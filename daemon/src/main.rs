//! Persistent virtual keyboard for the on-screen keyboard plugin.
//!
//! Why this exists. The plugin used to spawn a `wtype` process per keystroke,
//! which cost 30-80ms a key and, worse, never reached XWayland clients at all:
//! wtype builds a small synthetic keymap holding just the character it needs,
//! and XWayland ignores that, so keys vanished into Proton games and Electron
//! apps. One long-lived helper with a real, complete keymap fixes both. Measured
//! at 0.4ms average per keystroke against 37.8ms for a wtype spawn.
//!
//! Why it compiles its own keymap. An earlier version subscribed to the seat's
//! keymap and mirrored it into its virtual keyboard. That coupling was a
//! mistake and produced two separate failures: uploading changed the seat, the
//! compositor rebuilt its keymap and sent it back, and the cycle drove xkbcomp
//! 56,547 times in five minutes until the desktop froze; and holding a layout
//! group in step with the seat disturbed layout switching for unrelated
//! applications. There is no subscription now, so neither is possible. wvkbd
//! has worked this way for years without upsetting a session.
//!
//! One compiled keymap carries every configured layout as a group, so switching
//! language selects a group rather than compiling again. The panel tells the
//! helper which layouts to compile and which group is active; it is the only
//! thing that talks to the compositor about layouts.
//!
//! Protocol, one command per line on a unix socket:
//!   hello <version>   readiness gate, replies `hello <version>`
//!   ping              replies `pong`
//!   keyboards         snapshot positively identified physical keyboards
//!   tap <key>         press and release; <key> is an xkb name (AD01) or an
//!                     evdev code (16)
//!   down <key>        press
//!   up <key>          release
//!   mods <mask>       set the modifier mask by hand; the helper maintains it
//!                     from the keys held, so the next down/up supersedes this
//!   group <n>         select which compiled layout to type in
//!   configure<TAB>rules<TAB>model<TAB>layouts<TAB>variants<TAB>options
//!             <TAB>kb_file<TAB>group
//! Replies are `ok`, `hello <n>`, `configured`, `pong`,
//! `keyboards<TAB>name...`, or `err <reason>`.
//!
//! Key repeat belongs to the compositor: a press is `down`, a release is `up`,
//! and nothing here or in the panel repeats anything. What the helper does add
//! is a cap — a non-modifier code held past fifteen seconds is lifted and
//! logged, because the only way that happens is a panel that is alive but
//! wedged. Modifier codes are exempt; a locked Ctrl is deliberately held.

use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use wayland_client::protocol::{wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, EventQueue, QueueHandle};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1,
    zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
};

/// Bumped whenever the command set changes, so a plugin updated without
/// reinstalling the helper says so instead of failing silently.
const PROTOCOL_VERSION: u32 = 3;

/// How long a non-modifier code may stay held before the helper lifts it
/// (spec-v1 §6). Fifteen seconds of held backspace is about six hundred
/// repeats; nobody does that with a mouse button, so a hold that long means
/// the panel is alive but wedged.
const DEFAULT_HOLD_CAP: Duration = Duration::from_secs(15);

/// The cap, overridable so the integration seam can assert on it without
/// sleeping fifteen seconds. Read once: a value that changed under a live
/// hold would make the deadline already armed on a client thread a lie.
fn hold_cap() -> Duration {
    static CAP: std::sync::OnceLock<Duration> = std::sync::OnceLock::new();
    *CAP.get_or_init(|| {
        std::env::var("OMARCHY_OSK_HOLD_CAP_MS")
            .ok()
            .and_then(|raw| raw.trim().parse::<u64>().ok())
            .filter(|ms| *ms > 0)
            .map_or(DEFAULT_HOLD_CAP, Duration::from_millis)
    })
}

/// The compositor only orders key events by this stamp, so a counter is enough
/// and saves a clock syscall per keystroke.
fn stamp() -> u32 {
    static COUNTER: AtomicU32 = AtomicU32::new(1);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}

/// Until the panel reports the real list. Any layout compiles; this one just
/// gives the helper a valid keymap to be ready with.
#[derive(Clone, Debug, Eq, PartialEq)]
struct XkbConfig {
    rules: String,
    model: String,
    layouts: String,
    variants: String,
    options: String,
    kb_file: String,
    group: u32,
}

impl Default for XkbConfig {
    fn default() -> Self {
        Self {
            rules: "evdev".into(),
            model: "pc105".into(),
            layouts: "us".into(),
            variants: String::new(),
            options: String::new(),
            kb_file: String::new(),
            group: 0,
        }
    }
}

impl XkbConfig {
    fn same_keymap(&self, other: &Self) -> bool {
        self.rules == other.rules
            && self.model == other.model
            && self.layouts == other.layouts
            && self.variants == other.variants
            && self.options == other.options
            && self.kb_file == other.kb_file
    }
}

