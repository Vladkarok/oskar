//! Persistent virtual keyboard for the on-screen keyboard plugin.
//!
//! One long-lived helper holding a complete keymap: per-keystroke spawns are
//! slow, and a small synthetic keymap is ignored by XWayland, so keys would
//! never reach X11 clients.
//!
//! The helper compiles its own keymap and never subscribes to the seat's.
//! Mirroring the seat keymap forms a feedback loop (upload changes the seat,
//! the compositor rebuilds and sends it back) and disturbs layout switching
//! for other applications.
//!
//! One compiled keymap carries every configured layout as a group, so switching
//! language selects a group rather than compiling again. The panel tells the
//! helper which layouts to compile and which group is active. What the helper
//! knows about the compositor's seat — its keyboards, their groups, its
//! kb_file — it reads over the compositor's IPC on the panel's behalf
//! (protocol 7, `seat.rs` and `hyprland.rs`), never from the Wayland seat.
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
//!   caps <group> [positions...]
//!                     keycap facts for the named group of the installed
//!                     keymap: one line, records separated by
//!                     0x1E, fields by 0x1F, each field `t<text>` (resolved
//!                     character text), `x<keysym>` (a symbol that produces no
//!                     character) or `n` (no symbol at this level). Without a
//!                     position list every named key is answered.
//! Protocol 7 only (a `hello 6` connection answers these `err unknown command`):
//!   seat              the compositor's keyboards as `seat<TAB><json>`
//!   switch<TAB>device<TAB>group
//!                     move one keyboard to an absolute group
//!   share<TAB>path    point the compositor's kb_file at a keymap file, or
//!                     clear it with `share<TAB>-`; verified by read-back
//!   events on|off     push `event<TAB>...` lines to this connection
//! Replies are `ok`, `hello <n>`,
//! `configured<TAB><generation>`, `pong`,
//! `keyboards<TAB>name...`, `caps<TAB><generation><TAB><group><TAB><records>`,
//! `seat<TAB><json>`, or `err <reason>`. Pushed events are extra lines that
//! answer no command; protocol.rs documents the framing.
//!
//! The generation is the count of keymap installs this process has performed.
//! It is what the panel correlates its keycap facts against: a same-keymap
//! reconfigure keeps the generation (the installed keymap did not change), a
//! changed one bumps it, so a facts reply computed from a superseded keymap is
//! detectable and discardable. The panel and the helper move protocol
//! versions together, so a mismatched pair fails the hello gate instead of
//! negotiating the wrong reply shapes.
//!
//! Key repeat belongs to the compositor: a press is `down`, a release is `up`,
//! and nothing here or in the panel repeats anything. What the helper does add
//! is a cap — a non-modifier code held past fifteen seconds is lifted and
//! logged, because the only way that happens is a panel that is alive but
//! wedged. Modifier codes are exempt; locked Shift is deliberately held.

mod apply;
mod events;
mod hyprland;
mod json;
mod keymap;
mod protocol;
mod seat;
mod server;
mod state;

use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use wayland_client::{Connection, EventQueue};

use crate::apply::release_everything;
use crate::events::SUBSCRIBERS;
use crate::hyprland::Hyprland;
use crate::seat::{socket_path, EventSink, SeatBackend};
use crate::server::{serve, Seat};
use crate::state::{Shared, SharedRef, State};

/// The signals a shutdown arrives as. SIGTERM is `systemctl stop` and the
/// `PartOf=` teardown; SIGINT is a foreground run; SIGHUP is the session going
/// away underneath one.
const SHUTDOWN_SIGNALS: [libc::c_int; 3] = [libc::SIGTERM, libc::SIGINT, libc::SIGHUP];

fn shutdown_signal_set() -> libc::sigset_t {
    // SAFETY: sigemptyset/sigaddset only write through the pointer they are
    // given, and it points at a zeroed sigset_t owned by this frame.
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        for signal in SHUTDOWN_SIGNALS {
            libc::sigaddset(&mut set, signal);
        }
        set
    }
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

