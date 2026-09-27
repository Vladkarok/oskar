//! The session around the helper: its runtime directory, the files it
//! publishes there, the physical keyboards the seat carries, and the
//! compositor-neutral half of the seat verbs (`SeatBackend`).

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Where the helper publishes the keymap it installed, for the compositor to
/// compile the very same one.
///
/// Two keymaps on a seat is not a cosmetic difference. The compositor hands a
/// focused client whichever keyboard is active, so if ours differs a client
/// gets a keymap swap on every focus change, and every swap resets the group
/// it resolves keys in. Applications that do not re-read the group after a
/// swap then type the previous alphabet until a modifier key arrives.
///
/// Under `$XDG_RUNTIME_DIR` beside the socket: the unit sets `PrivateTmp` so
/// `/tmp` is the helper's own, and `ProtectHome=read-only` rules out `$HOME`.
/// It also means the file dies with the session, which is what keeps a stale
/// `kb_file` from outliving the panel that pointed at it.
///
/// A path only: the directory is created and checked once, at startup
/// (`claim_runtime_dir`), before anything is written into it.
pub(crate) fn published_keymap_path() -> Option<PathBuf> {
    let dir = std::env::var("XDG_RUNTIME_DIR").ok()?;
    Some(PathBuf::from(dir).join("oskar").join("keymap.xkb"))
}

/// Whether a `kb_file` names the file this helper publishes.
pub(crate) fn is_published_keymap(path: &str) -> bool {
    OwnFiles::from_env().is_some_and(|own| own.is_published(path))
}

/// The recovery record's file name, beside the published keymap in the
/// runtime directory this helper owns — the one place `ProtectSystem=strict`
/// leaves writable. The unit preserves that directory across service stops
/// (`RuntimeDirectoryPreserve=yes`) so the record survives helper restarts
/// (`oskar upgrade` restarts it) while systemd still removes it when the
/// session ends. The helper outlives a shell crash; the panel does not, and
/// without this record a crashed shell would lose the user's custom keymap
/// source while the compositor keeps compiling the published keymap.
const SOURCE_SIDECAR: &str = "user-keymap-source";

/// The helper's own files: the published keymap and the recovery record
/// beside it. Everything that asks "is this ours?" or "what did the user
/// have?" asks this, so the suites can point it at a scratch directory
/// instead of the live session's.
pub(crate) struct OwnFiles {
    published: PathBuf,
}

impl OwnFiles {
    pub(crate) fn from_env() -> Option<Self> {
        published_keymap_path().map(|published| OwnFiles { published })
    }

    #[cfg(test)]
    pub(crate) fn in_dir(dir: &Path) -> Self {
        OwnFiles {
            published: dir.join("keymap.xkb"),
        }
    }

    pub(crate) fn dir(&self) -> &Path {
        self.published.parent().unwrap_or(Path::new("."))
    }

    /// Compared after canonicalising, because the panel builds this path from
    /// `$XDG_RUNTIME_DIR` and the two spellings need not be byte-identical — a
    /// doubled separator or a symlinked runtime directory would otherwise let
    /// our own output back in as an input.
    pub(crate) fn is_published(&self, path: &str) -> bool {
        let theirs = Path::new(path);
        if path.is_empty() {
            return false;
        }
        self.published == theirs
            || match (self.published.canonicalize(), theirs.canonicalize()) {
                (Ok(a), Ok(b)) => a == b,
                _ => false,
            }
    }

    /// The user's own `kb_file` as the last configure recorded it, or empty
    /// when none is recorded.
    pub(crate) fn recorded_source(&self) -> String {
        std::fs::read_to_string(self.dir().join(SOURCE_SIDECAR))
            .map(|text| text.trim().to_string())
            .unwrap_or_default()
    }

    /// What the compositor's current `kb_file` would have to be put back to
    /// if a change failed: the value itself, or — when the compositor is
    /// already on the published keymap — the user's own recorded source.
    fn capture(&self, current: &str) -> String {
        if self.is_published(current) {
            self.recorded_source()
        } else {
            current.to_string()
        }
    }
}

/// Whether the helper can put a `kb_file` value back faithfully: empty, or an
/// absolute path. A relative one would be resolved against whatever the
/// compositor resolves it against, which the helper cannot know.
fn restorable(value: &str) -> bool {
    value.is_empty() || value.starts_with('/')
}

/// What a configure's `kb_file` says about the user's own keymap source.
#[derive(Debug, PartialEq)]
pub(crate) enum SourceDecision {
    /// The user's own file: remember it verbatim for shell-crash recovery
    /// and for the restore on shutdown.
    Remember(String),
    /// No custom source: the recovery record must not outlive the setting.
    Clear,
    /// Our own published path, or an empty one while the compositor still
    /// compiles the published keymap: keep whatever is recorded. The record
    /// is then the only memory of what the user had, and the restore on
    /// shutdown reads it.
    Leave,
}

/// The compositor's `kb_file` as the helper last saw it — a `seat` read, a
/// share's capture, a confirmed share.
#[derive(Debug, Clone, PartialEq, Default)]
pub(crate) enum LastSeen {
    #[default]
    Unknown,
    Empty,
    Published,
    /// The user's own value, verbatim, whether or not the file exists.
    User(String),
}

impl LastSeen {
    pub(crate) fn of(kb_file: &str, own: Option<&OwnFiles>) -> Self {
        let value = kb_file.trim();
        if value.is_empty() {
            LastSeen::Empty
        } else if own.is_some_and(|own| own.is_published(value)) {
            LastSeen::Published
        } else {
            LastSeen::User(value.to_string())
        }
    }
}

/// A configure's `kb_file` decides the record, read together with what the
/// compositor was last seen to hold. An empty configure is not always "the
/// user has none": the panel configures without a `kb_file` that names a
/// missing file (it cannot be compiled), and while the compositor is on the
/// published keymap the record is the only memory of the user's value. The
/// user's setting is theirs either way, so it is remembered literally —
/// the record holds a path, never the keymap, and nothing here reads it.
pub(crate) fn user_source_decision(kb_file: &str, last_seen: &LastSeen) -> SourceDecision {
    let trimmed = kb_file.trim();
    if trimmed.is_empty() {
        return match last_seen {
            LastSeen::Published => SourceDecision::Leave,
            LastSeen::User(value) => SourceDecision::Remember(value.clone()),
            LastSeen::Empty | LastSeen::Unknown => SourceDecision::Clear,
        };
    }
    if is_published_keymap(trimmed) {
        return SourceDecision::Leave;
    }
    SourceDecision::Remember(trimmed.to_string())
}

/// Writes (or removes) the user's own `kb_file` record atomically: a temp
/// file in the same directory renamed over the target, so a reader sees
/// the old complete value, the new complete value, or nothing — never a
/// partial path.
pub(crate) fn persist_user_source(dir: &Path, source: Option<&str>) -> std::io::Result<()> {
    let target = dir.join(SOURCE_SIDECAR);
    let Some(path) = source else {
        // Removing a missing file is the settled state, not an error: a
        // fresh runtime directory has nothing to clear.
        return match std::fs::remove_file(&target) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        };
    };
    let tmp = dir.join(format!("{SOURCE_SIDECAR}.tmp-{}", std::process::id()));
    std::fs::write(&tmp, format!("{path}\n"))?;
    std::fs::rename(&tmp, &target)
}