/// Builds a keymap for an RMLVO layout list such as "us,ua".
fn compile_keymap(config: &XkbConfig) -> Option<String> {
    use xkbcommon::xkb;
    let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    if !config.kb_file.is_empty() {
        let text = std::fs::read_to_string(&config.kb_file).ok()?;
        if text.len() > 2 * 1024 * 1024 {
            return None;
        }
        let keymap = xkb::Keymap::new_from_string(
            &context,
            text,
            xkb::KEYMAP_FORMAT_TEXT_V1,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )?;
        return Some(keymap.get_as_string(xkb::KEYMAP_FORMAT_TEXT_V1));
    }

    let rules = if config.rules.is_empty() {
        "evdev"
    } else {
        &config.rules
    };
    let model = if config.model.is_empty() {
        "pc105"
    } else {
        &config.model
    };
    let options = (!config.options.is_empty()).then(|| config.options.clone());
    let keymap = xkb::Keymap::new_from_names(
        &context,
        rules,
        model,
        &config.layouts,
        &config.variants,
        options,
        xkb::KEYMAP_COMPILE_NO_FLAGS,
    )?;
    Some(keymap.get_as_string(xkb::KEYMAP_FORMAT_TEXT_V1))
}

/// Hands a compiled keymap to the virtual keyboard through a file descriptor,
/// which is how the protocol expects to receive one.
fn upload_keymap(keyboard: &ZwpVirtualKeyboardV1, text: &str) -> std::io::Result<()> {
    use std::io::{Seek, SeekFrom};
    let mut file = tempfile::tempfile()?;
    file.write_all(text.as_bytes())?;
    file.write_all(&[0])?;
    file.seek(SeekFrom::Start(0))?;
    keyboard.keymap(1, file.as_fd(), text.len() as u32 + 1);
    Ok(())
}

/// Pulls `<AD01> = 24;` pairs out of the keymap's xkb_keycodes section.
///
/// Callers name keys the way xkb does, and the numbers are resolved here rather
/// than in the QML client: the keymap in hand is the authority, and there is no
/// second table to keep in step. Names map to evdev codes, the xkb codes minus 8.
fn parse_keycodes(keymap: &str) -> std::collections::HashMap<String, u32> {
    let mut codes = std::collections::HashMap::new();
    let Some(section) = keymap.split("xkb_keycodes").nth(1) else {
        return codes;
    };
    let section = section.split("};").next().unwrap_or(section);

    for line in section.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix('<') else {
            continue;
        };
        let Some((name, rest)) = rest.split_once('>') else {
            continue;
        };
        let Some((_, value)) = rest.split_once('=') else {
            continue;
        };
        let value = value.trim().trim_end_matches(';').trim();
        if let Ok(code) = value.parse::<u32>() {
            if let Some(evdev) = code.checked_sub(8) {
                codes.insert(name.to_string(), evdev);
            }
        }
    }
    codes
}

/// Which evdev codes carry which modifier bit, read out of the keymap in hand.
///
/// A wlroots compositor takes a virtual keyboard's modifier state from the
/// `modifiers` request alone; it does not watch key events and work it out.
/// So the helper has to say what is held, and to say it, it has to know which
/// positions are modifiers — a fact that belongs to the keymap and to nothing
/// else. Which position carries which modifier is an option away from
/// changing — `altwin:swap_lalt_lwin` moves LALT from Mod1 to Mod4 — and a
/// hard-coded table would be wrong for every setup but the one it was
/// written against.
///
/// The bit for a real modifier is its index in the order xkb fixes: Shift,
/// Lock, Control, Mod1..Mod5.
///
/// Asked of a real xkb state rather than read out of `modifier_map`, because
/// the modifier map is not what a keypress means. It is the union of every
/// modifier a position can reach on any level, and xkb resolves a press
/// through the action on the level actually selected. `shift:both_capslock_
/// cancel` is the case that broke: it puts Caps_Lock on the Shift keys'
/// second level, so with `grp:caps_toggle` also in play the keymap says
/// `modifier_map Lock { <LFSH> }`, and a union said a held Shift meant
/// Shift+Lock. Shift+Lock on an ALPHABETIC key is level 1 — the letters came
/// out lowercase while the TWO_LEVEL number row, which ignores Lock, shifted
/// correctly.
///
/// Pressing the position in a clean state and serializing what comes out is
/// what the compositor would do for a physical keyboard, so it agrees by
/// construction — and it picks up the positions that become modifiers through
/// a compat interpret rather than a modifier map, which the old reading
/// admitted it could not see.
fn modifier_masks_for_keymap(
    keymap: &str,
    codes: &std::collections::HashMap<String, u32>,
) -> std::collections::HashMap<u32, u32> {
    use xkbcommon::xkb;

    let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    let Some(compiled) = xkb::Keymap::new_from_string(
        &context,
        keymap.to_string(),
        xkb::KEYMAP_FORMAT_TEXT_V1,
        xkb::KEYMAP_COMPILE_NO_FLAGS,
    ) else {
        return std::collections::HashMap::new();
    };

    let mut masks = std::collections::HashMap::new();
    for code in codes.values() {
        // A fresh state per position rather than press-then-release: a key
        // carrying LockMods (Caps Lock) does not undo itself on release, and
        // would leave its bit set for every position probed after it.
        let mut state = xkb::State::new(&compiled);
        state.update_key(xkb::Keycode::from(code + 8), xkb::KeyDirection::Down);
        let mask = state.serialize_mods(xkb::STATE_MODS_EFFECTIVE);
        if mask != 0 {
            masks.insert(*code, mask);
        }
    }
    masks
}

/// A key is named the way xkb names it (`AD01`) or given as a raw evdev code.
enum Key {
    Code(u32),
    Name(String),
}

