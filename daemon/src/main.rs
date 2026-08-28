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
//!   tap <code>        press and release an evdev keycode
//!   down <code>       press
//!   up <code>         release
//!   mods <mask>       set the modifier mask (depressed group)
//!   ping              replies `pong`
//! Replies are `ok`, `pong`, or `err <reason>`.

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

enum Command {
    Tap(u32),
    Down(u32),
    Up(u32),
    Mods(u32),
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
}

type SharedRef = Arc<Mutex<Shared>>;

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

fn socket_path() -> PathBuf {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    let display = std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".to_string());
    PathBuf::from(dir).join(format!("omarchy-osk.{display}.sock"))
}

fn parse(line: &str) -> Option<Command> {
    let mut parts = line.split_whitespace();
    let verb = parts.next()?;
    let arg = || parts.clone().next().and_then(|value| value.parse::<u32>().ok());
    match verb {
        "tap" => arg().map(Command::Tap),
        "down" => arg().map(Command::Down),
        "up" => arg().map(Command::Up),
        "mods" => arg().map(Command::Mods),
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
    for line in BufReader::new(stream).lines().map_while(Result::ok) {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if line == "ping" {
            let _ = writeln!(out, "pong");
            continue;
        }
        let reply = match parse(line) {
            Some(command) => apply(&shared, &connection, command),
            None => "err unknown command",
        };
        let _ = writeln!(out, "{reply}");
    }
}

fn apply(shared: &SharedRef, connection: &Connection, command: Command) -> &'static str {
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

    match command {
        // Codes go out exactly as given: zwp_virtual_keyboard_v1.key takes an
        // evdev keycode, the same numbering wl_keyboard reports, which is the
        // xkb keycode minus 8. Callers speak evdev (KEY_Q = 16).
        Command::Tap(code) => {
            keyboard.key(stamp(), code, 1);
            keyboard.key(stamp(), code, 0);
        }
        Command::Down(code) => keyboard.key(stamp(), code, 1),
        Command::Up(code) => keyboard.key(stamp(), code, 0),
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
fn run(mut queue: EventQueue<State>, mut state: State) {
    while queue.blocking_dispatch(&mut state).is_ok() {}
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

    let path = socket_path();
    // A stale socket from a killed daemon would make bind fail; nothing else
    // owns this name, so removing it is safe.
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    eprintln!("listening on {}", path.display());

    let socket_shared = Arc::clone(&shared);
    let socket_connection = connection.clone();
    thread::spawn(move || serve(listener, socket_shared, socket_connection));
    run(queue, state);
    Ok(())
}