/// Writes the installed keymap where the compositor can be pointed at it.
///
/// Renamed into place rather than written in place: the compositor may be
/// reading the path at any moment, and half a keymap compiles into nothing.
pub(crate) fn publish_keymap(text: &str) {
    let Some(path) = published_keymap_path() else {
        return;
    };
    let staging = path.with_extension("xkb.new");
    if std::fs::write(&staging, text).is_err() {
        eprintln!("cannot stage the keymap for the compositor");
        return;
    }
    if std::fs::rename(&staging, &path).is_err() {
        eprintln!("cannot publish the keymap for the compositor");
        let _ = std::fs::remove_file(&staging);
    }
}

/// Takes the runtime directory for this process and returns the control
/// socket's path, before anything is written there.
///
/// The directory is created 0700 when absent and never re-moded when present:
/// it must already belong to this uid, be a real directory and carry no
/// group/other bits. A pre-created group-writable directory, or one another
/// user planted to bind their own socket for the panel, is refused loudly
/// instead of trusted — or "repaired" into looking trustworthy.
///
/// A live socket at the path is another helper, and this one refuses to be
/// the second: connecting tells a live owner apart from a socket left behind
/// by a crash, which is unlinked. Anything at the path that is not a socket
/// is not this helper's to remove.
pub(crate) fn claim_runtime_dir(runtime: &Path) -> Result<PathBuf, String> {
    use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt};
    let dir = runtime.join("oskar");
    match std::fs::symlink_metadata(&dir) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            match std::fs::DirBuilder::new().mode(0o700).create(&dir) {
                Ok(()) => {}
                // Lost a race with another creator: judged below like any
                // directory that was already there.
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(format!("cannot create {}: {error}", dir.display())),
            }
        }
        Err(error) => return Err(format!("cannot inspect {}: {error}", dir.display())),
        Ok(_) => {}
    }
    let meta = std::fs::symlink_metadata(&dir)
        .map_err(|error| format!("cannot inspect {}: {error}", dir.display()))?;
    if !meta.file_type().is_dir() || meta.uid() != nix_uid() || (meta.mode() & 0o077) != 0 {
        return Err(format!(
            "runtime dir {:?} is {} uid {} mode {:o}; expected a directory of \
             uid {} with no group/other bits — refusing to serve from a \
             directory we do not solely own",
            dir,
            if meta.file_type().is_symlink() {
                "a symlink,"
            } else if meta.file_type().is_dir() {
                "a directory,"
            } else {
                "not a directory,"
            },
            meta.uid(),
            meta.mode() & 0o777,
            nix_uid()
        ));
    }
    let socket = dir.join("control.sock");
    if std::os::unix::net::UnixStream::connect(&socket).is_ok() {
        return Err(format!("another daemon already owns {}", socket.display()));
    }
    match std::fs::symlink_metadata(&socket) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(format!("cannot inspect {}: {error}", socket.display())),
        Ok(meta) if meta.file_type().is_socket() => {
            std::fs::remove_file(&socket).map_err(|error| {
                format!("cannot remove the stale socket {}: {error}", socket.display())
            })?;
        }
        Ok(_) => {
            return Err(format!(
                "{} exists and is not a socket; refusing to remove it",
                socket.display()
            ))
        }
    }
    Ok(socket)
}

fn nix_uid() -> u32 {
    // SAFETY: getuid takes no arguments and cannot fail.
    unsafe { libc::getuid() }
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
        physical: bool,
        typing_keys: bool,
        pointer: bool,
    }

    let has_key = |bitmap: &str, code: usize| {
        bitmap
            .split_whitespace()
            .rev()
            .nth(code / u64::BITS as usize)
            .and_then(|word| u64::from_str_radix(word, 16).ok())
            .is_some_and(|word| word & (1 << (code % u64::BITS as usize)) != 0)
    };

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
        let keys =
            std::fs::read_to_string(path.join("device/capabilities/key")).unwrap_or_default();
        let typing_positions = (2..=11)
            .chain(16..=25)
            .chain(30..=38)
            .chain(44..=50)
            .chain([28, 57]);
        devices.push(Device {
            name: name.trim().to_string(),
            group,
            keyboard: property("ID_INPUT_KEYBOARD") == Some("1"),
            physical: property("ID_BUS").is_some() && property("ID_PATH").is_some(),
            typing_keys: typing_positions
                .into_iter()
                .all(|code| has_key(&keys, code)),
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
        .filter(|device| {
            device.keyboard
                && device.physical
                && device.typing_keys
                && !pointer_groups.contains(device.group.as_str())
        })
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
                "oskar",
            ]
            .iter()
            .any(|prefix| name.starts_with(prefix))
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

pub(crate) fn startup_keyboard_reply() -> String {
    let names = physical_keyboard_names(Path::new("/sys/class/input"), Path::new("/run/udev/data"));
    if names.is_empty() {
        "keyboards".to_string()
    } else {
        format!("keyboards\t{}", names.join("\t"))
    }
}

/// One keyboard as the compositor reports it: exactly the facts the panel's
/// device tiers (LayoutDevices.js) and its configure path read, written
/// under the compositor's own key names so those decisions consume the
/// helper's answer unchanged.
#[derive(Debug, Clone, PartialEq, Default)]
pub(crate) struct Keyboard {
    pub(crate) name: String,
    /// The seat's current keyboard: the device the next physical key
    /// comes from (the compositor's `main`).
    pub(crate) main: bool,
    pub(crate) active_layout_index: u32,
    pub(crate) layout: String,
    pub(crate) variant: String,
    pub(crate) rules: String,
    pub(crate) model: String,
    pub(crate) options: String,
}

/// Why a seat request has no answer. Each maps to exactly one reply line.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum SeatError {
    /// No compositor this helper knows how to ask. Typing needs none.
    NoBackend,
    /// The compositor's socket could not be reached, or did not answer
    /// inside the bound.
    Unreachable,
    /// The compositor answered with something that is not the document
    /// asked for. Never read as an empty answer: an unreadable kb_file
    /// taken for "unset" would make the panel forget a user's keymap.
    Unreadable,
    /// The compositor refused the request, in its own words.
    Refused(String),
    /// `share` named a relative path. The compositor would resolve it
    /// against its own working directory, not the panel's.
    NotAbsolute,
    /// The compositor accepted the change but reads back something else.
    NotApplied,
    /// `share` as a whole — clear, set and every read-back — ran past its
    /// deadline, which sits below the hold cap so a connection holding a
    /// key is never stalled past the cap by a wedged compositor.
    TimedOut,
    /// The request would not fit the compositor's request buffer.
    TooLong,
    /// `share` would take the compositor over from a `kb_file` the helper
    /// could not put back (a relative path): the user's setting stays.
    NotRestorable,
    /// The helper is shutting down; nothing more changes the compositor.
    ShuttingDown,
}

impl SeatError {
    pub(crate) fn reply(&self) -> String {
        match self {
            SeatError::NoBackend => "err no seat backend".to_string(),
            SeatError::Unreachable => "err seat unreachable".to_string(),
            SeatError::Unreadable => "err seat unreadable".to_string(),
            SeatError::Refused(why) => format!("err seat refused {}", one_line(why)),
            SeatError::NotAbsolute => "err share path must be absolute".to_string(),
            SeatError::NotApplied => "err share not applied".to_string(),
            SeatError::TimedOut => "err share timed out".to_string(),
            SeatError::TooLong => "err path too long".to_string(),
            SeatError::NotRestorable => "err user keymap not restorable".to_string(),
            SeatError::ShuttingDown => "err shutting down".to_string(),
        }
    }
}

