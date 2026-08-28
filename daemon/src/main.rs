//! Persistent virtual keyboard for the on-screen keyboard plugin.
//!
//! Why this exists at all, in two parts.
//!
//! Speed: the plugin used to spawn a `wtype` process per keystroke. A fork and
//! exec per key is tens of milliseconds and shows up as a laggy keyboard, and
//! the Omarchy plugin guide asks plugins not to launch shell processes. One
//! long-lived helper replaces all of them.
//!
//! XWayland: `wtype` builds a small synthetic keymap holding just the character
//! it needs, uploads it, types, and exits. Native Wayland clients re-read that
//! keymap and cope; XWayland does not, so keystrokes vanish into Proton games
//! and Electron apps running on XWayland. This daemon never invents a keymap —
//! it takes the seat's own keymap from the compositor and hands that same
//! keymap to its virtual keyboard, so a keycode means exactly what it means on
//! the physical keyboard, everywhere.
//!
//! Protocol, one command per line on a unix socket:
//!   tap <key>         press and release; <key> is an xkb name (AD01) or an
//!                     evdev code (16)
//!   down <key>        press
//!   up <key>          release
//!   mods <mask>       set the modifier mask (depressed group)
//!   hello <version>   readiness gate, replies `ready <version>`
//!   ping              replies `pong`
//! Replies are `ok`, `ready <n>`, `pong`, or `err <reason>`.

use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

use wayland_client::protocol::{wl_keyboard, wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, EventQueue, QueueHandle, WEnum};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1,
    zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
};

/// Reads the keymap the compositor shared. It arrives as a file descriptor the
/// client is expected to map, and a fresh handle is used so the daemon never
/// disturbs the offset of the one being forwarded to the virtual keyboard.
fn read_keymap(file: &std::fs::File, size: u32) -> Option<String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut handle = file.try_clone().ok()?;
    handle.seek(SeekFrom::Start(0)).ok()?;
    let mut buffer = vec![0u8; size as usize];
    handle.read_exact(&mut buffer).ok()?;
    // The text is NUL terminated; trim so the parser is not handed a stray byte.
    while buffer.last() == Some(&0) {
        buffer.pop();
    }
    String::from_utf8(buffer).ok()
}

/// A key is named the way xkb names it (`AD01`) or given as a raw evdev code.
/// Names are preferred: the QML side already labels keys by xkb position, and
/// resolving them here keeps the numbering in one place.
enum Key {
    Code(u32),
    Name(String),
}

enum Command {
    Tap(Key),
    Down(Key),
    Up(Key),
    Mods(u32),
}

/// Pulls `<AD01> = 24;` pairs out of the keymap's xkb_keycodes section.
///
/// Callers name keys the way xkb does, and the numbers are resolved here rather
/// than in the QML client: the keymap in hand is the authority, so a layout that
/// numbers keys unusually still works and there is no second table to keep in
/// step. Names map to evdev codes, which are the xkb codes minus 8.
fn parse_keycodes(keymap: &str) -> std::collections::HashMap<String, u32> {
    let mut codes = std::collections::HashMap::new();
    let Some(section) = keymap.split("xkb_keycodes").nth(1) else {
        return codes;
    };
    let section = section.split("};").next().unwrap_or(section);

    for line in section.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix('<') else { continue };
        let Some((name, rest)) = rest.split_once('>') else { continue };
        let Some((_, value)) = rest.split_once('=') else { continue };
        let value = value.trim().trim_end_matches(';').trim();
        if let Ok(code) = value.parse::<u32>() {
            if let Some(evdev) = code.checked_sub(8) {
                codes.insert(name.to_string(), evdev);
            }
        }
    }
    codes
}

/// What the socket threads need. Wayland proxies are Send + Sync and the
/// connection serialises requests internally, so client threads can drive the
/// keyboard directly instead of handing work to the event loop. That keeps the
/// main thread free to block on compositor events, which is where it should
/// spend its time: idle, waiting, costing nothing.
#[derive(Default)]
struct Shared {
    keyboard: Option<ZwpVirtualKeyboardV1>,
    /// A virtual keyboard drops key events until it has been given a keymap.
    ready: bool,
    /// xkb key name -> evdev code, taken from the keymap in use.
    codes: std::collections::HashMap<String, u32>,
}

