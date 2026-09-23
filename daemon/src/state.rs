//! The state shared between the Wayland queue and the socket threads.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use wayland_client::protocol::{wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, QueueHandle};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1,
    zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
};

use crate::keymap::{
    compile_keymap_with, hash_bytes, modifier_masks_for_keymap, parse_keycodes, upload_keymap,
    XkbConfig,
};
use crate::protocol::keycap_facts_for_groups;
use crate::seat::publish_keymap;

pub(crate) fn stamp() -> u32 {
    static COUNTER: AtomicU32 = AtomicU32::new(1);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}

/// One logical press: who is claiming it, and when the device first saw it go
/// down. The instant belongs to the press rather than to any one claim, since
/// the device only holds the key once however many connections want it.
pub(crate) struct Hold {
    pub(crate) claimants: std::collections::HashSet<u64>,
    pub(crate) since: Instant,
}

/// What the socket threads need. Wayland proxies are Send + Sync and the
/// connection serialises requests internally, so client threads drive the
/// keyboard directly. That leaves the main thread free to sit in poll.
#[derive(Default)]
pub(crate) struct Shared {
    pub(crate) keyboard: Option<ZwpVirtualKeyboardV1>,
    /// The bytes behind the installed `kb_file`, if it came from one. `None`
    /// for an RMLVO keymap, where the configure's own fields are the identity.
    pub(crate) kb_file_mark: Option<u64>,
    /// Set before shutdown releases the device. Socket threads may still have
    /// buffered commands, but none may mutate the keyboard after this point.
    pub(crate) shutting_down: bool,
    /// A virtual keyboard drops key events until it has been given a keymap.
    pub(crate) ready: bool,
    /// xkb key name -> evdev code, taken from the keymap in use.
    pub(crate) codes: std::collections::HashMap<String, u32>,
    /// evdev code -> modifier bit per group, for the codes the keymap calls
    /// modifiers. A position may carry different bits in different groups —
    /// RALT is Alt_R in us and ISO_Level3_Shift in ua — so the active group
    /// picks the entry (see `modifier_mask`).
    pub(crate) modifier_masks: std::collections::HashMap<u32, Vec<u32>>,
    /// The generation stamped on every keycap-facts reply: the number of
    /// keymap installs this process has performed. A same-keymap reconfigure
    /// keeps it (the installed keymap did not change), a changed one bumps it.
    pub(crate) caps_gen: u64,
    /// Pre-resolved keycap-facts records, one string per group of the
    /// installed keymap (see `keycap_facts_for_groups`). Rebuilt exactly when
    /// `caps_gen` is bumped, so a `caps` request compiles nothing.
    pub(crate) caps_per_group: Vec<String>,
    /// Which compiled layout is active.
    pub(crate) group: u32,
    pub(crate) config: Option<XkbConfig>,
    /// Evdev codes held at the device, with the connections claiming each.
    /// The device is shared, so a code is one logical press with many
    /// claimants: it goes down with the first claim and up with the last
    /// release, and a claim is what authorizes a release.
    pub(crate) held: std::collections::HashMap<u32, Hold>,
    pub(crate) uploads: std::collections::VecDeque<Instant>,
}

impl Shared {
    /// Everything that must be true before a key can actually land.
    pub(crate) fn is_ready(&self) -> bool {
        self.keyboard.is_some() && self.ready && !self.codes.is_empty()
    }

    /// The modifier mask the device should be reporting: every bit carried by
    /// a code some connection currently holds, read at the group the device is
    /// typing in — the same position can mean different modifiers per group.
    /// Derived from `held` rather than accumulated, so it cannot drift out of
    /// step with what is pressed.
    pub(crate) fn modifier_mask(&self) -> u32 {
        self.held
            .keys()
            .filter_map(|code| match self.modifier_masks.get(code) {
                // A group beyond the keymap's own count wraps in xkb; the
                // first group's bit is the honest answer for it.
                Some(per_group) => per_group
                    .get(self.group as usize)
                    .or_else(|| per_group.first())
                    .copied(),
                None => None,
            })
            .fold(0, |mask, bit| mask | bit)
    }