/// Compositor prose squeezed into one bounded protocol field: control
/// characters (a newline would end the reply early) become spaces.
fn one_line(text: &str) -> String {
    text.trim()
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .take(160)
        .collect()
}

/// What the seat tells subscribed connections without being asked.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum SeatEvent {
    /// A keyboard's active group moved, whoever moved it.
    Layout { device: String, group: u32 },
    /// The device set or its configuration may have changed (hotplug, a
    /// config reload): the listener re-asks `seat`.
    Devices,
}

impl SeatEvent {
    /// The event's protocol line, without its newline. A device name that
    /// could break the framing (a tab or a control byte) degrades to the
    /// `devices` event, which asks the listener to re-read instead.
    pub(crate) fn line(&self) -> String {
        match self {
            SeatEvent::Layout { device, group }
                if !device.is_empty() && !device.chars().any(char::is_control) =>
            {
                format!("event\tlayout\t{device}\t{group}")
            }
            _ => "event\tdevices".to_string(),
        }
    }
}

/// Where a backend's events go. `listening` lets a backend skip resolving
/// an event nobody would read.
pub(crate) trait EventSink: Send + Sync {
    fn listening(&self) -> bool;
    fn send(&self, event: SeatEvent);
}

/// Everything the helper asks of the compositor about the seat. One
/// implementation per compositor; the protocol verbs are written against
/// this and nothing else, so a second host is a second implementation.
///
/// Every method is bounded in time and never runs under the typing lock:
/// a wedged compositor stalls the asking connection, never a keystroke.
pub(crate) trait SeatBackend: Send + Sync {
    fn keyboards(&self) -> Result<Vec<Keyboard>, SeatError>;
    /// The compositor's `kb_file` setting, empty when unset.
    fn kb_file(&self) -> Result<String, SeatError>;
    /// `kb_file`, answered by `deadline`.
    fn kb_file_by(&self, deadline: Instant) -> Result<String, SeatError>;
    fn switch_group(&self, device: &str, group: u32) -> Result<(), SeatError>;
    /// Sets the compositor's `kb_file` to `value` (empty clears it), without
    /// verifying: `Ok` is the compositor accepting the request.
    fn write_kb_file(&self, value: &str, deadline: Instant) -> Result<(), SeatError>;
    /// Reads `kb_file` back until it is `value` or `deadline` passes, and
    /// stops early with `ShuttingDown` once `stopping` says so.
    fn confirm_kb_file(
        &self,
        value: &str,
        deadline: Instant,
        stopping: &dyn Fn() -> bool,
    ) -> Result<(), SeatError>;
    /// The gate every change to this compositor's `kb_file` runs under, so a
    /// `share` from one connection never interleaves with another's, or with
    /// the restore on shutdown. One per compositor, not per process.
    fn kb_file_gate(&self) -> &Mutex<()>;
    /// Starts delivering events to `sink` on threads of the backend's own.
    /// Their failure ends the events, never the helper.
    fn watch(self: std::sync::Arc<Self>, sink: std::sync::Arc<dyn EventSink>);
}

fn gate_by(gate: &Mutex<()>, deadline: Instant) -> Option<std::sync::MutexGuard<'_, ()>> {
    loop {
        match gate.try_lock() {
            Ok(guard) => return Some(guard),
            // A panicked holder changed nothing this waiter relies on: the
            // gate orders writes, it guards no data.
            Err(std::sync::TryLockError::Poisoned(poisoned)) => return Some(poisoned.into_inner()),
            Err(std::sync::TryLockError::WouldBlock) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(std::sync::TryLockError::WouldBlock) => return None,
        }
    }
}

// The time bounds, as one invariant. Every compositor request is bounded by
// IO_BOUND on its own.
//
// - SHARE_BOUND covers a whole `share` — the gate wait, the capture, the
//   change and its read-backs.
// - PUT_BACK_BOUND is the put-back's OWN budget, started fresh when it
//   begins, whatever the failed change consumed: one write and one
//   read-back of IO_BOUND each, plus a second for re-reads while the
//   compositor applies the value. Nothing the failed operation did can
//   starve it.
// - On the share's connection (the panel's typing connection) the two add
//   up to 11 s. That is NOT bounded by the 15 s hold cap — the cap counts
//   from the press, and a key pressed shortly before the share would
//   outlast it — so the seat verbs run on a worker while the connection
//   keeps lifting keys as the cap comes due (server.rs,
//   wait_serving_holds).
// - At shutdown the restore waits for the gate at most SHUTDOWN_GATE_WAIT:
//   a share in flight sees the stop at its next step boundary (at most one
//   request, IO_BOUND) and then runs its own put-back (PUT_BACK_BOUND).
//   The restore itself then reads the setting (IO_BOUND) and puts it back
//   (PUT_BACK_BOUND): 14 s in all, inside the 20 s exit watchdog
//   (main.rs) and systemd's 90 s default stop timeout (the unit sets no
//   TimeoutStopSec). A compositor that answers takes milliseconds; the
//   bounds only matter for one that does not.
pub(crate) const IO_BOUND: Duration = Duration::from_secs(2);
pub(crate) const SHARE_BOUND: Duration = Duration::from_secs(6);
pub(crate) const PUT_BACK_BOUND: Duration = Duration::from_secs(5);
pub(crate) const SHUTDOWN_GATE_WAIT: Duration = Duration::from_secs(7);

/// Puts `value` back as the compositor's `kb_file`, verified, inside its
/// own `PUT_BACK_BOUND` from now. No clear first: the value differs from
/// what the compositor holds, or setting it is a no-op that leaves it in
/// place either way. Never interrupted by shutdown: this is the step the
/// shutdown exists to complete.
fn put_back(backend: &dyn SeatBackend, value: &str) -> Result<(), SeatError> {
    let deadline = Instant::now() + PUT_BACK_BOUND;
    backend.write_kb_file(value, deadline)?;
    backend.confirm_kb_file(value, deadline, &|| false)
}