impl Shared {
    /// Everything that must be true before a key can actually land.
    fn is_ready(&self) -> bool {
        self.keyboard.is_some() && self.ready && !self.codes.is_empty()
    }
}

type SharedRef = Arc<Mutex<Shared>>;

/// Bumped whenever the command set changes, so a plugin updated without
/// reinstalling the helper says so instead of failing silently.
const PROTOCOL_VERSION: u32 = 1;

struct State {
    seat: Option<wl_seat::WlSeat>,
    manager: Option<ZwpVirtualKeyboardManagerV1>,
    /// The seat keymap, forwarded verbatim from the compositor. Kept so a
    /// keyboard created after the keymap arrived can still be initialised.
    keymap: Option<(u32, std::fs::File, u32)>,
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
        drop(shared);
        self.push_keymap();
    }

    /// Runs when the keyboard appears and again whenever the compositor hands
    /// us a new keymap. The second case is not optional: the compositor
    /// interprets our keycodes through *our* keymap, so after the user switches
    /// layout a stale keymap would keep producing the old alphabet.
    fn push_keymap(&mut self) {
        let Some((format, file, size)) = self.keymap.as_ref() else {
            return;
        };
        let mut shared = self.shared.lock().unwrap();
        let Some(keyboard) = shared.keyboard.as_ref() else {
            return;
        };
        keyboard.keymap(*format, file.as_fd(), *size);
        shared.ready = true;
        if let Some(text) = read_keymap(file, *size) {
            shared.codes = parse_keycodes(&text);
        }
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
        let wl_registry::Event::Global { name, interface, version } = event else {
            return;
        };
        match interface.as_str() {
            "wl_seat" => {
                let seat: wl_seat::WlSeat =
                    registry.bind(name, version.min(7), qh, ());
                state.seat = Some(seat);
            }
            "zwp_virtual_keyboard_manager_v1" => {
                state.manager = Some(registry.bind(name, 1, qh, ()));
            }
            _ => {}
        }
        state.ensure_keyboard(qh);
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(
        _: &mut Self,
        seat: &wl_seat::WlSeat,
        event: wl_seat::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_seat::Event::Capabilities { capabilities: WEnum::Value(caps) } = event {
            if caps.contains(wl_seat::Capability::Keyboard) {
                // Taking the seat keyboard is the whole point: its keymap event
                // is the compositor's own keymap, which is what makes typed
                // keycodes land correctly in XWayland clients too.
                seat.get_keyboard(qh, ());
            }
        }
    }
}

impl Dispatch<wl_keyboard::WlKeyboard, ()> for State {
    fn event(
        state: &mut Self,
        _: &wl_keyboard::WlKeyboard,
        event: wl_keyboard::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_keyboard::Event::Keymap { format, fd, size } = event {
            let format = match format {
                WEnum::Value(value) => value as u32,
                WEnum::Unknown(raw) => raw,
            };
            state.keymap = Some((format, std::fs::File::from(fd), size));
            state.push_keymap();
            eprintln!("keymap updated ({size} bytes)");
        }
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

/// Fixed path under the runtime directory the service unit declares.
///
/// No fallback to /tmp and no guessing at WAYLAND_DISPLAY: running without a
/// graphical session is a startup failure worth seeing, and a socket in the
/// wrong place would leave a keyboard that connects fine and types nothing.
fn socket_path() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let dir = std::env::var("XDG_RUNTIME_DIR")
        .map_err(|_| "XDG_RUNTIME_DIR is unset; this must run inside a user session")?;
    let dir = PathBuf::from(dir).join("omarchy-osk");
    std::fs::create_dir_all(&dir)?;
    Ok(dir.join("control.sock"))
}

fn parse(line: &str) -> Option<Command> {
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
        _ => None,
    }
}

