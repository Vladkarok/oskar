//! Commands applied to the device, and every path that lifts a held key.

use std::time::{Duration, Instant};

use wayland_client::Connection;

use crate::keymap::{compile_keymap_with, hash_bytes, read_kb_file_bounded};
use crate::protocol::{caps_reply, keycap_facts_for_groups, Command, Key};
use crate::seat::{
    persist_user_source, user_source_decision, Locks, OwnFiles, SeatBackend, SourceDecision,
};
use crate::state::{stamp, Hold, Shared, SharedRef};

/// How long a non-modifier code may stay held before the helper lifts it.
/// Fifteen seconds of held backspace is about six hundred
/// repeats; nobody does that with a mouse button, so a hold that long means
/// the panel is alive but wedged.
const DEFAULT_HOLD_CAP: Duration = Duration::from_secs(15);

/// The cap, overridable so the integration seam can assert on it without
/// sleeping fifteen seconds. Read once: a value that changed under a live
/// hold would make the deadline already armed on a client thread a lie.
fn hold_cap() -> Duration {
    static CAP: std::sync::OnceLock<Duration> = std::sync::OnceLock::new();
    *CAP.get_or_init(|| {
        std::env::var("OSKAR_HOLD_CAP_MS")
            .ok()
            .and_then(|raw| raw.trim().parse::<u64>().ok())
            .filter(|ms| *ms > 0)
            .map_or(DEFAULT_HOLD_CAP, Duration::from_millis)
    })
}

/// Whether a group index can be carried by the installed keymap. The
/// caps facts are per-group, so their count is the group count; with nothing
/// installed, no group is valid. An out-of-range `group` from any client is
/// refused without touching device state.
fn group_in_range(group: u32, installed_groups: usize) -> bool {
    installed_groups > 0 && (group as usize) < installed_groups
}

/// The seat's locks, read now for an operation about to send a modifiers
/// request (see `Shared::locked_mask`). Called outside the typing lock:
/// the read waits on the compositor. `None` without a seat backend or an
/// answer.
pub(crate) fn read_locks(seat: Option<&dyn SeatBackend>) -> Option<Locks> {
    match seat?.locks() {
        Ok(locks) => Some(locks),
        Err(error) => {
            eprintln!(
                "could not read the seat's locks ({}); a modifiers request goes out with none",
                error.reply()
            );
            None
        }
    }
}

/// Whether `command` would send a modifiers request: then it needs a lock
/// reading of its own (`read_locks`). Asked under the typing lock and
/// answered for the state seen then; a command that turns out to send one
/// anyway (a keymap swapped in between) goes out with no reading.
fn sends_modifiers(shared: &Shared, command: &Command) -> bool {
    match command {
        Command::Mods(_) | Command::Group(_) | Command::Configure(_) => true,
        Command::Down(key) | Command::Up(key) => {
            let code = match key {
                Key::Code(code) => Some(*code),
                Key::Name(name) => shared.codes.get(name).copied(),
            };
            code.is_some_and(|code| shared.modifier_masks.contains_key(&code))
        }
        Command::Tap(_) | Command::Caps { .. } => false,
    }
}

/// Releases whatever a departing client left pressed and, when nothing is
/// held any more, zeroes the modifier mask — so a dropped connection cannot
/// strand the session with a stuck key, while a surviving connection's
/// chord survives a neighbour disconnecting. The whole cleanup runs under
/// one lock acquisition: an emptiness check followed by a separate
/// re-locked `mods` would admit another connection's claim in between and
/// clear the mask out from under it.
pub(crate) fn release_all(
    shared: &SharedRef,
    connection: &Connection,
    held: Vec<u32>,
    conn_id: u64,
    seat: Option<&dyn SeatBackend>,
) {
    // Only a connection that held something can send a modifiers request.
    let locks = if held.is_empty() { None } else { read_locks(seat) };
    let mut shared = shared.lock().unwrap();
    let mut released_any = false;
    for code in held {
        let before = shared.held.contains_key(&code);
        apply_locked(
            &mut shared,
            connection,
            Command::Up(Key::Code(code)),
            None,
            conn_id,
            locks,
        );
        released_any |= before;
    }
    // The mask is zeroed only when this connection's departure actually
    // lifted something: a manual `mods <mask>` carries no claim, and a
    // connection that held nothing must not wipe a survivor's mask.
    if released_any && shared.held.is_empty() {
        apply_locked(&mut shared, connection, Command::Mods(0), None, conn_id, locks);
    }
}