enum Command {
    Tap(Key),
    Down(Key),
    Up(Key),
    Mods(u32),
    /// Selects which compiled layout this device types in.
    Group(u32),
    /// Atomically installs complete XKB state and selects its active group.
    Configure(XkbConfig),
}

/// One logical press: who is claiming it, and when the device first saw it go
/// down. The instant belongs to the press rather than to any one claim, since
/// the device only holds the key once however many connections want it.
struct Hold {
    claimants: std::collections::HashSet<u64>,
    since: Instant,
}

/// What the socket threads need. Wayland proxies are Send + Sync and the
/// connection serialises requests internally, so client threads drive the
/// keyboard directly. That leaves the main thread free to sit in poll.
#[derive(Default)]
struct Shared {
    keyboard: Option<ZwpVirtualKeyboardV1>,
    /// A virtual keyboard drops key events until it has been given a keymap.
    ready: bool,
    /// xkb key name -> evdev code, taken from the keymap in use.
    codes: std::collections::HashMap<String, u32>,
    /// evdev code -> modifier bit, for the codes the keymap calls modifiers.
    modifier_masks: std::collections::HashMap<u32, u32>,
    /// Which compiled layout is active.
    group: u32,
    config: Option<XkbConfig>,
    /// Evdev codes held at the device, with the connections claiming each.
    /// The device is shared, so a code is one logical press with many
    /// claimants: it goes down with the first claim and up with the last
    /// release, and a claim is what authorizes a release.
    held: std::collections::HashMap<u32, Hold>,
    uploads: std::collections::VecDeque<Instant>,
}

impl Shared {
    /// Everything that must be true before a key can actually land.
    fn is_ready(&self) -> bool {
        self.keyboard.is_some() && self.ready && !self.codes.is_empty()
    }

    /// The modifier mask the device should be reporting: every bit carried by
    /// a code some connection currently holds. Derived from `held` rather than
    /// accumulated, so it cannot drift out of step with what is pressed.
    fn modifier_mask(&self) -> u32 {
        self.held
            .keys()
            .filter_map(|code| self.modifier_masks.get(code))
            .fold(0, |mask, bit| mask | bit)
    }

    /// Compiles `layouts` and installs the result. Held by the caller's lock so
    /// a keystroke can never observe a half-swapped keymap.
    fn install_config(&mut self, config: &XkbConfig) -> bool {
        if self
            .config
            .as_ref()
            .is_some_and(|current| current.same_keymap(config))
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
            }
            self.config = Some(config.clone());
            return true;
        }
        let now = Instant::now();
        while self
            .uploads
            .front()
            .is_some_and(|at| now.duration_since(*at) > Duration::from_secs(10))
        {
            self.uploads.pop_front();
        }
        if self.uploads.len() >= 4 {
            eprintln!("refusing excessive keymap reconfiguration");
            return false;
        }
        let Some(text) = compile_keymap(config) else {
            eprintln!("cannot compile requested XKB configuration");
            return false;
        };
        let Some(keyboard) = self.keyboard.as_ref() else {
            return false;
        };
        if self.ready {
            for (code, _) in self.held.drain() {
                keyboard.key(0, code, 0);
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
        self.codes = parse_keycodes(&text);
        self.modifier_masks = modifier_masks_for_keymap(&text, &self.codes);
        self.ready = !self.codes.is_empty();
        self.config = Some(config.clone());
        self.uploads.push_back(now);
        eprintln!(
            "keymap compiled for '{}' ({} bytes)",
            config.layouts,
            text.len()
        );
        self.ready
    }
}

type SharedRef = Arc<Mutex<Shared>>;

struct State {
    seat: Option<wl_seat::WlSeat>,
    manager: Option<ZwpVirtualKeyboardManagerV1>,
    shared: SharedRef,
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
        shared.install_config(&XkbConfig::default());
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
        // The seat keyboard is deliberately not bound. Reading its keymap is
        // what coupled this helper to the seat, and that coupling caused both
        // the rebuild storm and the layout-switching interference.
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

fn socket_path() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let dir = std::env::var("XDG_RUNTIME_DIR")
        .map_err(|_| "XDG_RUNTIME_DIR is unset; this must run inside a user session")?;
    let dir = PathBuf::from(dir).join("omarchy-osk");
    std::fs::create_dir_all(&dir)?;
    Ok(dir.join("control.sock"))
}