    /// Compiles `layouts` and installs the result. Held by the caller's lock so
    /// a keystroke can never observe a half-swapped keymap.
    pub(crate) fn install_config(
        &mut self,
        config: &XkbConfig,
        kb_file_bytes: Option<&[u8]>,
        precompiled: Option<&str>,
    ) -> bool {
        // Same fields and, for a kb_file, the same bytes behind them. The
        // bytes arrive from the caller so one read both validates the group
        // ceiling and installs the map; two reads would let a swap between
        // them validate one file and install another. `precompiled` is the
        // same text the caller's ceiling counted; None means compile here.
        // The `group` command reaches none of this and never reads the file.
        let file_bytes = kb_file_bytes.map(|bytes| bytes.to_vec());
        let mark = file_bytes.as_deref().map(hash_bytes);
        if self
            .config
            .as_ref()
            .is_some_and(|current| current.same_keymap(config))
            && mark == self.kb_file_mark
        {
            // A same-keymap reconfigure is only ever a group change: the
            // device state was never reset, so whatever a client's chord
            // holds must survive the swap. The group rides on the same
            // request as the mask, so the mask goes back out with it.
            if self.group != config.group {
                self.group = config.group;
                if let Some(keyboard) = self.keyboard.as_ref() {
                    keyboard.modifiers(self.modifier_mask(), 0, 0, self.group);
                }
                // Logged because the failure this catches is invisible from
                // both ends: the panel believes it asked, the compositor
                // believes it was told, and the user is the only one who
                // finds out — by typing the previous alphabet.
                eprintln!("group -> {}", self.group);
            }
            self.config = Some(config.clone());
            return true;
        }
        // The churn budget is paid by apply's configure gate, before any
        // compile attempt — counting it here again would double-bill every
        // changed configure.
        let text = match precompiled {
            Some(text) => text.to_string(),
            None => match compile_keymap_with(config, file_bytes.as_deref()) {
                Some(text) => text,
                None => {
                    eprintln!("cannot compile requested XKB configuration");
                    return false;
                }
            },
        };
        let Some(keyboard) = self.keyboard.as_ref() else {
            return false;
        };
        if self.ready {
            for (code, _) in self.held.drain() {
                keyboard.key(stamp(), code, 0);
            }
            keyboard.modifiers(0, 0, 0, self.group);
        }
        if let Err(error) = upload_keymap(keyboard, &text) {
            eprintln!("cannot upload requested keymap: {error}");
            return false;
        }

        // A new keymap resets the device's group, so re-assert it.
        self.group = config.group;
        keyboard.modifiers(0, 0, 0, self.group);
        self.kb_file_mark = mark;
        self.codes = parse_keycodes(&text);
        self.modifier_masks = modifier_masks_for_keymap(&text, &self.codes);
        // The keycap facts are the same install's answer about itself: built
        // from the exact text that was just uploaded, so the panel's caps and
        // the compositor's typing can never disagree about the keymap.
        self.caps_gen += 1;
        self.caps_per_group = keycap_facts_for_groups(&text);
        // Published after the upload, never before: the file is an offer to
        // the compositor to share this exact keymap, and offering one that
        // was not installed would invite the divergence it exists to end.
        publish_keymap(&text);
        self.ready = !self.codes.is_empty();
        self.config = Some(config.clone());
        eprintln!(
            "keymap compiled for '{}' ({} bytes)",
            config.layouts,
            text.len()
        );
        self.ready
    }
}

pub(crate) type SharedRef = Arc<Mutex<Shared>>;

pub(crate) struct State {
    pub(crate) seat: Option<wl_seat::WlSeat>,
    pub(crate) manager: Option<ZwpVirtualKeyboardManagerV1>,
    pub(crate) shared: SharedRef,
}

impl State {
    fn ensure_keyboard(&mut self, qh: &QueueHandle<Self>) {
        let (Some(manager), Some(seat)) = (self.manager.as_ref(), self.seat.as_ref()) else {
            return;
        };
        let mut shared = self.shared.lock().unwrap();
        if shared.keyboard.is_some() {
            return;
        }
        shared.keyboard = Some(manager.create_virtual_keyboard(seat, qh, ()));
        shared.install_config(&XkbConfig::default(), None, None);
    }
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        else {
            return;
        };
        match interface.as_str() {
            "wl_seat" => state.seat = Some(registry.bind(name, version.min(7), qh, ())),
            "zwp_virtual_keyboard_manager_v1" => {
                state.manager = Some(registry.bind(name, 1, qh, ()))
            }
            _ => {}
        }
        state.ensure_keyboard(qh);
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(
        _: &mut Self,
        _: &wl_seat::WlSeat,
        _: wl_seat::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        // The seat keyboard is deliberately not bound: reading its keymap
        // couples this helper to the seat (see the module header).
    }
}

impl Dispatch<ZwpVirtualKeyboardManagerV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &ZwpVirtualKeyboardManagerV1,
        _: <ZwpVirtualKeyboardManagerV1 as wayland_client::Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwpVirtualKeyboardV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &ZwpVirtualKeyboardV1,
        _: <ZwpVirtualKeyboardV1 as wayland_client::Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