/// `share` as one transaction: the compositor's `kb_file` is captured before
/// anything changes, changed and read back, and on any failure put back to
/// what was captured, inside the put-back's own bound. The compositor is
/// never left empty unless it was empty, or the put-back itself failed —
/// which is logged with the value, so the user can set it by hand.
///
/// Taking the compositor over — pointing it at the published keymap — is
/// refused while it carries a `kb_file` the helper could not put back.
/// `stopping` is asked between every two steps: once shutdown has begun, a
/// share in flight puts the capture back (if it changed anything) and
/// releases the gate for the shutdown restore. `observe` hears every value
/// the compositor was seen to hold.
pub(crate) fn share_transaction(
    backend: &dyn SeatBackend,
    own: &OwnFiles,
    path: Option<&str>,
    deadline: Instant,
    stopping: &dyn Fn() -> bool,
    observe: &dyn Fn(&str),
) -> Result<(), SeatError> {
    let Some(_gate) = gate_by(backend.kb_file_gate(), deadline) else {
        return Err(SeatError::TimedOut);
    };
    if stopping() {
        return Err(SeatError::ShuttingDown);
    }
    let wanted = path.unwrap_or("");
    let current = backend.kb_file_by(deadline)?;
    observe(&current);
    let captured = own.capture(&current);
    let taking_over = own.is_published(wanted);
    if !restorable(&captured) && taking_over {
        eprintln!(
            "[oskar] not sharing the keymap: the compositor's kb_file {captured:?} is not an \
             absolute path, so it could not be put back"
        );
        return Err(SeatError::NotRestorable);
    }
    let step = || {
        if stopping() {
            Err(SeatError::ShuttingDown)
        } else {
            Ok(())
        }
    };
    step()?;
    let changed = (|| {
        // Cleared first only when the setting already names the target:
        // assigning the value it holds is a no-op, and a keymap republished
        // under the same name has to be re-read or the compositor keeps
        // compiling the one before it. Any other change is one write, so
        // there is no moment at which the compositor holds nothing.
        if !wanted.is_empty() && current == wanted {
            backend.write_kb_file("", deadline)?;
            step()?;
        }
        backend.write_kb_file(wanted, deadline)?;
        step()?;
        backend.confirm_kb_file(wanted, deadline, stopping)
    })();
    match changed {
        Ok(()) => {
            observe(wanted);
            Ok(())
        }
        Err(error) => {
            if !restorable(&captured) {
                eprintln!(
                    "[oskar] share failed ({}); the previous kb_file {captured:?} cannot be put \
                     back; set input:kb_file to it by hand",
                    error.reply()
                );
                return Err(error);
            }
            match put_back(backend, &captured) {
                Ok(()) => observe(&captured),
                Err(restore) => eprintln!(
                    "[oskar] share failed ({}) and putting kb_file back failed too ({}); set \
                     input:kb_file to {captured:?} by hand, or reload Hyprland",
                    error.reply(),
                    restore.reply()
                ),
            }
            Err(error)
        }
    }
}

/// What the restore on shutdown did.
#[derive(Debug, PartialEq)]
pub(crate) enum ShutdownRestore {
    /// The compositor is not on the published keymap: its setting is
    /// someone else's (the user's, a reload's) and stays.
    NotOurs,
    /// The compositor was on the published keymap and now holds this.
    Restored(String),
    /// It could not be read or changed in time.
    Failed(SeatError),
}

/// What the user's `kb_file` should be once the helper is gone: the
/// recorded source, or empty (unset) when none is recorded or it cannot be
/// put back.
pub(crate) fn shutdown_value(own: &OwnFiles) -> String {
    let value = own.recorded_source();
    if restorable(&value) {
        value
    } else {
        eprintln!("[oskar] the recorded kb_file {value:?} is not absolute; clearing instead");
        String::new()
    }
}

/// On the helper's own shutdown, after its keys are released: a compositor
/// still compiling the published keymap is put back to the user's recorded
/// source, or cleared when none is recorded. The published file dies with
/// the runtime directory, and a `kb_file` naming it must not outlive the
/// process that keeps it current. Bounded as the invariant above states:
/// the gate wait, one read and the put-back, each on its own budget.
pub(crate) fn restore_on_shutdown(backend: &dyn SeatBackend, own: &OwnFiles) -> ShutdownRestore {
    let Some(_gate) = gate_by(backend.kb_file_gate(), Instant::now() + SHUTDOWN_GATE_WAIT) else {
        return ShutdownRestore::Failed(SeatError::TimedOut);
    };
    let current = match backend.kb_file_by(Instant::now() + IO_BOUND) {
        Ok(current) => current,
        Err(error) => return ShutdownRestore::Failed(error),
    };
    if !own.is_published(&current) {
        return ShutdownRestore::NotOurs;
    }
    let value = shutdown_value(own);
    match put_back(backend, &value) {
        Ok(()) => ShutdownRestore::Restored(value),
        Err(error) => ShutdownRestore::Failed(error),
    }
}

/// xkb's human names for layout codes, the table the panel labels with.
const BASE_LST: &str = "/usr/share/X11/xkb/rules/base.lst";
const BASE_LST_CAP: u64 = 2 * 1024 * 1024;

/// The `! layout` section's name for each wanted code, in `wanted` order.
/// Codes the table does not carry are simply absent.
fn layout_titles(base_lst: &str, wanted: &[String]) -> Vec<(String, String)> {
    let mut found = std::collections::HashMap::new();
    let mut in_layouts = false;
    for line in base_lst.lines() {
        if let Some(section) = line.strip_prefix('!') {
            in_layouts = section.trim() == "layout";
            continue;
        }
        if !in_layouts {
            continue;
        }
        let line = line.trim();
        let Some((code, name)) = line.split_once(char::is_whitespace) else {
            continue;
        };
        if wanted.iter().any(|want| want == code) {
            found.entry(code.to_string()).or_insert_with(|| name.trim().to_string());
        }
    }
    wanted
        .iter()
        .filter_map(|code| found.get(code).map(|name| (code.clone(), name.clone())))
        .collect()
}

/// Every distinct layout code any keyboard carries, in first-seen order.
fn layout_codes(keyboards: &[Keyboard]) -> Vec<String> {
    let mut codes: Vec<String> = Vec::new();
    for code in keyboards.iter().flat_map(|k| k.layout.split(',')) {
        let code = code.trim();
        if !code.is_empty() && !codes.iter().any(|seen| seen == code) {
            codes.push(code.to_string());
        }
    }
    codes
}

/// The `seat` reply's JSON: the device inventory under the compositor's own
/// key names, the helper's positively identified physical keyboards (the
/// `keyboards` verb's list), the compositor's `kb_file`, and the human
/// names of every layout code the keyboards carry. One line by
/// construction: every string goes through `json::quote`.
fn seat_json(
    keyboards: &[Keyboard],
    safe: &[String],
    kb_file: &str,
    titles: &[(String, String)],
) -> String {
    use crate::json::quote;
    let devices: Vec<String> = keyboards
        .iter()
        .map(|k| {
            format!(
                "{{\"name\":{},\"main\":{},\"active_layout_index\":{},\"layout\":{},\
                 \"variant\":{},\"rules\":{},\"model\":{},\"options\":{}}}",
                quote(&k.name),
                k.main,
                k.active_layout_index,
                quote(&k.layout),
                quote(&k.variant),
                quote(&k.rules),
                quote(&k.model),
                quote(&k.options)
            )
        })
        .collect();
    let safe: Vec<String> = safe.iter().map(|name| quote(name)).collect();
    let titles: Vec<String> = titles
        .iter()
        .map(|(code, name)| format!("{}:{}", quote(code), quote(name)))
        .collect();
    format!(
        "{{\"keyboards\":[{}],\"safe\":[{}],\"kb_file\":{},\"titles\":{{{}}}}}",
        devices.join(","),
        safe.join(","),
        quote(kb_file),
        titles.join(",")
    )
}