/// The names Hyprland gives kernel input devices that udev identifies as
/// keyboards, excluding any libinput device group that also owns a pointer.
/// A gaming mouse often exposes a full keyboard-shaped HID interface; the
/// shared device group is the positive evidence that it is not a keyboard we
/// may safely advance. Missing metadata produces no candidate, never a guess.
fn physical_keyboard_names(input_root: &Path, udev_root: &Path) -> Vec<String> {
    struct Device {
        name: String,
        group: String,
        keyboard: bool,
        pointer: bool,
    }

    let Ok(entries) = std::fs::read_dir(input_root) else {
        return Vec::new();
    };
    let mut devices = Vec::new();
    for entry in entries.flatten() {
        let event = entry.file_name();
        if !event.to_string_lossy().starts_with("event") {
            continue;
        }
        let path = entry.path();
        let Ok(name) = std::fs::read_to_string(path.join("device/name")) else {
            continue;
        };
        let Ok(dev) = std::fs::read_to_string(path.join("dev")) else {
            continue;
        };
        let Ok(properties) = std::fs::read_to_string(udev_root.join(format!("c{}", dev.trim())))
        else {
            continue;
        };
        let property = |wanted: &str| {
            properties.lines().find_map(|line| {
                line.strip_prefix("E:")?
                    .split_once('=')
                    .filter(|(key, _)| *key == wanted)
                    .map(|(_, value)| value)
            })
        };
        let group = property("LIBINPUT_DEVICE_GROUP").unwrap_or("").to_string();
        if group.is_empty() {
            continue;
        }
        devices.push(Device {
            name: name.trim().to_string(),
            group,
            keyboard: property("ID_INPUT_KEYBOARD") == Some("1"),
            pointer: [
                "ID_INPUT_MOUSE",
                "ID_INPUT_TOUCHPAD",
                "ID_INPUT_TOUCHSCREEN",
                "ID_INPUT_TABLET",
            ]
            .iter()
            .any(|key| property(key) == Some("1")),
        });
    }

    let pointer_groups: std::collections::HashSet<&str> = devices
        .iter()
        .filter(|device| device.pointer)
        .map(|device| device.group.as_str())
        .collect();
    let mut names: Vec<String> = devices
        .iter()
        .filter(|device| device.keyboard && !pointer_groups.contains(device.group.as_str()))
        .map(|device| {
            device
                .name
                .chars()
                .flat_map(char::to_lowercase)
                .map(|character| {
                    if character.is_whitespace() {
                        '-'
                    } else {
                        character
                    }
                })
                .collect()
        })
        .filter(|name: &String| {
            ![
                "hl-virtual-keyboard",
                "power-button",
                "sleep-button",
                "lid-switch",
                "video-bus",
                "omarchy-osk",
            ]
            .iter()
            .any(|prefix| name.starts_with(prefix))
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

fn startup_keyboard_reply() -> String {
    let names = physical_keyboard_names(Path::new("/sys/class/input"), Path::new("/run/udev/data"));
    if names.is_empty() {
        "keyboards".to_string()
    } else {
        format!("keyboards\t{}", names.join("\t"))
    }
}

fn parse(line: &str) -> Option<Command> {
    if let Some(raw) = line.strip_prefix("configure\t") {
        let fields: Vec<&str> = raw.split('\t').collect();
        if fields.len() != 7 {
            return None;
        }
        return Some(Command::Configure(XkbConfig {
            rules: fields[0].to_string(),
            model: fields[1].to_string(),
            layouts: fields[2].to_string(),
            variants: fields[3].to_string(),
            options: fields[4].to_string(),
            kb_file: fields[5].to_string(),
            group: fields[6].parse().ok()?,
        }));
    }
    let mut parts = line.split_whitespace();
    let verb = parts.next()?;
    let raw = parts.next()?;
    let key = || match raw.parse::<u32>() {
        Ok(code) => Key::Code(code),
        Err(_) => Key::Name(raw.to_string()),
    };
    match verb {
        "tap" => Some(Command::Tap(key())),
        "down" => Some(Command::Down(key())),
        "up" => Some(Command::Up(key())),
        "mods" => raw.parse::<u32>().ok().map(Command::Mods),
        "group" => raw.parse::<u32>().ok().map(Command::Group),
        _ => None,
    }
}

fn serve(listener: UnixListener, shared: SharedRef, connection: Connection) {
    const MAX_CLIENTS: usize = 4;
    let clients = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    for stream in listener.incoming().flatten() {
        if clients.fetch_add(1, Ordering::AcqRel) >= MAX_CLIENTS {
            clients.fetch_sub(1, Ordering::AcqRel);
            drop(stream);
            continue;
        }
        let shared = Arc::clone(&shared);
        let connection = connection.clone();
        let clients = Arc::clone(&clients);
        if thread::Builder::new()
            .name("osk-client".into())
            .spawn(move || {
                handle_client(stream, shared, connection);
                clients.fetch_sub(1, Ordering::AcqRel);
            })
            .is_err()
        {
            eprintln!("cannot spawn socket client worker");
            std::process::exit(70);
        }
    }
}

fn handle_client(stream: UnixStream, shared: SharedRef, connection: Connection) {
    let Ok(mut out) = stream.try_clone() else {
        return;
    };
    // Keys this connection pressed and has not released. If the shell restarts
    // mid-chord the compositor would otherwise keep Ctrl logically down for the
    // rest of the session, which looks like a broken machine rather than a
    // broken plugin.
    let mut held: Vec<u32> = Vec::new();
    static CONNECTION: AtomicU64 = AtomicU64::new(1);
    let conn_id = CONNECTION.fetch_add(1, Ordering::Relaxed);

    let mut reader = BufReader::new(match stream.try_clone() {
        Ok(handle) => handle,
        Err(_) => return,
    });
    let mut pending = String::new();
    loop {
        // The only thing this connection ever waits on is its own next line.
        // Arming that wait with the cap's deadline is what enforces the cap
        // without a timer thread: no hold means no deadline and the read
        // blocks the way it always did, and a hold means exactly one wakeup,
        // at the moment the key is due to be lifted.
        let timeout = hold_deadline(&shared, conn_id).map(|deadline| {
            deadline
                .saturating_duration_since(Instant::now())
                .max(Duration::from_millis(1))
        });
        if stream.set_read_timeout(timeout).is_err() {
            break;
        }
        match reader.read_line(&mut pending) {
            Ok(0) => break,
            Ok(_) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                // The deadline came due with nothing to read, which is the
                // wedged panel this cap exists for. `pending` keeps whatever
                // part of a line did arrive; the next read appends to it.
                for code in expire_stuck_keys(&shared, &connection) {
                    held.retain(|entry| *entry != code);
                }
                continue;
            }
            Err(_) => break,
        }
        let line = std::mem::take(&mut pending);
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // `hello` reports more than "the process is up": a keyboard without a
        // keymap accepts commands and drops every key, so the client must not
        // enable keys until one is loaded. `ping` stays a plain liveness check.
        if let Some(version) = line.strip_prefix("hello") {
            let wanted: u32 = version.trim().parse().unwrap_or(PROTOCOL_VERSION);
            let reply = if wanted != PROTOCOL_VERSION {
                format!("err protocol {PROTOCOL_VERSION} required, helper needs reinstall")
            } else if shared.lock().unwrap().is_ready() {
                format!("hello {PROTOCOL_VERSION}")
            } else {
                "err not ready".to_string()
            };
            let _ = writeln!(out, "{reply}");
            continue;
        }
        if line == "ping" {
            let _ = writeln!(out, "pong");
            continue;
        }
        if line == "keyboards" {
            let _ = writeln!(out, "{}", startup_keyboard_reply());
            continue;
        }
        let reply = match parse(line) {
            Some(command) => apply(&shared, &connection, command, Some(&mut held), conn_id),
            None => "err unknown command",
        };
        let _ = writeln!(out, "{reply}");
    }

    release_all(&shared, &connection, held, conn_id);
}

/// Releases whatever a departing client left pressed and, when nothing is
/// held any more, zeroes the modifier mask — so a dropped connection cannot
/// strand the session with a stuck key, while a surviving connection's
/// chord survives a neighbour disconnecting. The whole cleanup runs under
/// one lock acquisition: an emptiness check followed by a separate
/// re-locked `mods` would admit another connection's claim in between and
/// clear the mask out from under it.
fn release_all(shared: &SharedRef, connection: &Connection, held: Vec<u32>, conn_id: u64) {
    let mut shared = shared.lock().unwrap();
    for code in held {
        apply_locked(
            &mut shared,
            connection,
            Command::Up(Key::Code(code)),
            None,
            conn_id,
        );
    }
    if shared.held.is_empty() {
        apply_locked(&mut shared, connection, Command::Mods(0), None, conn_id);
    }
}

/// When the client thread must next wake to enforce the cap: the earliest
/// expiry among the non-modifier codes this connection is claiming, or `None`
/// when it holds nothing capped. `None` means the read blocks with no deadline
/// at all, which is what keeps this from being a poll — an idle connection
/// wakes zero times, and a holding one wakes once.
fn hold_deadline(shared: &SharedRef, conn_id: u64) -> Option<Instant> {
    let shared = shared.lock().unwrap();
    let cap = hold_cap();
    shared
        .held
        .iter()
        .filter(|(code, hold)| {
            hold.claimants.contains(&conn_id) && !shared.modifier_masks.contains_key(*code)
        })
        .map(|(_, hold)| hold.since + cap)
        .min()
}

/// Lifts every non-modifier code held past the cap and says so in the log.
/// Modifier codes are exempt: a locked Ctrl (spec-v1 §5) is deliberately held
/// for minutes, and releasing it would make the lock indicator lie.
///
/// The release is unconditional rather than per-claim — the device holds the
/// key once, so lifting it means dropping every claim on it. Returns the codes
/// it released so the caller can forget them too.
fn expire_stuck_keys(shared: &SharedRef, connection: &Connection) -> Vec<u32> {
    let mut shared = shared.lock().unwrap();
    let cap = hold_cap();
    let now = Instant::now();
    let expired: Vec<u32> = shared
        .held
        .iter()
        .filter(|(code, hold)| {
            !shared.modifier_masks.contains_key(*code) && now.duration_since(hold.since) >= cap
        })
        .map(|(code, _)| *code)
        .collect();
    if expired.is_empty() {
        return expired;
    }
    let Some(keyboard) = shared.keyboard.clone() else {
        return Vec::new();
    };
    for code in &expired {
        shared.held.remove(code);
        keyboard.key(stamp(), *code, 0);
        eprintln!(
            "releasing stuck key {code} held past {} ms",
            cap.as_millis()
        );
    }
    let _ = connection.flush();
    expired
}

fn apply(
    shared: &SharedRef,
    connection: &Connection,
    command: Command,
    held: Option<&mut Vec<u32>>,
    conn_id: u64,
) -> &'static str {
    let mut shared = shared.lock().unwrap();
    apply_locked(&mut shared, connection, command, held, conn_id)
}

fn apply_locked(
    shared: &mut Shared,
    connection: &Connection,
    command: Command,
    mut held: Option<&mut Vec<u32>>,
    conn_id: u64,
) -> &'static str {
    if let Command::Configure(ref config) = command {
        let installed = shared.install_config(config);
        let _ = connection.flush();
        return if installed {
            "configured"
        } else {
            "err cannot configure keymap"
        };
    }

    let Some(keyboard) = shared.keyboard.as_ref() else {
        return "err no virtual keyboard";
    };
    if !shared.ready {
        return "err no keymap yet";
    }

    // Held-key bookkeeping below mutates `shared`, so drop the borrow the
    // proxy carries by cloning it — proxies are cheap handles, and the Group
    // arm already does this.
    let keyboard = keyboard.clone();

    // Codes go out as evdev numbers, the xkb keycode minus 8.
    let resolve = |key: &Key| match key {
        Key::Code(code) => Some(*code),
        Key::Name(name) => shared.codes.get(name).copied(),
    };

    let mut pressed = None;
    let mut released = None;

    match command {
        // A tap participates in the same ownership as down/up: while any
        // connection holds the code, the key is down, so the compositor
        // would drop the duplicate press and the tap's release would lift
        // someone else's hold. Neither is sent; the claim is left alone.
        Command::Tap(ref key) => match resolve(key) {
            Some(code) => {
                if shared.held.contains_key(&code) {
                    return "err key held";
                }
                keyboard.key(stamp(), code, 1);
                keyboard.key(stamp(), code, 0);
            }
            None => return "err unknown key",
        },
        Command::Down(ref key) => match resolve(key) {
            Some(code) => {
                // The claim set is the authority: the device press belongs to
                // the first claim and the release to the last, so a duplicate
                // `down` neither re-presses nor re-claims. Gating on the set
                // (not the connection's own list) is what lets a connection
                // re-claim after a keymap swap drained the claims out from
                // under it — its list still shows the code, but the device
                // press is genuinely new again.
                let hold = shared.held.entry(code).or_insert_with(|| Hold {
                    claimants: std::collections::HashSet::new(),
                    since: Instant::now(),
                });
                let was_first = hold.claimants.is_empty();
                if !hold.claimants.contains(&conn_id) {
                    hold.claimants.insert(conn_id);
                }
                if was_first {
                    // The stuck-key cap measures the device press, so a
                    // re-press after the last claim went restarts the clock.
                    hold.since = Instant::now();
                    keyboard.key(stamp(), code, 1);
                }
                pressed = Some(code);
            }
            None => return "err unknown key",
        },
        Command::Up(ref key) => match resolve(key) {
            Some(code) => {
                // A claim authorizes a release: the device sees the key go up
                // only when the last claim on it goes. A connection that
                // never claimed the code cannot end another connection's
                // hold, and says so. An Up for a code nothing holds is still
                // forwarded — the compositor drops releases for keys it does
                // not consider held, and refusing would strand a client's
                // view of its own state after a mid-hold keymap swap
                // released everything behind its back.
                let send_release = match shared.held.get_mut(&code) {
                    Some(hold) => {
                        if !hold.claimants.remove(&conn_id) {
                            return "err not holding";
                        }
                        let last = hold.claimants.is_empty();
                        if last {
                            shared.held.remove(&code);
                        }
                        last
                    }
                    None => true,
                };
                if send_release {
                    keyboard.key(stamp(), code, 0);
                }
                released = Some(code);
            }
            None => return "err unknown key",
        },
        // The group rides along with every modifier update: dropping it would
        // silently reset the device to the first layout.
        Command::Mods(mask) => keyboard.modifiers(mask, 0, 0, shared.group),
        // A language switch mid-chord must not drop what is held, so the
        // group goes out alongside the mask the held keys imply rather than
        // alongside a zero.
        Command::Group(group) => {
            let keyboard = keyboard.clone();
            shared.group = group;
            keyboard.modifiers(shared.modifier_mask(), 0, 0, group);
        }
        Command::Configure(_) => unreachable!("handled above"),
    }

    // A key event carries no modifier state of its own. The compositor learns
    // what is held from `modifiers` and from nothing else, so a chord that was
    // only ever pressed and released arrives modifierless: `down LFSH / tap
    // AD01 / up LFSH` typed `q`, which is how this shipped broken. Re-assert
    // the mask whenever a modifier code goes down or comes up, and the tap in
    // between lands under it.
    if let Some(code) = pressed.or(released) {
        if shared.modifier_masks.contains_key(&code) {
            keyboard.modifiers(shared.modifier_mask(), 0, 0, shared.group);
        }
    }

    if let Some(held) = held.as_deref_mut() {
        if let Some(code) = pressed {
            if !held.contains(&code) {
                held.push(code);
            }
        }
        if let Some(code) = released {
            held.retain(|entry| *entry != code);
        }
    }

    // Requests sit in the connection buffer until flushed, and the event loop
    // may be parked with nothing to wake it, so flush here rather than hoping
    // it happens soon.
    let _ = connection.flush();
    "ok"
}

