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
//!   hello <version>   readiness gate, replies `ready <version>`
//!   ping              replies `pong`
//!   tap <key>         press and release; <key> is an xkb name (AD01) or an
//!                     evdev code (16)
//!   down <key>        press
//!   up <key>          release
//!   mods <mask>       set the modifier mask
//!   group <n>         select which compiled layout to type in
//!   configure<TAB>rules<TAB>model<TAB>layouts<TAB>variants<TAB>options
//!             <TAB>kb_file<TAB>group
//! Replies are `ok`, `ready <n>`, `pong`, or `err <reason>`.

use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
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
const PROTOCOL_VERSION: u32 = 2;

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
    /// Which compiled layout is active.
    group: u32,
    config: Option<XkbConfig>,
    held: std::collections::HashSet<u32>,
    uploads: std::collections::VecDeque<Instant>,
}

impl Shared {
    /// Everything that must be true before a key can actually land.
    fn is_ready(&self) -> bool {
        self.keyboard.is_some() && self.ready && !self.codes.is_empty()
    }

    /// Compiles `layouts` and installs the result. Held by the caller's lock so
    /// a keystroke can never observe a half-swapped keymap.
    fn install_config(&mut self, config: &XkbConfig) -> bool {
        if self
            .config
            .as_ref()
            .is_some_and(|current| current.same_keymap(config))
        {
            self.group = config.group;
            if let Some(keyboard) = self.keyboard.as_ref() {
                keyboard.modifiers(0, 0, 0, self.group);
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
            for code in self.held.drain() {
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

    for line in BufReader::new(stream).lines().map_while(Result::ok) {
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
        let reply = match parse(line) {
            Some(command) => apply(&shared, &connection, command, Some(&mut held)),
            None => "err unknown command",
        };
        let _ = writeln!(out, "{reply}");
    }

    release_all(&shared, &connection, held);
}

/// Releases whatever a departing client left pressed and zeroes the modifier
/// mask, so a dropped connection cannot strand the session with a stuck key.
fn release_all(shared: &SharedRef, connection: &Connection, held: Vec<u32>) {
    for code in held {
        apply(shared, connection, Command::Up(Key::Code(code)), None);
    }
    apply(shared, connection, Command::Mods(0), None);
}

fn apply(
    shared: &SharedRef,
    connection: &Connection,
    command: Command,
    mut held: Option<&mut Vec<u32>>,
) -> &'static str {
    let mut shared = shared.lock().unwrap();

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

    // The compositor only orders events by this stamp, so a counter is enough
    // and saves a clock syscall per keystroke.
    static COUNTER: AtomicU32 = AtomicU32::new(1);
    let stamp = || COUNTER.fetch_add(1, Ordering::Relaxed);

    // Codes go out as evdev numbers, the xkb keycode minus 8.
    let resolve = |key: &Key| match key {
        Key::Code(code) => Some(*code),
        Key::Name(name) => shared.codes.get(name).copied(),
    };

    let mut pressed = None;
    let mut released = None;

    match command {
        Command::Tap(ref key) => match resolve(key) {
            Some(code) => {
                keyboard.key(stamp(), code, 1);
                keyboard.key(stamp(), code, 0);
            }
            None => return "err unknown key",
        },
        Command::Down(ref key) => match resolve(key) {
            Some(code) => {
                keyboard.key(stamp(), code, 1);
                shared.held.insert(code);
                pressed = Some(code);
            }
            None => return "err unknown key",
        },
        Command::Up(ref key) => match resolve(key) {
            Some(code) => {
                keyboard.key(stamp(), code, 0);
                shared.held.remove(&code);
                released = Some(code);
            }
            None => return "err unknown key",
        },
        // The group rides along with every modifier update: dropping it would
        // silently reset the device to the first layout.
        Command::Mods(mask) => keyboard.modifiers(mask, 0, 0, shared.group),
        Command::Group(group) => {
            let keyboard = keyboard.clone();
            shared.group = group;
            keyboard.modifiers(0, 0, 0, group);
        }
        Command::Configure(_) => unreachable!("handled above"),
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
