//! The session around the helper: its runtime directory, the files it
//! publishes there, the physical keyboards the seat carries, and the
//! compositor-neutral half of the seat verbs (`SeatBackend`).

use std::path::{Path, PathBuf};

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
pub(crate) fn published_keymap_path() -> Option<PathBuf> {
    let dir = std::env::var("XDG_RUNTIME_DIR").ok()?;
    let dir = PathBuf::from(dir).join("oskar");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("keymap.xkb"))
}

/// Whether a `kb_file` names the file this helper publishes.
///
/// Compared after canonicalising, because the panel builds this path from
/// `$XDG_RUNTIME_DIR` and the two spellings need not be byte-identical — a
/// doubled separator or a symlinked runtime directory would otherwise let our
/// own output back in as an input.
pub(crate) fn is_published_keymap(path: &str) -> bool {
    let Some(ours) = published_keymap_path() else {
        return false;
    };
    let theirs = Path::new(path);
    ours == theirs
        || match (ours.canonicalize(), theirs.canonicalize()) {
            (Ok(a), Ok(b)) => a == b,
            _ => false,
        }
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

/// What a configure's `kb_file` says about the user's own keymap source.
#[derive(Debug, PartialEq)]
pub(crate) enum SourceDecision {
    /// The user's own file: remember it verbatim for shell-crash recovery.
    Remember(String),
    /// No custom source: the recovery record must not outlive the setting.
    Clear,
    /// Our own published path: ambiguous input, refused as an input
    /// elsewhere; keep whatever is recorded rather than destroy it.
    Leave,
}

pub(crate) fn user_source_decision(kb_file: &str) -> SourceDecision {
    let trimmed = kb_file.trim();
    if trimmed.is_empty() {
        return SourceDecision::Clear;
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

pub(crate) fn socket_path() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let dir = std::env::var("XDG_RUNTIME_DIR")
        .map_err(|_| "XDG_RUNTIME_DIR is unset; this must run inside a user session")?;
    let dir = PathBuf::from(dir).join("oskar");
    std::fs::create_dir_all(&dir)?;
    let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    // The daemon's own guarantee, not systemd's: the directory must belong
    // to this uid and carry no group/other bits. A pre-created
    // group-writable directory, or one another user planted to bind their
    // own socket for the panel, is refused loudly instead of trusted.
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let meta = std::fs::metadata(&dir)?;
    if meta.uid() != nix_uid() || (meta.mode() & 0o077) != 0 {
        return Err(format!(
            "runtime dir {:?} is uid {} mode {:o}; expected uid {} and no \
             group/other bits — refusing to serve from a directory we do \
             not solely own",
            dir,
            meta.uid(),
            meta.mode() & 0o777,
            nix_uid()
        )
        .into());
    }
    Ok(dir.join("control.sock"))
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
    fn switch_group(&self, device: &str, group: u32) -> Result<(), SeatError>;
    /// Points the compositor's `kb_file` at `path`, or clears it for
    /// `None`, and verifies the setting by reading it back.
    fn share(&self, path: Option<&str>) -> Result<(), SeatError>;
    /// Starts delivering events to `sink` on threads of the backend's own.
    /// Their failure ends the events, never the helper.
    fn watch(self: std::sync::Arc<Self>, sink: std::sync::Arc<dyn EventSink>);
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
pub(crate) fn seat_reply(backend: Option<&dyn SeatBackend>) -> String {
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
pub(crate) fn share_reply(backend: Option<&dyn SeatBackend>, path: Option<&str>) -> String {
    let Some(backend) = backend else {
        return SeatError::NoBackend.reply();
    };
    if path.is_some_and(|path| !path.starts_with('/')) {
        return SeatError::NotAbsolute.reply();
    }
    match backend.share(path) {
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
        match user_source_decision("/home/u/custom.xkb") {
            SourceDecision::Remember(path) => {
                assert_eq!(path, "/home/u/custom.xkb")
            }
            other => panic!("a user path is Remember, got {other:?}"),
        }
        // An unrelated custom path whose suffix resembles the published path
        // is still the user's.
        let lookalike = "/home/u/backups/oskar/keymap.xkb";
        assert!(matches!(
            user_source_decision(lookalike),
            SourceDecision::Remember(_)
        ));
        assert!(matches!(user_source_decision(""), SourceDecision::Clear));
        assert!(matches!(user_source_decision("  "), SourceDecision::Clear));
        if let Some(ours) = published_keymap_path() {
            let spelling = ours.to_string_lossy().to_string();
            assert!(matches!(
                user_source_decision(&spelling),
                SourceDecision::Leave
            ));
        }
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
        shared: std::sync::Mutex<Vec<Option<String>>>,
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
        fn share(&self, path: Option<&str>) -> Result<(), SeatError> {
            self.shared.lock().unwrap().push(path.map(str::to_string));
            Ok(())
        }
        fn watch(self: std::sync::Arc<Self>, _sink: std::sync::Arc<dyn EventSink>) {}
    }

    fn fake(keyboards: Result<Vec<Keyboard>, SeatError>, kb_file: Result<String, SeatError>) -> FakeSeat {
        FakeSeat {
            keyboards,
            kb_file,
            shared: std::sync::Mutex::new(Vec::new()),
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
        assert_eq!(seat_reply(None), "err no seat backend");
        assert_eq!(switch_reply(None, "kbd", 1), "err no seat backend");
        assert_eq!(share_reply(None, None), "err no seat backend");

        let good = fake(
            Ok(vec![Keyboard {
                name: "kbd".into(),
                layout: "us".into(),
                ..Keyboard::default()
            }]),
            Ok(String::new()),
        );
        let reply = seat_reply(Some(&good));
        assert!(reply.starts_with("seat\t{\"keyboards\":[{\"name\":\"kbd\""), "{reply}");
        assert!(!reply.contains('\n'));
        assert_eq!(switch_reply(Some(&good), "kbd", 1), "ok");
        assert_eq!(
            switch_reply(Some(&good), "other", 1),
            "err seat refused device not found"
        );

        // A failed read of either half is an error, never a partial answer.
        let blind = fake(Err(SeatError::Unreadable), Ok(String::new()));
        assert_eq!(seat_reply(Some(&blind)), "err seat unreadable");
        let no_kb_file = fake(Ok(vec![]), Err(SeatError::Unreachable));
        assert_eq!(seat_reply(Some(&no_kb_file)), "err seat unreachable");

        // share: a relative path is refused before the compositor is asked;
        // an absolute one goes through whether or not the helper's own
        // namespace can see it (the compositor's read-back decides).
        for relative in ["keymap.xkb", "./keymap.xkb", "~/keymap.xkb", " /x"] {
            assert_eq!(
                share_reply(Some(&good), Some(relative)),
                "err share path must be absolute"
            );
        }
        assert_eq!(share_reply(Some(&good), Some("/tmp/only-the-compositor-sees-this.xkb")), "ok");
        assert_eq!(share_reply(Some(&good), None), "ok");
        assert_eq!(
            *good.shared.lock().unwrap(),
            [Some("/tmp/only-the-compositor-sees-this.xkb".to_string()), None]
        );
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