fn run_main() -> Result<(), Box<dyn std::error::Error>> {
    let connection = Connection::connect_to_env()
        .map_err(|e| StartupFailure(e.to_string()))?;
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
        return Err(StartupFailure(reason.to_string()).into());
    }

    // `keyboard.keymap` is asynchronous. Do not expose the control socket until
    // the compositor has processed it; otherwise a fast client can send a
    // modifiers request first and Hyprland terminates the protocol object with
    // "Mods event received before a keymap was set".
    connection.flush()?;
    queue.roundtrip(&mut state)?;

    let path = socket_path().map_err(|e| StartupFailure(e.to_string()))?;
    // Refuse to be the second instance. Connecting is the test rather than a
    // lock file, because it tells a live owner apart from a socket left behind
    // by a crash; unlinking blindly would let a newcomer steal the path from a
    // running daemon and leave both serving.
    if UnixStream::connect(&path).is_ok() {
        return Err(StartupFailure(format!(
            "another daemon already owns {}",
            path.display()
        ))
        .into());
    }
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)
        .map_err(|error| StartupFailure(format!("cannot bind {}: {error}", path.display())))?;
    eprintln!("listening on {}", path.display());

    // The shutdown wait does the release with ordinary Wayland writes on a
    // thread of its own: a signal handler may not touch a mutex or a Wayland
    // queue.
    // Blocked here, not at the top of main: everything above this point is
    // startup, holds no key, and has nothing to release, so the default
    // disposition is right for a signal arriving during it. Blocking earlier
    // would make a hung startup sit out systemd's stop timeout.
    //
    // Before the threads below, so each inherits the block and the wait
    // thread is the only place these signals are ever delivered. Blocking
    // before the sigwait is also what makes the wait sound: a signal arriving
    // in between stays pending instead of killing the process.
    // SAFETY: pthread_sigmask reads the set it is handed and writes nothing
    // else; the null oldset is the documented "do not report" argument.
    unsafe {
        let set = shutdown_signal_set();
        libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
    }

    let signal_shared = Arc::clone(&shared);
    let signal_connection = connection.clone();
    thread::spawn(move || {
        let set = shutdown_signal_set();
        let mut received: libc::c_int = 0;
        // SAFETY: both pointers are to live locals, and these signals are
        // blocked process-wide, which is sigwait's precondition.
        if unsafe { libc::sigwait(&set, &mut received) } != 0 {
            return;
        }
        // The release waits on the compositor, and a compositor that is
        // itself going away (the `PartOf=` teardown) may never answer. The
        // release is best-effort and systemd must not sit through its stop
        // timeout for it, so leaving is bounded either way.
        thread::spawn(|| {
            // Generous against the release's own compositor round-trips:
            // every path under it is bounded well inside this, and an exit
            // that raced a live round-trip could strand the very keys the
            // release exists to lift.
            thread::sleep(Duration::from_secs(6));
            eprintln!("compositor did not acknowledge the shutdown release; leaving anyway");
            std::process::exit(0);
        });
        let lifted = release_everything(&signal_shared, &signal_connection);
        if lifted.is_empty() {
            eprintln!("signal {received}; nothing was held, exiting");
        } else {
            eprintln!("signal {received}; released held keys {lifted:?}, exiting");
        }
        // Straight out rather than unwinding: the main thread is parked in the
        // Wayland queue and has no path back that does not risk sending more
        // key events after the release.
        std::process::exit(0);
    });

    // The seat backend is optional by design: without one the seat verbs
    // answer `err no seat backend`, no events flow, and typing is untouched.
    let seat: Seat = match Hyprland::from_env() {
        Some(hyprland) => {
            let hyprland = Arc::new(hyprland);
            let sink: Arc<dyn EventSink> = Arc::new(&SUBSCRIBERS);
            Arc::clone(&hyprland).watch(sink);
            Some(hyprland as Arc<dyn SeatBackend>)
        }
        None => {
            eprintln!("no Hyprland instance in the environment; seat verbs are off");
            None
        }
    };

    let socket_shared = Arc::clone(&shared);
    let socket_connection = connection.clone();
    thread::spawn(move || serve(listener, socket_shared, socket_connection, seat));
    run(queue, state)
}

/// A failure before the service is up and serving: retrying cannot
/// change it while the session stands, so the unit's
/// RestartPreventExitStatus=78 (EX_CONFIG) makes systemd fail closed
/// instead of spinning StartLimit.
#[derive(Debug)]
struct StartupFailure(String);
impl std::fmt::Display for StartupFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}
impl std::error::Error for StartupFailure {}

fn main() {
    if let Err(error) = run_main() {
        let startup = error
            .downcast_ref::<StartupFailure>()
            .is_some();
        if startup {
            eprintln!("oskar-daemon: {error}");
            std::process::exit(78);
        }
        // A runtime failure (a dispatch error with the session standing):
        // exit 1 keeps Restart=always — 78 would leave the keyboard dead
        // until a manual restart.
        eprintln!("oskar-daemon: runtime failure: {error}");
        std::process::exit(1);
    }
}