/// `seat`: one line, `seat<TAB><json>`, or the error that kept it from
/// being answered. Both compositor reads must succeed — a failed kb_file
/// read is an error, never an empty value.
pub(crate) fn seat_reply(backend: Option<&dyn SeatBackend>, observe: &dyn Fn(&str)) -> String {
    let Some(backend) = backend else {
        return SeatError::NoBackend.reply();
    };
    let keyboards = match backend.keyboards() {
        Ok(keyboards) => keyboards,
        Err(error) => return error.reply(),
    };
    let kb_file = match backend.kb_file() {
        Ok(kb_file) => kb_file,
        Err(error) => return error.reply(),
    };
    observe(&kb_file);
    let safe = physical_keyboard_names(Path::new("/sys/class/input"), Path::new("/run/udev/data"));
    let base_lst = std::fs::File::open(BASE_LST)
        .and_then(|file| {
            use std::io::Read;
            let mut text = String::new();
            file.take(BASE_LST_CAP).read_to_string(&mut text)?;
            Ok(text)
        })
        .unwrap_or_default();
    let titles = layout_titles(&base_lst, &layout_codes(&keyboards));
    format!("seat\t{}", seat_json(&keyboards, &safe, &kb_file, &titles))
}

/// `switch`: moves one device to an absolute group.
pub(crate) fn switch_reply(backend: Option<&dyn SeatBackend>, device: &str, group: u32) -> String {
    let Some(backend) = backend else {
        return SeatError::NoBackend.reply();
    };
    match backend.switch_group(device, group) {
        Ok(()) => "ok".to_string(),
        Err(error) => error.reply(),
    }
}

/// `share`: points the compositor at a keymap file, or clears the setting.
///
/// The helper never checks the file itself: it runs in a mount namespace
/// of its own (`PrivateTmp=yes`), so its view of a path is not the
/// compositor's. The path only has to be absolute — a relative one would
/// resolve against the compositor's working directory — and the
/// compositor's read-back is the verification.
pub(crate) fn share_reply(
    backend: Option<&dyn SeatBackend>,
    path: Option<&str>,
    stopping: &dyn Fn() -> bool,
    observe: &dyn Fn(&str),
) -> String {
    share_reply_in(backend, OwnFiles::from_env(), path, stopping, observe)
}

/// `share_reply` with the helper's own files named by the caller, so the
/// reply does not depend on the environment it is asked in.
pub(crate) fn share_reply_in(
    backend: Option<&dyn SeatBackend>,
    own: Option<OwnFiles>,
    path: Option<&str>,
    stopping: &dyn Fn() -> bool,
    observe: &dyn Fn(&str),
) -> String {
    let Some(backend) = backend else {
        return SeatError::NoBackend.reply();
    };
    if path.is_some_and(|path| !path.starts_with('/')) {
        return SeatError::NotAbsolute.reply();
    }
    let Some(own) = own else {
        return SeatError::Unreadable.reply();
    };
    let deadline = Instant::now() + SHARE_BOUND;
    match share_transaction(backend, &own, path, deadline, stopping, observe) {
        Ok(()) => "ok".to_string(),
        Err(error) => error.reply(),
    }
}

/// Wakes on event nodes appearing in or vanishing from an input device
/// directory (`/dev/input`): the kernel's own record of hotplug, which
/// needs neither udev's netlink socket nor a subprocess.
pub(crate) struct InputNodeWatch {
    fd: std::os::fd::OwnedFd,
}

impl InputNodeWatch {
    pub(crate) fn open(dir: &Path) -> Option<Self> {
        use std::os::fd::FromRawFd;
        use std::os::unix::ffi::OsStrExt;
        let dir = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
        // SAFETY: inotify_init1 takes flags only; a non-negative return is a
        // fresh descriptor this frame owns from here on.
        let raw = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
        if raw < 0 {
            return None;
        }
        // SAFETY: `raw` was just returned by inotify_init1 and nothing else owns it.
        let fd = unsafe { std::os::fd::OwnedFd::from_raw_fd(raw) };
        let mask = libc::IN_CREATE | libc::IN_DELETE | libc::IN_MOVED_TO | libc::IN_MOVED_FROM;
        // SAFETY: the descriptor is live and `dir` is a NUL-terminated path.
        let watch = unsafe {
            libc::inotify_add_watch(std::os::fd::AsRawFd::as_raw_fd(&fd), dir.as_ptr(), mask)
        };
        (watch >= 0).then_some(InputNodeWatch { fd })
    }

    /// Waits up to `timeout` (forever for `None`) and reports whether an
    /// `event*` node came or went. `Ok(false)` covers both a timeout and a
    /// wake for other names (`js0`, `by-id`), so callers loop.
    pub(crate) fn wait(&self, timeout: Option<std::time::Duration>) -> std::io::Result<bool> {
        use std::os::fd::AsRawFd;
        let raw = self.fd.as_raw_fd();
        let mut poll = libc::pollfd {
            fd: raw,
            events: libc::POLLIN,
            revents: 0,
        };
        let ms = timeout.map_or(-1, |t| t.as_millis().min(i32::MAX as u128) as libc::c_int);
        // SAFETY: one pollfd, owned by this frame, for a live descriptor.
        let ready = unsafe { libc::poll(&mut poll, 1, ms) };
        if ready < 0 {
            let error = std::io::Error::last_os_error();
            return if error.kind() == std::io::ErrorKind::Interrupted {
                Ok(false)
            } else {
                Err(error)
            };
        }
        if ready == 0 {
            return Ok(false);
        }
        let mut changed = false;
        // Aligned for the kernel's inotify_event records.
        let mut buf = [0u64; 512];
        loop {
            // SAFETY: the buffer is owned, writable and its byte length is
            // passed; the descriptor is non-blocking so this cannot park.
            let read = unsafe {
                libc::read(raw, buf.as_mut_ptr().cast(), std::mem::size_of_val(&buf))
            };
            if read <= 0 {
                break;
            }
            // SAFETY: the kernel wrote `read` bytes into `buf`.
            let bytes = unsafe {
                std::slice::from_raw_parts(buf.as_ptr().cast::<u8>(), read as usize)
            };
            changed |= event_node_named(bytes);
        }
        Ok(changed)
    }
}