/// When the client thread must next wake to enforce the cap: the earliest
/// expiry among the non-modifier codes this connection is claiming, or `None`
/// when it holds nothing capped. `None` means the read blocks with no deadline
/// at all, which is what keeps this from being a poll — an idle connection
/// wakes zero times, and a holding one wakes once.
pub(crate) fn hold_deadline(shared: &SharedRef, conn_id: u64) -> Option<Instant> {
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

pub(crate) fn expire_stuck_keys(shared: &SharedRef, connection: &Connection) -> Vec<u32> {
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

/// Lifts every code the device is holding, zeroes the modifier mask and
/// flushes, so nothing is left pressed when this process stops.
///
/// Every other way of losing a hold is already covered — a departing client
/// runs `release_all`, a wedged one is caught by the cap in
/// `expire_stuck_keys`, a keymap-changing configure drains in
/// `install_config` — and all three run on a thread that dies with the
/// process. Hyprland does not lift a destroyed keyboard's presses, so without
/// this a SIGTERM mid-press leaves the key repeating for the rest of the
/// session, and a restarted helper cannot clear it (its keyboard is a new
/// object).
///
/// Unconditional rather than per-claim, like the cap: the device holds a key
/// once, so lifting it means dropping every claim on it. Modifiers are not
/// exempt here — the cap exempts them because a locked Shift is meant to stay
/// down, and that reason ends with the process.
///
/// Returns the codes it lifted, so the caller can say what happened rather
/// than claim a release that had nothing to release.
pub(crate) fn release_everything(
    shared_arc: &SharedRef,
    connection: &Connection,
    seat: Option<&dyn SeatBackend>,
) -> Vec<u32> {
    // Close the command gate under the lock used by every command. From
    // this instant a client thread can only receive `err shutting down`;
    // a command already under the lock completes or is refused, and
    // nothing new starts while the release round-trips — the gate closes
    // first precisely so the release is the last writer.
    {
        let mut shared = shared_arc.lock().unwrap();
        shared.shutting_down = true;
    }
    // Read with the gate already closed: no command can change the device
    // between this reading and the release below.
    let locks = read_locks(seat);
    let mut shared = shared_arc.lock().unwrap();
    let Some(keyboard) = shared.keyboard.clone() else {
        return Vec::new();
    };
    let held: Vec<u32> = shared.held.keys().copied().collect();
    for code in &held {
        shared.held.remove(code);
        keyboard.key(stamp(), *code, 0);
    }
    keyboard.modifiers(0, 0, shared.locked_mask(locks), shared.group);
    // The lock is dropped before the round trip: it blocks on the compositor,
    // and holding `shared` across that would stall any client thread still
    // serving a line.
    drop(shared);
    // A round trip, not a flush. `flush` only writes the bytes; the process
    // then exits and closes the connection, and a compositor that reaches the
    // disconnect with the release still unread destroys the virtual keyboard
    // holding the key. The sync callback is the proof that the compositor
    // processed the release before this process leaves.
    let _ = connection.roundtrip();
    held
}

pub(crate) fn apply(
    shared: &SharedRef,
    connection: &Connection,
    command: Command,
    held: Option<&mut Vec<u32>>,
    conn_id: u64,
    seat: Option<&dyn SeatBackend>,
) -> String {
    // A command that sends a modifiers request reads the seat's locks
    // first, outside the lock: the reading waits on the compositor.
    let reads = sends_modifiers(&shared.lock().unwrap(), &command);
    let locks = if reads { read_locks(seat) } else { None };
    // Every command runs under the lock; the lock is held only for bounded
    // work — compiles pay the churn budget at the gate.
    let mut guard = shared.lock().unwrap();
    apply_locked(&mut guard, connection, command, held, conn_id, locks)
}

fn apply_locked(
    shared: &mut Shared,
    connection: &Connection,
    command: Command,
    held: Option<&mut Vec<u32>>,
    conn_id: u64,
    locks: Option<Locks>,
) -> String {
    if shared.shutting_down {
        return "err shutting down".to_string();
    }
    if let Command::Configure(ref config) = command {
        // Record the user's own `kb_file` source before anything else
        // happens to it. Recorded from what the panel sends
        // — the intent — and not from whether this compile succeeds: even
        // a refused configure is evidence of what the user had configured,
        // and the recovery read happens on a shell that no longer has the
        // value anywhere else.
        if let Some(own) = OwnFiles::from_env() {
            let dir = own.dir();
            let decision =
                user_source_decision(&config.kb_file, &shared.compositor_kb_file);
            let outcome = match decision {
                SourceDecision::Remember(path) => persist_user_source(dir, Some(&path)),
                SourceDecision::Clear => persist_user_source(dir, None),
                SourceDecision::Leave => Ok(()),
            };
            if let Err(error) = outcome {
                eprintln!("[oskar] could not record the user keymap source: {error}");
            }
        }
        // A group the configure's own map cannot carry is refused whole,
        // with no device state changed. Bounded by the incoming map, never
        // the installed one, or a correct grow (one group to two) would be
        // refused. A custom keymap's groups are asked of the one bounded
        // snapshot that will also be installed, so the ceiling and the map
        // cannot describe two different files.
        let kb_file_bytes = if config.kb_file.is_empty() {
            None
        } else {
            match read_kb_file_bounded(&config.kb_file) {
                Some(bytes) => Some(bytes),
                // Unreadable now is refused now: the install would refuse
                // the same map one round later anyway.
                None => return "err cannot configure keymap".to_string(),
            }
        };
        // An unchanged keymap skips the ceiling compile entirely, so group
        // flips never pay a compile under the lock. The installed map's own
        // group count is the ceiling that fits it.
        let mark = kb_file_bytes.as_deref().map(hash_bytes);
        let unchanged = shared.config.as_ref().is_some_and(|c| c.same_keymap(config))
            && shared.kb_file_mark == mark;
        if !unchanged {
            // Compile attempts pay the churn budget here, before any work,
            // so a file engineered to fail late in parse is still rate
            // limited. This is the only churn accounting.
            let now = Instant::now();
            while shared
                .uploads
                .front()
                .is_some_and(|at| now.duration_since(*at) > Duration::from_secs(10))
            {
                shared.uploads.pop_front();
            }
            if shared.uploads.len() >= 4 {
                eprintln!("refusing excessive keymap reconfiguration");
                return "err cannot configure keymap".to_string();
            }
            shared.uploads.push_back(now);
        }
        // One compile serves the whole changed path: the ceiling counts it,
        // the install uploads it. Two compiles would cost double under the
        // lock and could disagree if the system xkb database changed in
        // between; one text makes the ceiling the installed map's count.
        let group_ceiling;
        let compiled: Option<String>;
        if unchanged {
            group_ceiling = shared.caps_per_group.len().max(1);
            compiled = None;
        } else {
            let Some(text) = compile_keymap_with(config, kb_file_bytes.as_deref()) else {
                return "err cannot configure keymap".to_string();
            };
            group_ceiling = keycap_facts_for_groups(&text).len().max(1);
            compiled = Some(text);
        }
        if !group_in_range(config.group, group_ceiling) {
            return "err bad group".to_string();
        }
        let installed =
            shared.install_config(config, kb_file_bytes.as_deref(), compiled.as_deref(), locks);
        let _ = connection.flush();
        // The generation rides on the reply: it is what the
        // panel correlates its keycap facts against, and a same-keymap
        // reconfigure deliberately answers with the generation it kept.
        return if installed {
            format!("configured\t{}", shared.caps_gen)
        } else {
            "err cannot configure keymap".to_string()
        };
    }

    let Some(keyboard) = shared.keyboard.as_ref() else {
        return "err no virtual keyboard".to_string();
    };
    if !shared.ready {
        return "err no keymap yet".to_string();
    }

    // Held-key bookkeeping below mutates `shared`, so drop the borrow the
    // proxy carries by cloning it — proxies are cheap handles.
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
                    return "err key held".to_string();
                }
                keyboard.key(stamp(), code, 1);
                keyboard.key(stamp(), code, 0);
            }
            None => return "err unknown key".to_string(),
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
            None => return "err unknown key".to_string(),
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
                            return "err not holding".to_string();
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
            None => return "err unknown key".to_string(),
        },
        // The group rides along with every modifier update: dropping it would
        // silently reset the device to the first layout.
        Command::Mods(mask) => {
            keyboard.modifiers(mask, 0, shared.locked_mask(locks), shared.group)
        }
        // A language switch mid-chord must not drop what is held, so the
        // group goes out alongside the mask the held keys imply rather than
        // alongside a zero.
        Command::Group(group) => {
            if !group_in_range(group, shared.caps_per_group.len()) {
                return "err bad group".to_string();
            }
            let keyboard = keyboard.clone();
            shared.group = group;
            keyboard.modifiers(shared.modifier_mask(), 0, shared.locked_mask(locks), group);
        }
        // Facts, not keys: nothing is pressed, nothing is held, and the
        // answer is read out of the installed keymap's pre-resolved records.
        // The group is validated rather than wrapped — xkb would silently
        // answer another group's facts for a past-the-count group.
        Command::Caps { group, positions } => {
            let _ = keyboard;
            return match caps_reply(shared.caps_gen, &shared.caps_per_group, group, &positions) {
                Some(reply) => reply,
                None => "err bad group".to_string(),
            };
        }
        Command::Configure(_) => unreachable!("handled above"),
    }

    // A key event carries no modifier state of its own. The compositor learns
    // what is held from `modifiers` and from nothing else, so a chord that was
    // only ever pressed and released arrives modifierless (`down LFSH / tap
    // AD01 / up LFSH` would type `q`). Re-assert the mask whenever a modifier
    // code goes down or comes up, and the tap in between lands under it.
    if let Some(code) = pressed.or(released) {
        if shared.modifier_masks.contains_key(&code) {
            keyboard.modifiers(
                shared.modifier_mask(),
                0,
                shared.locked_mask(locks),
                shared.group,
            );
        }
    }

    if let Some(held) = held {
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
    "ok".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keymap::compile_keymap_with;
    use crate::protocol::parse;
    use crate::seat::{EventSink, Keyboard, SeatError};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;

    /// A seat backend that answers only the lock reading, with whatever the
    /// test sets, and counts how often it was asked.
    struct FakeLocks {
        reading: Mutex<Result<Locks, SeatError>>,
        asked: AtomicUsize,
        gate: Mutex<()>,
    }

    impl FakeLocks {
        fn new(reading: Result<Locks, SeatError>) -> Self {
            FakeLocks {
                reading: Mutex::new(reading),
                asked: AtomicUsize::new(0),
                gate: Mutex::new(()),
            }
        }
        fn set(&self, reading: Result<Locks, SeatError>) {
            *self.reading.lock().unwrap() = reading;
        }
        fn asked(&self) -> usize {
            self.asked.load(Ordering::SeqCst)
        }
    }

    impl SeatBackend for FakeLocks {
        fn keyboards(&self) -> Result<Vec<Keyboard>, SeatError> {
            Err(SeatError::NoBackend)
        }
        fn locks(&self) -> Result<Locks, SeatError> {
            self.asked.fetch_add(1, Ordering::SeqCst);
            self.reading.lock().unwrap().clone()
        }
        fn kb_file(&self) -> Result<String, SeatError> {
            Err(SeatError::NoBackend)
        }
        fn kb_file_by(&self, _deadline: Instant) -> Result<String, SeatError> {
            Err(SeatError::NoBackend)
        }
        fn switch_group(&self, _device: &str, _group: u32) -> Result<(), SeatError> {
            Err(SeatError::NoBackend)
        }
        fn write_kb_file(&self, _value: &str, _deadline: Instant) -> Result<(), SeatError> {
            Err(SeatError::NoBackend)
        }
        fn confirm_kb_file(
            &self,
            _value: &str,
            _deadline: Instant,
            _stopping: &dyn Fn() -> bool,
        ) -> Result<(), SeatError> {
            Err(SeatError::NoBackend)
        }
        fn kb_file_gate(&self) -> &Mutex<()> {
            &self.gate
        }
        fn watch(self: std::sync::Arc<Self>, _sink: std::sync::Arc<dyn EventSink>) {}
    }

    /// A ready virtual keyboard bound on an unconnected socket pair, whose
    /// requests are read back off the other end. Its keymap state is set up
    /// by hand rather than installed: an install publishes into the live
    /// session's runtime directory.
    struct Wire {
        connection: Connection,
        theirs: std::os::unix::net::UnixStream,
        shared: SharedRef,
        keyboard: u32,
        /// The keymap text the state was built from.
        text: String,
        _queue: wayland_client::EventQueue<crate::state::State>,
    }

    impl Wire {
        fn new(layouts: &str) -> Self {
            use crate::keymap::{
                lock_bits_for_keymap, modifier_masks_for_keymap, parse_keycodes, XkbConfig,
            };
            use wayland_client::protocol::wl_seat::WlSeat;
            use wayland_client::Proxy;
            use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1;

            let (ours, theirs) = std::os::unix::net::UnixStream::pair().unwrap();
            theirs.set_nonblocking(true).unwrap();
            let connection = Connection::from_socket(ours).unwrap();
            let queue = connection.new_event_queue::<crate::state::State>();
            let qh = queue.handle();
            let registry = connection.display().get_registry(&qh, ());
            let seat: WlSeat = registry.bind(1, 7, &qh, ());
            let manager: ZwpVirtualKeyboardManagerV1 = registry.bind(2, 1, &qh, ());
            let keyboard = manager.create_virtual_keyboard(&seat, &qh, ());
            let config = XkbConfig {
                layouts: layouts.to_string(),
                ..XkbConfig::default()
            };
            let text = compile_keymap_with(&config, None).expect("the fixture compiles");
            let mut shared = Shared {
                keyboard: Some(keyboard.clone()),
                ready: true,
                codes: parse_keycodes(&text),
                lock_bits: lock_bits_for_keymap(&text),
                caps_per_group: keycap_facts_for_groups(&text),
                config: Some(config),
                ..Shared::default()
            };
            shared.modifier_masks = modifier_masks_for_keymap(&text, &shared.codes);
            let wire = Wire {
                connection,
                theirs,
                shared: std::sync::Arc::new(Mutex::new(shared)),
                keyboard: keyboard.id().protocol_id(),
                text,
                _queue: queue,
            };
            wire.modifiers();
            wire
        }

        /// The bit the compositor's reading names, resolved by that name in
        /// the keymap under test.
        fn bit(&self, name: &str) -> u32 {
            use xkbcommon::xkb;
            let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
            let compiled = xkb::Keymap::new_from_string(
                &context,
                self.text.clone(),
                xkb::KEYMAP_FORMAT_TEXT_V1,
                xkb::KEYMAP_COMPILE_NO_FLAGS,
            )
            .expect("the fixture compiles");
            1u32 << compiled.mod_get_index(name)
        }

        /// Every `modifiers` request (depressed, latched, locked, group) the
        /// keyboard sent since the last call.
        fn modifiers(&self) -> Vec<[u32; 4]> {
            use std::io::Read;
            let _ = self.connection.flush();
            let mut bytes = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                match (&self.theirs).read(&mut chunk) {
                    Ok(0) => break,
                    Ok(n) => bytes.extend_from_slice(&chunk[..n]),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(error) => panic!("reading the wire: {error}"),
                }
            }
            let word = |at: usize| u32::from_ne_bytes(bytes[at..at + 4].try_into().unwrap());
            let mut found = Vec::new();
            let mut at = 0;
            while at + 8 <= bytes.len() {
                let (object, header) = (word(at), word(at + 4));
                let (size, opcode) = ((header >> 16) as usize, header & 0xffff);
                // zwp_virtual_keyboard_v1.modifiers is request 2.
                if object == self.keyboard && opcode == 2 {
                    found.push([word(at + 8), word(at + 12), word(at + 16), word(at + 20)]);
                }
                at += size.max(8);
            }
            found
        }

        fn apply(&self, line: &str, held: &mut Vec<u32>, seat: Option<&dyn SeatBackend>) -> String {
            apply(&self.shared, &self.connection, parse(line).unwrap(), Some(held), 1, seat)
        }
    }

    const NUM: Locks = Locks {
        caps: false,
        num: true,
    };
    const BOTH: Locks = Locks {
        caps: true,
        num: true,
    };

    /// The compositor forwards a modifiers request's whole state to the
    /// focused client, so every request carries the seat's locks as read
    /// for it, at the bits the compositor's reading names: a panel Shift
    /// click, its release, the hello's `mods 0` and a `group` must leave
    /// the user's NumLock and Caps Lock where they were.
    #[test]
    fn every_modifiers_request_carries_the_seats_locks() {
        let wire = Wire::new("us,ua");
        let (lock, num) = (wire.bit("Lock"), wire.bit("Mod2"));
        assert_ne!(lock, num);
        let seat = FakeLocks::new(Ok(NUM));
        let mut held = Vec::new();

        assert_eq!(wire.apply("down LFSH", &mut held, Some(&seat)), "ok");
        let shift = wire.modifiers();
        assert_eq!(shift.len(), 1, "a Shift press re-asserts the mask once");
        assert_ne!(shift[0][0], 0, "Shift is depressed");
        assert_eq!(shift[0][2], num, "NumLock stays on under a panel Shift");

        seat.set(Ok(BOTH));
        assert_eq!(wire.apply("up LFSH", &mut held, Some(&seat)), "ok");
        assert_eq!(wire.modifiers(), [[0, 0, lock | num, 0]]);
        assert_eq!(wire.apply("mods 0", &mut held, Some(&seat)), "ok");
        assert_eq!(wire.modifiers(), [[0, 0, lock | num, 0]]);
        assert_eq!(wire.apply("group 1", &mut held, Some(&seat)), "ok");
        assert_eq!(wire.modifiers(), [[0, 0, lock | num, 1]]);
    }

    /// A layout follow is a same-keymap configure: only the group moves, and
    /// the request that moves it carries the locks.
    #[test]
    fn a_layout_follow_carries_the_seats_locks() {
        let wire = Wire::new("us,ua");
        let seat = FakeLocks::new(Ok(NUM));
        let mut config = wire.shared.lock().unwrap().config.clone().unwrap();
        config.group = 1;
        let follow = Command::Configure(config.clone());
        assert!(sends_modifiers(&wire.shared.lock().unwrap(), &follow));
        let locks = read_locks(Some(&seat));
        assert!(wire.shared.lock().unwrap().install_config(&config, None, None, locks));
        assert_eq!(wire.modifiers(), [[0, 0, wire.bit("Mod2"), 1]]);
    }

    /// Every operation reads the locks for itself. A lock toggled on a
    /// physical keyboard raises no compositor event, so a reading kept from
    /// an earlier operation would put back a NumLock the user turned off.
    #[test]
    fn each_operation_reads_the_locks_afresh() {
        let wire = Wire::new("us");
        let num = wire.bit("Mod2");
        let seat = FakeLocks::new(Ok(NUM));
        let mut held = Vec::new();
        wire.apply("down LFSH", &mut held, Some(&seat));
        assert_eq!(wire.modifiers()[0][2], num);
        // The user turns NumLock off on the physical keyboard.
        seat.set(Ok(Locks::default()));
        wire.apply("up LFSH", &mut held, Some(&seat));
        assert_eq!(wire.modifiers(), [[0, 0, 0, 0]], "the old reading is not reused");
        assert_eq!(seat.asked(), 2);
    }

    /// Without a reading of its own an operation sends no lock: never a
    /// reading kept from an earlier operation, which could be stale either
    /// way.
    #[test]
    fn without_a_fresh_reading_no_lock_is_sent() {
        let wire = Wire::new("us");
        let seat = FakeLocks::new(Ok(BOTH));
        let mut held = Vec::new();
        wire.apply("down LFSH", &mut held, Some(&seat));
        assert_ne!(wire.modifiers()[0][2], 0);
        seat.set(Err(SeatError::Unreachable));
        wire.apply("up LFSH", &mut held, Some(&seat));
        assert_eq!(wire.modifiers(), [[0, 0, 0, 0]]);
        wire.apply("mods 0", &mut held, None);
        assert_eq!(wire.modifiers(), [[0, 0, 0, 0]], "no seat backend, no lock");
    }

    /// Keys that send no modifiers request never wait on the compositor.
    #[test]
    fn plain_keys_do_not_ask_for_the_locks() {
        let wire = Wire::new("us");
        let seat = FakeLocks::new(Ok(NUM));
        let mut held = Vec::new();
        assert_eq!(wire.apply("tap AD01", &mut held, Some(&seat)), "ok");
        assert_eq!(wire.apply("down AD01", &mut held, Some(&seat)), "ok");
        assert_eq!(wire.apply("up AD01", &mut held, Some(&seat)), "ok");
        assert_eq!(wire.apply("caps 0", &mut held, Some(&seat)).split('\t').next(), Some("caps"));
        assert_eq!(seat.asked(), 0);
        assert!(wire.modifiers().is_empty());
    }

    /// A departing client's release and the shutdown release are modifiers
    /// requests too, and carry the locks read for them.
    #[test]
    fn the_releases_carry_the_seats_locks() {
        let wire = Wire::new("us");
        let num = wire.bit("Mod2");
        let seat = FakeLocks::new(Ok(NUM));
        let mut held = Vec::new();
        wire.apply("down LFSH", &mut held, Some(&seat));
        wire.modifiers();
        release_all(&wire.shared, &wire.connection, held, 1, Some(&seat));
        let released = wire.modifiers();
        assert!(!released.is_empty());
        assert!(released.iter().all(|request| request[2] == num), "{released:?}");
        assert_eq!(released.last().unwrap()[0], 0);

        // The shutdown release ends in a round trip; a compositor end that
        // has hung up answers it at once with an error.
        wire.theirs.shutdown(std::net::Shutdown::Write).unwrap();
        assert!(release_everything(&wire.shared, &wire.connection, Some(&seat)).is_empty());
        assert_eq!(wire.modifiers(), [[0, 0, num, 0]]);
    }

    /// Shutdown closes the command gate before it releases anything, so the
    /// release is the last writer: every command after it — a keystroke
    /// included — is refused with `err shutting down` and never reaches the
    /// device. Neither path touches the connection (no keyboard is bound
    /// yet), so an unconnected socket pair stands in for the compositor.
    #[test]
    fn shutdown_refuses_every_later_command() {
        let (ours, _theirs) = std::os::unix::net::UnixStream::pair().unwrap();
        let connection = Connection::from_socket(ours).unwrap();
        let shared: SharedRef = std::sync::Arc::new(std::sync::Mutex::new(Shared::default()));
        assert_ne!(
            apply(&shared, &connection, Command::Mods(0), None, 1, None),
            "err shutting down",
            "an open gate serves commands"
        );
        assert!(release_everything(&shared, &connection, None).is_empty());
        assert!(shared.lock().unwrap().shutting_down, "the release closes the gate");
        for command in [Command::Mods(0), Command::Group(0), parse("tap AD01").unwrap()] {
            assert_eq!(apply(&shared, &connection, command, None, 1, None), "err shutting down");
        }
    }

    /// The installed keymap's group count is the authority for what a
    /// `group` command may carry. Nothing installed
    /// (an empty caps table) validates nothing.
    #[test]
    fn group_bounds_come_from_the_installed_keymap() {
        assert!(group_in_range(0, 1), "a one-group map carries group 0");
        assert!(group_in_range(1, 2));
        assert!(!group_in_range(2, 2), "two groups stop before 2");
        assert!(!group_in_range(9, 2));
        assert!(!group_in_range(0, 0), "nothing installed validates nothing");
    }

    #[test]
    fn a_configures_group_is_bounded_by_its_own_compiled_map() {
        // The incoming map is the authority: the ceiling counts what the
        // configure compiles to, never the declaration — classic evdev drops
        // layouts past the fourth. A grow from one group to two must not be
        // refused for the old map's count.
        let count = |layouts: &str| {
            match parse(&format!("configure\tevdev\tpc105\t{layouts}\t\t\t\t0")) {
                Some(Command::Configure(config)) => {
                    let text = compile_keymap_with(&config, None)
                        .expect("the fixture compiles");
                    keycap_facts_for_groups(&text).len()
                }
                other => panic!("expected a configure, got {other:?}"),
            }
        };
        assert_eq!(count("us"), 1);
        assert_eq!(count("us,ua"), 2);
        assert_eq!(count("us,ua,de,ru"), 4);
        // Separators are not layouts; a file-only configure still
        // compiles one group and carries group 0.
        assert_eq!(count("us,"), 1);
        assert!(group_in_range(1, 2));
        assert!(!group_in_range(2, 2), "two groups stop before 2");
        assert!(group_in_range(0, 1));
    }

    /// The RMLVO ceiling counts the compiled map, never the declaration —
    /// classic evdev rules resolve only layout[1..=4], so five declared
    /// layouts compile to four groups and a group-4 configure must be
    /// refused, or it would type group 0's alphabet under the fifth
    /// language's name. This is the path apply's configure arm walks.
    #[test]
    fn rmlvo_ceiling_counts_the_compiled_map_not_the_declaration() {
        let layouts = "us,ru,ua,it,fr";
        let declared = layouts.split(',').filter(|s| !s.trim().is_empty()).count();
        assert_eq!(declared, 5, "the fixture must declare five");
        match parse("configure\tevdev\tpc105\tus,ru,ua,it,fr\t\t\t\t0") {
            Some(Command::Configure(config)) => {
                let text = compile_keymap_with(&config, None)
                    .expect("the five-layout declaration compiles");
                assert_eq!(keycap_facts_for_groups(&text).len(), 4);
            }
            other => panic!("expected a configure, got {other:?}"),
        }
    }
}