fn serve(listener: UnixListener, shared: SharedRef, connection: Connection) {
    for stream in listener.incoming().flatten() {
        let shared = Arc::clone(&shared);
        let connection = connection.clone();
        thread::spawn(move || handle_client(stream, shared, connection));
    }
}

fn handle_client(stream: UnixStream, shared: SharedRef, connection: Connection) {
    let Ok(mut out) = stream.try_clone() else { return };
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
        // `hello` is the readiness gate. It deliberately reports more than "the
        // process is up": the client must not enable keys until a virtual
        // keyboard exists AND the compositor keymap has been forwarded to it,
        // because a keyboard without a keymap accepts commands and drops every
        // key. `ping` stays as a plain liveness check.
        if let Some(version) = line.strip_prefix("hello") {
            let wanted: u32 = version.trim().parse().unwrap_or(PROTOCOL_VERSION);
            let reply = if wanted != PROTOCOL_VERSION {
                format!("err protocol {PROTOCOL_VERSION} required, helper needs reinstall")
            } else if shared.lock().unwrap().is_ready() {
                format!("ready {PROTOCOL_VERSION}")
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
    let shared = shared.lock().unwrap();
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

    // Codes go out as evdev numbers, the same numbering wl_keyboard reports,
    // which is the xkb keycode minus 8.
    let resolve = |key: &Key| match key {
        Key::Code(code) => Some(*code),
        Key::Name(name) => shared.codes.get(name).copied(),
    };

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
                if let Some(held) = held.as_deref_mut() {
                    if !held.contains(&code) {
                        held.push(code);
                    }
                }
            }
            None => return "err unknown key",
        },
        Command::Up(ref key) => match resolve(key) {
            Some(code) => {
                keyboard.key(stamp(), code, 0);
                if let Some(held) = held.as_deref_mut() {
                    held.retain(|entry| *entry != code);
                }
            }
            None => return "err unknown key",
        },
        Command::Mods(mask) => keyboard.modifiers(mask, 0, 0, 0),
    }

    // Requests sit in the connection buffer until flushed, and the event loop
    // may be parked with nothing to wake it, so flush here rather than hoping
    // it happens soon.
    let _ = connection.flush();
    "ok"
}

/// Blocks on compositor events for the life of the process. The only events
/// that matter are keymap updates after a layout switch; the rest of the time
/// this thread is asleep in poll, which is the point.
fn run(mut queue: EventQueue<State>, mut state: State) -> Result<(), Box<dyn std::error::Error>> {
    loop {
        // Exit rather than trying to reconnect: the session environment this
        // process was started with is stale once the compositor is gone, and
        // systemd rebuilds connection, registry, keyboard and keymap cleanly.
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
        keymap: None,
        shared: Arc::clone(&shared),
    };

    // Two roundtrips: the first surfaces the globals, the second delivers the
    // seat capabilities and the keymap that follows from binding the keyboard.
    queue.roundtrip(&mut state)?;
    state.ensure_keyboard(&qh);
    queue.roundtrip(&mut state)?;

    if shared.lock().unwrap().keyboard.is_none() {
        return Err("compositor does not offer zwp_virtual_keyboard_manager_v1".into());
    }

    let path = socket_path()?;
    // Refuse to be the second instance. Two daemons on one seat feed each other
    // keymaps forever: every virtual keyboard added changes the seat keymap,
    // the other one observes that change and re-uploads its own, and round it
    // goes. It shows as an endless "keymap updated" log alternating between two
    // sizes, and it burns CPU for as long as both are up.
    //
    // Connecting is the test rather than a lock file, because it tells a live
    // owner apart from a socket left behind by a crash. Unlinking blindly would
    // let a newcomer steal the path from a running daemon.
    if UnixStream::connect(&path).is_ok() {
        return Err(format!("another daemon already owns {}", path.display()).into());
    }
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    eprintln!("listening on {}", path.display());

    let socket_shared = Arc::clone(&shared);
    let socket_connection = connection.clone();
    thread::spawn(move || serve(listener, socket_shared, socket_connection));
    run(queue, state)
}