/// Whether a batch of raw inotify records names an `event*` node. A queue
/// overflow counts too: the events it dropped may have been exactly those.
fn event_node_named(mut bytes: &[u8]) -> bool {
    // struct inotify_event: wd (i32), mask, cookie, len (u32), then `len`
    // bytes of NUL-padded name.
    const HEADER: usize = 16;
    let mut named = false;
    while bytes.len() >= HEADER {
        let mask = u32::from_ne_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
        let len = u32::from_ne_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]) as usize;
        let Some(name) = bytes.get(HEADER..HEADER + len) else {
            break;
        };
        named |= mask & libc::IN_Q_OVERFLOW != 0 || name.starts_with(b"event");
        bytes = &bytes[HEADER + len..];
    }
    named
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The helper's own published keymap is never an input.
    ///
    /// The compositor is pointed at that file so the seat has one keymap,
    /// and the path comes back on the next configure. Reading it would
    /// freeze whichever version wrote it: the old keymap would outlive the
    /// code that made it.
    ///
    /// Asked of the decision and not of the filesystem: the real published
    /// path is the live session's keymap, and the suite must not touch it.
    #[test]
    fn the_helpers_own_published_keymap_is_never_read_back() {
        let Some(ours) = published_keymap_path() else {
            // No XDG_RUNTIME_DIR: the helper cannot run at all, and
            // `socket_path` says so at startup.
            return;
        };
        let spelling = ours.to_string_lossy().to_string();
        assert!(is_published_keymap(&spelling), "our own path is ours");
        // The panel builds this path by concatenation, so the spelling it
        // sends need not be the one `published_keymap_path` produces.
        assert!(
            is_published_keymap(&spelling.replace("/oskar/", "//oskar/")),
            "a doubled separator is still our own file"
        );
        assert!(
            !is_published_keymap("/home/someone/my-own.xkb"),
            "a user's keymap is not ours"
        );
        assert!(!is_published_keymap(""), "an RMLVO configure names no file");
        assert!(
            !is_published_keymap(&format!("{spelling}.backup")),
            "a neighbour of ours is not ours"
        );
    }

    /// The recovery record's three-way decision. A user's own
    /// `kb_file` is remembered verbatim — including a path that merely
    /// contains our suffix, which is a user's file by exact identity, not
    /// ours by substring. An RMLVO configure (no file) clears the record:
    /// the recovery value must not outlive the user's own setting. Our
    /// published path is neither remembered nor forgotten — feeding our own
    /// output back is refused elsewhere, and an ambiguous spelling must not
    /// destroy the record.
    #[test]
    fn a_user_source_is_remembered_ours_is_left_and_empty_clears() {
        match user_source_decision("/home/u/custom.xkb", &LastSeen::Unknown) {
            SourceDecision::Remember(path) => {
                assert_eq!(path, "/home/u/custom.xkb")
            }
            other => panic!("a user path is Remember, got {other:?}"),
        }
        // An unrelated custom path whose suffix resembles the published path
        // is still the user's.
        let lookalike = "/home/u/backups/oskar/keymap.xkb";
        assert!(matches!(
            user_source_decision(lookalike, &LastSeen::Unknown),
            SourceDecision::Remember(_)
        ));
        assert!(matches!(user_source_decision("", &LastSeen::Empty), SourceDecision::Clear));
        assert!(matches!(user_source_decision("  ", &LastSeen::Unknown), SourceDecision::Clear));
        if let Some(ours) = published_keymap_path() {
            let spelling = ours.to_string_lossy().to_string();
            assert!(matches!(
                user_source_decision(&spelling, &LastSeen::Unknown),
                SourceDecision::Leave
            ));
        }
    }

    /// While the compositor compiles the published keymap, the record is
    /// the only memory of the user's own kb_file — the restore on shutdown
    /// reads it — so an empty configure in that state leaves it standing.
    /// A user path still replaces it: that is new knowledge, not a loss.
    #[test]
    fn the_record_survives_an_empty_configure_while_the_compositor_is_ours() {
        assert_eq!(user_source_decision("", &LastSeen::Published), SourceDecision::Leave);
        assert_eq!(user_source_decision(" ", &LastSeen::Published), SourceDecision::Leave);
        assert_eq!(
            user_source_decision("/home/u/new.xkb", &LastSeen::Published),
            SourceDecision::Remember("/home/u/new.xkb".into())
        );
    }

    /// A user kb_file naming a missing file: the panel configures without
    /// it (it cannot compile), and the record still keeps the user's
    /// literal value, so the restore on shutdown puts back what they set.
    #[test]
    fn a_missing_user_file_is_remembered_literally() {
        let seen = LastSeen::of("/home/u/on-unplugged-media.xkb", None);
        assert_eq!(seen, LastSeen::User("/home/u/on-unplugged-media.xkb".into()));
        assert_eq!(
            user_source_decision("", &seen),
            SourceDecision::Remember("/home/u/on-unplugged-media.xkb".into())
        );
        assert_eq!(LastSeen::of("  ", None), LastSeen::Empty);
        let dir = scratch("seen");
        let own = OwnFiles::in_dir(&dir);
        let published = own.dir().join("keymap.xkb").to_string_lossy().to_string();
        assert_eq!(LastSeen::of(&published, Some(&own)), LastSeen::Published);
        let _ = std::fs::remove_dir_all(dir);
    }

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("osk-claim-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn mode_of(path: &Path) -> u32 {
        use std::os::unix::fs::MetadataExt;
        std::fs::symlink_metadata(path).unwrap().mode() & 0o777
    }

    /// Startup takes the runtime directory before anything is written into
    /// it: an absent one is created 0700, a stale socket is unlinked, and a
    /// live one means another helper — this one refuses.
    #[test]
    fn claiming_the_runtime_dir_creates_it_private_and_clears_a_stale_socket() {
        let runtime = scratch("fresh");
        let socket = claim_runtime_dir(&runtime).expect("an absent dir is created");
        assert_eq!(socket, runtime.join("oskar/control.sock"));
        assert_eq!(mode_of(&runtime.join("oskar")), 0o700);

        // A socket nobody listens on is a crash's leftover.
        drop(std::os::unix::net::UnixListener::bind(&socket).unwrap());
        assert!(socket.exists());
        claim_runtime_dir(&runtime).expect("a stale socket is cleared");
        assert!(!socket.exists());

        let live = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let refused = claim_runtime_dir(&runtime).unwrap_err();
        assert!(refused.contains("another daemon"), "{refused}");
        assert!(socket.exists(), "a live helper's socket is left alone");
        drop(live);
        let _ = std::fs::remove_dir_all(runtime);
    }

    /// Anything at the socket path that is not a socket is not the helper's
    /// to remove; an existing directory is judged, never re-moded.
    #[test]
    fn claiming_refuses_a_foreign_file_and_a_loose_dir_and_changes_neither() {
        use std::os::unix::fs::PermissionsExt;
        let runtime = scratch("foreign");
        let dir = runtime.join("oskar");
        std::fs::create_dir(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(dir.join("control.sock"), "not a socket").unwrap();
        let refused = claim_runtime_dir(&runtime).unwrap_err();
        assert!(refused.contains("is not a socket"), "{refused}");
        assert_eq!(
            std::fs::read_to_string(dir.join("control.sock")).unwrap(),
            "not a socket"
        );
        std::fs::remove_file(dir.join("control.sock")).unwrap();

        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o750)).unwrap();
        let refused = claim_runtime_dir(&runtime).unwrap_err();
        assert!(refused.contains("mode 750"), "{refused}");
        assert_eq!(mode_of(&dir), 0o750, "an existing directory is never re-moded");

        std::fs::remove_dir(&dir).unwrap();
        let elsewhere = scratch("elsewhere");
        std::fs::set_permissions(&elsewhere, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::os::unix::fs::symlink(&elsewhere, &dir).unwrap();
        let refused = claim_runtime_dir(&runtime).unwrap_err();
        assert!(refused.contains("symlink"), "{refused}");
        let _ = std::fs::remove_dir_all(runtime);
        let _ = std::fs::remove_dir_all(elsewhere);
    }

    /// The sidecar sits beside the published keymap — the one
    /// directory `ProtectSystem=strict` leaves the helper writable, and
    /// the one the unit preserves across service stops so a routine
    /// `oskar upgrade` cannot wipe the record.
    #[test]
    fn the_source_sidecar_lives_beside_the_published_keymap() {
        let Some(published) = published_keymap_path() else {
            return;
        };
        let dir = published
            .parent()
            .expect("the published keymap always has a parent directory");
        let sidecar = dir.join(SOURCE_SIDECAR);
        assert!(sidecar.starts_with(dir));
        assert_ne!(sidecar, published, "the record is not the keymap itself");
    }

    /// The sidecar itself. Written atomically (temp + rename),
    /// re-written in place, and removed on clear — a reader either sees the
    /// old complete value, the new complete value, or nothing.
    #[test]
    fn the_source_sidecar_writes_rewrites_and_clears() {
        let dir = std::env::temp_dir().join(format!("osk-sidecar-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        persist_user_source(&dir, Some("/home/u/custom.xkb")).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.join(SOURCE_SIDECAR))
                .unwrap()
                .trim(),
            "/home/u/custom.xkb"
        );
        // An edited custom file at the same path is the same record shape:
        // the sidecar holds the path; content is read fresh each compile.
        persist_user_source(&dir, Some("/home/u/custom.xkb")).unwrap();
        persist_user_source(&dir, Some("/home/u/two.xkb")).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.join(SOURCE_SIDECAR))
                .unwrap()
                .trim(),
            "/home/u/two.xkb"
        );
        persist_user_source(&dir, None).unwrap();
        assert!(!dir.join(SOURCE_SIDECAR).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    struct FakeSeat {
        keyboards: Result<Vec<Keyboard>, SeatError>,
        kb_file: Result<String, SeatError>,
        shared: std::sync::Mutex<Vec<String>>,
        gate: Mutex<()>,
    }

    impl SeatBackend for FakeSeat {
        fn keyboards(&self) -> Result<Vec<Keyboard>, SeatError> {
            self.keyboards.clone()
        }
        fn kb_file(&self) -> Result<String, SeatError> {
            self.kb_file.clone()
        }
        fn switch_group(&self, device: &str, _group: u32) -> Result<(), SeatError> {
            if device == "kbd" {
                Ok(())
            } else {
                Err(SeatError::Refused("device not found".into()))
            }
        }
        fn kb_file_by(&self, _deadline: Instant) -> Result<String, SeatError> {
            self.kb_file.clone()
        }
        fn write_kb_file(&self, value: &str, _deadline: Instant) -> Result<(), SeatError> {
            self.shared.lock().unwrap().push(value.to_string());
            Ok(())
        }
        fn confirm_kb_file(
            &self,
            _value: &str,
            _deadline: Instant,
            _stopping: &dyn Fn() -> bool,
        ) -> Result<(), SeatError> {
            Ok(())
        }
        fn kb_file_gate(&self) -> &Mutex<()> {
            &self.gate
        }
        fn watch(self: std::sync::Arc<Self>, _sink: std::sync::Arc<dyn EventSink>) {}
    }

    fn fake(keyboards: Result<Vec<Keyboard>, SeatError>, kb_file: Result<String, SeatError>) -> FakeSeat {
        FakeSeat {
            keyboards,
            kb_file,
            shared: std::sync::Mutex::new(Vec::new()),
            gate: Mutex::new(()),
        }
    }

    #[test]
    fn the_seat_reply_is_one_line_of_json_the_panel_reads_unchanged() {
        let keyboards = vec![
            Keyboard {
                name: "at-translated-set-2-keyboard".into(),
                main: true,
                active_layout_index: 1,
                layout: "us,ua".into(),
                variant: ",".into(),
                rules: "evdev".into(),
                model: "pc105".into(),
                options: "grp:alt_shift_toggle".into(),
            },
            Keyboard {
                name: "odd\"name\nwith\tbreaks".into(),
                ..Keyboard::default()
            },
        ];
        let json = seat_json(
            &keyboards,
            &["at-translated-set-2-keyboard".to_string()],
            "/run/user/1000/oskar/keymap.xkb",
            &[("us".into(), "English (US)".into()), ("ua".into(), "Ukrainian".into())],
        );
        assert!(!json.contains('\n') && !json.contains('\r'));
        let parsed = crate::json::parse(&json).expect("the reply is JSON");
        let first = &parsed.get("keyboards").unwrap().as_array().unwrap()[0];
        // The compositor's own key names, which LayoutDevices.js reads.
        assert_eq!(first.get("name").unwrap().as_str(), Some("at-translated-set-2-keyboard"));
        assert_eq!(first.get("main").unwrap().as_bool(), Some(true));
        assert_eq!(first.get("active_layout_index").unwrap().as_u32(), Some(1));
        for (key, value) in [
            ("layout", "us,ua"),
            ("variant", ","),
            ("rules", "evdev"),
            ("model", "pc105"),
            ("options", "grp:alt_shift_toggle"),
        ] {
            assert_eq!(first.get(key).unwrap().as_str(), Some(value), "{key}");
        }
        let second = &parsed.get("keyboards").unwrap().as_array().unwrap()[1];
        assert_eq!(second.get("name").unwrap().as_str(), Some("odd\"name\nwith\tbreaks"));
        assert_eq!(parsed.get("safe").unwrap().as_array().unwrap().len(), 1);
        assert_eq!(
            parsed.get("kb_file").unwrap().as_str(),
            Some("/run/user/1000/oskar/keymap.xkb")
        );
        assert_eq!(
            parsed.get("titles").unwrap().get("ua").unwrap().as_str(),
            Some("Ukrainian")
        );
    }

    #[test]
    fn the_seat_verbs_answer_one_line_each_way() {
        let never = || false;
        let ignore = |_: &str| {};
        // The helper's own files are named here: a build environment has
        // no user session and no `$XDG_RUNTIME_DIR`.
        let own = || Some(OwnFiles::in_dir(&scratch("verbs")));
        assert_eq!(seat_reply(None, &ignore), "err no seat backend");
        assert_eq!(switch_reply(None, "kbd", 1), "err no seat backend");
        assert_eq!(share_reply_in(None, own(), None, &never, &ignore), "err no seat backend");

        let good = fake(
            Ok(vec![Keyboard {
                name: "kbd".into(),
                layout: "us".into(),
                ..Keyboard::default()
            }]),
            Ok(String::new()),
        );
        let seen = std::sync::Mutex::new(Vec::new());
        let reply = seat_reply(Some(&good), &|kb: &str| seen.lock().unwrap().push(kb.to_string()));
        assert_eq!(*seen.lock().unwrap(), [String::new()], "the kb_file read is observed");
        assert!(reply.starts_with("seat\t{\"keyboards\":[{\"name\":\"kbd\""), "{reply}");
        assert!(!reply.contains('\n'));
        assert_eq!(switch_reply(Some(&good), "kbd", 1), "ok");
        assert_eq!(
            switch_reply(Some(&good), "other", 1),
            "err seat refused device not found"
        );

        // A failed read of either half is an error, never a partial answer.
        let blind = fake(Err(SeatError::Unreadable), Ok(String::new()));
        assert_eq!(seat_reply(Some(&blind), &ignore), "err seat unreadable");
        let no_kb_file = fake(Ok(vec![]), Err(SeatError::Unreachable));
        assert_eq!(seat_reply(Some(&no_kb_file), &ignore), "err seat unreachable");

        // share: a relative path is refused before the compositor is asked;
        // an absolute one goes through whether or not the helper's own
        // namespace can see it (the compositor's read-back decides).
        for relative in ["keymap.xkb", "./keymap.xkb", "~/keymap.xkb", " /x"] {
            assert_eq!(
                share_reply_in(Some(&good), own(), Some(relative), &never, &ignore),
                "err share path must be absolute"
            );
        }
        assert_eq!(
            share_reply_in(Some(&good), own(), Some("/tmp/only-the-compositor-sees-this.xkb"), &never, &ignore),
            "ok"
        );
        assert_eq!(share_reply_in(Some(&good), own(), None, &never, &ignore), "ok");
        assert_eq!(
            *good.shared.lock().unwrap(),
            ["/tmp/only-the-compositor-sees-this.xkb".to_string(), String::new()]
        );
        // Once shutdown has begun nothing more changes the compositor.
        assert_eq!(
            share_reply_in(Some(&good), own(), None, &|| true, &ignore),
            "err shutting down"
        );
        // Without a runtime directory the helper has no files of its own.
        assert_eq!(
            share_reply_in(Some(&good), None, None, &never, &ignore),
            "err seat unreadable"
        );
        assert_eq!(good.shared.lock().unwrap().len(), 2);
    }

    #[test]
    fn every_seat_error_is_one_err_line() {
        for error in [
            SeatError::NoBackend,
            SeatError::Unreachable,
            SeatError::Unreadable,
            SeatError::Refused("error: bad\nsecond line\r".into()),
            SeatError::NotAbsolute,
            SeatError::NotApplied,
            SeatError::TimedOut,
            SeatError::TooLong,
            SeatError::NotRestorable,
            SeatError::ShuttingDown,
        ] {
            let reply = error.reply();
            assert!(reply.starts_with("err "), "{reply}");
            assert!(!reply.chars().any(char::is_control), "{reply:?}");
        }
    }

    #[test]
    fn event_lines_carry_the_device_and_group_or_degrade_to_a_reread() {
        assert_eq!(
            SeatEvent::Layout {
                device: "kbd-1".into(),
                group: 2
            }
            .line(),
            "event\tlayout\tkbd-1\t2"
        );
        assert_eq!(SeatEvent::Devices.line(), "event\tdevices");
        for device in ["", "a\tb", "a\nb"] {
            assert_eq!(
                SeatEvent::Layout {
                    device: device.into(),
                    group: 0
                }
                .line(),
                "event\tdevices"
            );
        }
    }

    #[test]
    fn layout_titles_come_from_the_layout_section_only() {
        let base_lst = "! model\n  us    Not a layout\n\n! layout\n  us              English (US)\n  \
                        ua              Ukrainian\n  de              German\n\n! variant\n  \
                        intl            us: English (US, intl.)\n";
        let wanted = ["ua".to_string(), "us".to_string(), "xx".to_string()];
        assert_eq!(
            layout_titles(base_lst, &wanted),
            [
                ("ua".to_string(), "Ukrainian".to_string()),
                ("us".to_string(), "English (US)".to_string()),
            ]
        );
        let keyboards = [
            Keyboard {
                layout: "us,ua".into(),
                ..Keyboard::default()
            },
            Keyboard {
                layout: "ua, de,".into(),
                ..Keyboard::default()
            },
        ];
        assert_eq!(layout_codes(&keyboards), ["us", "ua", "de"]);
    }

    #[test]
    fn a_queue_overflow_reads_as_a_change() {
        let record = |mask: u32, name: &[u8]| {
            let mut bytes = Vec::new();
            bytes.extend_from_slice(&(-1i32).to_ne_bytes());
            bytes.extend_from_slice(&mask.to_ne_bytes());
            bytes.extend_from_slice(&0u32.to_ne_bytes());
            bytes.extend_from_slice(&(name.len() as u32).to_ne_bytes());
            bytes.extend_from_slice(name);
            bytes
        };
        assert!(event_node_named(&record(libc::IN_Q_OVERFLOW, b"")));
        assert!(!event_node_named(&record(libc::IN_CREATE, b"js0\0\0\0\0\0")));
        let mut both = record(libc::IN_CREATE, b"js0\0\0\0\0\0");
        both.extend(record(libc::IN_DELETE, b"event3\0\0"));
        assert!(event_node_named(&both));
    }

    #[test]
    fn the_input_node_watch_wakes_for_event_nodes_only() {
        let dir = std::env::temp_dir().join(format!("osk-input-watch-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let watch = InputNodeWatch::open(&dir).expect("inotify on a temp dir");
        let short = Some(std::time::Duration::from_millis(100));
        assert!(!watch.wait(short).unwrap(), "nothing happened yet");
        std::fs::write(dir.join("js0"), "").unwrap();
        assert!(!watch.wait(short).unwrap(), "not an event node");
        std::fs::write(dir.join("event42"), "").unwrap();
        assert!(watch.wait(short).unwrap(), "an event node appeared");
        std::fs::remove_file(dir.join("event42")).unwrap();
        assert!(watch.wait(short).unwrap(), "an event node vanished");
        assert!(InputNodeWatch::open(&dir.join("absent")).is_none());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn startup_inventory_rejects_a_mouse_keyboard_interface() {
        let root =
            std::env::temp_dir().join(format!("oskar-device-test-{}", std::process::id()));
        let input = root.join("input");
        let udev = root.join("udev");
        std::fs::create_dir_all(&udev).unwrap();

        let device = |event: &str, dev: &str, name: &str, properties: &str, keys: &str| {
            let path = input.join(event);
            std::fs::create_dir_all(path.join("device/capabilities")).unwrap();
            std::fs::write(path.join("device/name"), name).unwrap();
            std::fs::write(path.join("device/capabilities/key"), keys).unwrap();
            std::fs::write(path.join("dev"), dev).unwrap();
            std::fs::write(udev.join(format!("c{dev}")), properties).unwrap();
        };
        device(
            "event1",
            "13:1",
            "QEMU USB Keyboard",
            "E:ID_INPUT_KEYBOARD=1\nE:ID_BUS=usb\nE:ID_PATH=pci-keyboard\nE:LIBINPUT_DEVICE_GROUP=keyboard\n",
            "ffffffffffffffff",
        );
        device(
            "event2",
            "13:2",
            "Gaming Mouse Keyboard",
            "E:ID_INPUT_KEYBOARD=1\nE:ID_BUS=usb\nE:ID_PATH=pci-mouse\nE:LIBINPUT_DEVICE_GROUP=mouse\n",
            "ffffffffffffffff",
        );
        device(
            "event3",
            "13:3",
            "Gaming Mouse",
            "E:ID_INPUT_MOUSE=1\nE:ID_BUS=usb\nE:ID_PATH=pci-mouse\nE:LIBINPUT_DEVICE_GROUP=mouse\n",
            "0",
        );
        device(
            "event4",
            "13:4",
            "Power Button",
            "E:ID_INPUT_KEY=1\nE:LIBINPUT_DEVICE_GROUP=power\n",
            "ffffffffffffffff",
        );
        device(
            "event5",
            "13:5",
            "uinput pseudo keyboard",
            "E:ID_INPUT_KEYBOARD=1\nE:LIBINPUT_DEVICE_GROUP=pseudo\n",
            "ffffffffffffffff",
        );
        device(
            "event6",
            "13:6",
            "Laptop Hotkeys Keyboard",
            "E:ID_INPUT_KEYBOARD=1\nE:ID_BUS=platform\nE:ID_PATH=platform-hotkeys\nE:LIBINPUT_DEVICE_GROUP=hotkeys\n",
            "8000",
        );

        assert_eq!(
            physical_keyboard_names(&input, &udev),
            vec!["qemu-usb-keyboard"]
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}