/// Blocks on compositor events for the life of the process. With no keymap
/// subscription there is almost nothing to receive, so this thread sits in
/// poll, which is the point.
fn run(mut queue: EventQueue<State>, mut state: State) -> Result<(), Box<dyn std::error::Error>> {
    loop {
        // Exit rather than trying to reconnect: the session environment this
        // process started with is stale once the compositor is gone, and
        // systemd rebuilds the connection, registry and keyboard cleanly.
        queue.blocking_dispatch(&mut state)?;
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let connection = Connection::connect_to_env()?;
    let mut queue = connection.new_event_queue();
    let qh = queue.handle();
    connection.display().get_registry(&qh, ());

    let shared: SharedRef = Arc::new(Mutex::new(Shared::default()));
    let mut state = State {
        seat: None,
        manager: None,
        shared: Arc::clone(&shared),
    };

    // Globals and seat capabilities are causally ordered but need not arrive
    // within one sync boundary, so bound the wait rather than assuming a
    // particular batching.
    for _ in 0..8 {
        queue.roundtrip(&mut state)?;
        if shared.lock().unwrap().is_ready() {
            break;
        }
    }

    if !shared.lock().unwrap().is_ready() {
        let reason = if state.manager.is_none() {
            "compositor does not offer zwp_virtual_keyboard_manager_v1"
        } else if state.seat.is_none() {
            "compositor did not advertise a seat"
        } else {
            "virtual keyboard did not become ready"
        };
        return Err(reason.into());
    }

    // `keyboard.keymap` is asynchronous. Do not expose the control socket until
    // the compositor has processed it; otherwise a fast client can send a
    // modifiers request first and Hyprland terminates the protocol object with
    // "Mods event received before a keymap was set".
    connection.flush()?;
    queue.roundtrip(&mut state)?;

    let path = socket_path()?;
    // Refuse to be the second instance. Connecting is the test rather than a
    // lock file, because it tells a live owner apart from a socket left behind
    // by a crash; unlinking blindly would let a newcomer steal the path from a
    // running daemon and leave both serving.
    if UnixStream::connect(&path).is_ok() {
        return Err(format!("another daemon already owns {}", path.display()).into());
    }
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)
        .map_err(|error| format!("cannot bind {}: {error}", path.display()))?;
    eprintln!("listening on {}", path.display());

    let socket_shared = Arc::clone(&shared);
    let socket_connection = connection.clone();
    thread::spawn(move || serve(listener, socket_shared, socket_connection));
    run(queue, state)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_inventory_rejects_a_mouse_keyboard_interface() {
        let root =
            std::env::temp_dir().join(format!("omarchy-osk-device-test-{}", std::process::id()));
        let input = root.join("input");
        let udev = root.join("udev");
        std::fs::create_dir_all(&udev).unwrap();

        let device = |event: &str, dev: &str, name: &str, properties: &str| {
            let path = input.join(event);
            std::fs::create_dir_all(path.join("device")).unwrap();
            std::fs::write(path.join("device/name"), name).unwrap();
            std::fs::write(path.join("dev"), dev).unwrap();
            std::fs::write(udev.join(format!("c{dev}")), properties).unwrap();
        };
        device(
            "event1",
            "13:1",
            "QEMU USB Keyboard",
            "E:ID_INPUT_KEYBOARD=1\nE:LIBINPUT_DEVICE_GROUP=keyboard\n",
        );
        device(
            "event2",
            "13:2",
            "Gaming Mouse Keyboard",
            "E:ID_INPUT_KEYBOARD=1\nE:LIBINPUT_DEVICE_GROUP=mouse\n",
        );
        device(
            "event3",
            "13:3",
            "Gaming Mouse",
            "E:ID_INPUT_MOUSE=1\nE:LIBINPUT_DEVICE_GROUP=mouse\n",
        );
        device(
            "event4",
            "13:4",
            "Power Button",
            "E:ID_INPUT_KEY=1\nE:LIBINPUT_DEVICE_GROUP=power\n",
        );

        assert_eq!(
            physical_keyboard_names(&input, &udev),
            vec!["qemu-usb-keyboard"]
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn compiles_a_multi_layout_keymap_with_a_group_per_layout() {
        let text = compile_keymap(&XkbConfig {
            layouts: "us,ua".into(),
            ..XkbConfig::default()
        })
        .expect("us,ua should compile");
        assert!(text.contains("xkb_keycodes"));
        // The second layout has to be present, since switching language
        // selects a group rather than recompiling. Groups appear as
        // `symbols[N]` entries on each key, so a second one means `ua` is in
        // there alongside `us`.
        assert!(
            text.contains("symbols[2]"),
            "expected a second layout group"
        );
        // libxkbcommon writes keysyms as numbers rather than names, so the
        // check is for the value: 0x6ca is Cyrillic_shorti, the Q position on
        // the Ukrainian layout. Its presence proves group 2 really is `ua` and
        // not a second copy of `us`.
        assert!(
            text.contains("0x6ca"),
            "expected the ua layout's own symbols in group 2"
        );
    }

    #[test]
    fn rejects_a_layout_that_does_not_exist() {
        assert!(compile_keymap(&XkbConfig {
            layouts: "definitely-not-a-layout".into(),
            ..XkbConfig::default()
        })
        .is_none());
    }

    #[test]
    fn reads_key_positions_out_of_a_compiled_keymap() {
        let text = compile_keymap(&XkbConfig::default()).expect("us should compile");
        let codes = parse_keycodes(&text);
        // AD01 is the Q position; evdev numbers it 16, xkb 24.
        assert_eq!(codes.get("AD01"), Some(&16));
        assert_eq!(codes.get("SPCE"), Some(&57));
    }

    #[test]
    fn reads_modifier_bits_out_of_a_compiled_keymap() {
        let text = compile_keymap(&XkbConfig::default()).expect("us should compile");
        let codes = parse_keycodes(&text);
        let masks = modifier_masks_for_keymap(&text, &codes);
        // xkb fixes the order of the real modifiers, so Shift is bit 0,
        // Control bit 2 and Mod4 — which is where `us` puts Super — bit 6.
        assert_eq!(masks.get(&codes["LFSH"]), Some(&0b1));
        assert_eq!(masks.get(&codes["RTSH"]), Some(&0b1));
        assert_eq!(masks.get(&codes["LCTL"]), Some(&0b100));
        assert_eq!(masks.get(&codes["LWIN"]), Some(&0b100_0000));
        // An ordinary letter carries no modifier bit at all, which is what
        // keeps the mask from being re-asserted on every keystroke.
        assert_eq!(masks.get(&codes["AD01"]), None);
        // Plain `us` puts RALT on Mod1, alongside LALT.
        assert_eq!(masks.get(&codes["RALT"]), Some(&0b1000));
    }

    #[test]
    fn a_position_carries_whichever_modifier_the_options_gave_it() {
        // The reason the table is read from the keymap instead of written
        // down: an option moves a position from one modifier to another.
        // With alt and super swapped, LALT is Mod4 and LWIN is Mod1 — the
        // exact reverse of the assertions above, and a hard-coded table
        // would send Alt where the user pressed Super.
        let text = compile_keymap(&XkbConfig {
            options: "altwin:swap_lalt_lwin".into(),
            ..XkbConfig::default()
        })
        .expect("us with altwin:swap_lalt_lwin should compile");
        let codes = parse_keycodes(&text);
        let masks = modifier_masks_for_keymap(&text, &codes);
        assert_eq!(masks.get(&codes["LALT"]), Some(&0b100_0000));
        assert_eq!(masks.get(&codes["LWIN"]), Some(&0b1000));
        // And the modifiers the option does not touch are unmoved.
        assert_eq!(masks.get(&codes["LFSH"]), Some(&0b1));
    }

    #[test]
    fn a_position_that_is_a_modifier_only_by_interpret_still_carries_its_bit() {
        // The limit the old modifier-map reading admitted to: under
        // `lv3:ralt_switch` AltGr emits ISO_Level3_Shift and reaches Mod5
        // through a compat interpret, with no modifier-map entry to read.
        let text = compile_keymap(&XkbConfig {
            options: "lv3:ralt_switch".into(),
            ..XkbConfig::default()
        })
        .expect("us with lv3:ralt_switch should compile");
        let codes = parse_keycodes(&text);
        let masks = modifier_masks_for_keymap(&text, &codes);
        assert_eq!(masks.get(&codes["RALT"]), Some(&0b1000_0000));
    }

    /// Asserts on the characters a client would read, not on a bit pattern:
    /// the mask was wrong in a way that still looked plausible, and only the
    /// letter came out wrong.
    ///
    /// The owner's options are the case that broke.
    /// `shift:both_capslock_cancel` puts Caps_Lock on the second level of the
    /// Shift keys and `grp:caps_toggle` takes CAPS out of Lock, so the
    /// compiled keymap ends up with `modifier_map Lock { <LFSH> }` alongside
    /// `modifier_map Shift { <LFSH>, <RTSH> }`. A mask OR-ed straight out of
    /// the modifier map therefore reported Shift+Lock for a held Shift — and
    /// Shift+Lock on an ALPHABETIC key selects level 1, a lowercase letter.
    /// The number row is TWO_LEVEL and ignores Lock, which is exactly why
    /// digits shifted while letters did not.
    #[test]
    fn a_held_shift_types_a_capital_under_the_owners_options() {
        use xkbcommon::xkb;

        let text = compile_keymap(&XkbConfig {
            layouts: "us,ua".into(),
            options: "shift:both_capslock_cancel,grp:caps_toggle".into(),
            ..XkbConfig::default()
        })
        .expect("the owner's RMLVO should compile");
        let codes = parse_keycodes(&text);
        let masks = modifier_masks_for_keymap(&text, &codes);
        let mask = masks
            .get(&codes["LFSH"])
            .copied()
            .expect("Shift must carry a modifier bit");

        // Stand in for the compositor: a fresh state told what the helper
        // says is held, then asked what the key positions produce.
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let keymap = xkb::Keymap::new_from_string(
            &context,
            text,
            xkb::KEYMAP_FORMAT_TEXT_V1,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .expect("the helper's own keymap text should compile");
        let mut state = xkb::State::new(&keymap);
        state.update_mask(mask, 0, 0, 0, 0, 0);

        let typed = |name: &str| state.key_get_utf8(xkb::Keycode::from(codes[name] + 8));
        assert_eq!(typed("AD01"), "Q", "a held Shift must capitalise a letter");
        // The half that kept working, asserted so a fix that breaks it fails
        // here rather than on the next hand test.
        assert_eq!(typed("AE01"), "!", "a held Shift must shift the number row");
    }

    #[test]
    fn parses_both_key_names_and_raw_codes() {
        assert!(matches!(
            parse("tap AD01"),
            Some(Command::Tap(Key::Name(_)))
        ));
        assert!(matches!(parse("tap 16"), Some(Command::Tap(Key::Code(16)))));
        assert!(matches!(
            parse("configure\tevdev\tpc105\tus,ua\t,unicode\tgrp:caps_toggle\t\t1"),
            Some(Command::Configure(XkbConfig { group: 1, .. }))
        ));
        assert!(parse("nonsense").is_none());
    }
}
