//! The `hyprland` seat backend: Hyprland's two IPC sockets, spoken to
//! directly — no `hyprctl`, no shell, no `jq`.
//!
//! Socket1 (`.socket.sock`) is request/reply: one connection per request,
//! the request written as `hyprctl` writes it (`<flags>/<command>`), the
//! reply read to EOF. Socket2 (`.socket2.sock`) is the compositor's event
//! stream, one `name>>data` line per event, read on a thread of its own.
//! Hotplug comes from `/dev/input` (see `watch`): Hyprland's IPC has no
//! input-device event.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use crate::json;
use crate::seat::{EventSink, InputNodeWatch, Keyboard, SeatBackend, SeatError, SeatEvent};

/// Every socket1 exchange — connect, write, read to EOF — finishes inside
/// this, measured absolutely: a compositor trickling bytes cannot stretch it.
const IO_BOUND: Duration = Duration::from_secs(2);
/// A `j/devices` answer is a few KiB per dozen devices; anything past this
/// is not an answer the seat verbs can use.
const MAX_REPLY: usize = 1024 * 1024;
/// Hyprland reads a request in short chunks until a short read; a request
/// past this (a kb_file path of kilobytes of escapes) is refused here
/// rather than risk arriving split.
const MAX_REQUEST: usize = 8 * 1024;
/// One socket2 line past this is skipped whole, not buffered.
const MAX_EVENT_LINE: usize = 64 * 1024;
/// How often the readback after a `kb_file` change is retried, and how far
/// apart: the setting is applied on the compositor's own loop.
const READBACK_TRIES: u32 = 10;
const READBACK_GAP: Duration = Duration::from_millis(50);

pub(crate) struct Hyprland {
    socket1: PathBuf,
    socket2: PathBuf,
}

impl Hyprland {
    /// The backend for the Hyprland instance this helper was started under,
    /// or `None` outside one. Whether its sockets still answer is asked per
    /// request, so a compositor that goes away reads as no backend.
    pub(crate) fn from_env() -> Option<Self> {
        let signature = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
        // The signature is one path component; anything else is not one.
        if signature.is_empty() || signature.contains('/') || signature == ".." {
            return None;
        }
        let runtime = std::env::var("XDG_RUNTIME_DIR").ok()?;
        Some(Self::at(&PathBuf::from(runtime).join("hypr").join(signature)))
    }

    fn at(dir: &Path) -> Self {
        Hyprland {
            socket1: dir.join(".socket.sock"),
            socket2: dir.join(".socket2.sock"),
        }
    }

    /// One socket1 exchange, bounded in time and size.
    fn request(&self, body: &str) -> Result<String, SeatError> {
        if body.len() > MAX_REQUEST {
            return Err(SeatError::TooLong);
        }
        let deadline = Instant::now() + IO_BOUND;
        let mut stream = connect_bounded(&self.socket1, IO_BOUND).map_err(|error| {
            match error.kind() {
                // The socket is gone or nobody listens on it: the compositor
                // this helper was started under is not there any more.
                std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused => {
                    SeatError::NoBackend
                }
                _ => SeatError::Unreachable,
            }
        })?;
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() || stream.set_write_timeout(Some(left)).is_err() {
            return Err(SeatError::Unreachable);
        }
        stream
            .write_all(body.as_bytes())
            .map_err(|_| SeatError::Unreachable)?;
        let mut reply = Vec::new();
        let mut chunk = [0u8; 8192];
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() || stream.set_read_timeout(Some(left)).is_err() {
                return Err(SeatError::Unreachable);
            }
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    reply.extend_from_slice(&chunk[..n]);
                    if reply.len() > MAX_REPLY {
                        return Err(SeatError::Unreadable);
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return Err(SeatError::Unreachable),
            }
        }
        String::from_utf8(reply).map_err(|_| SeatError::Unreadable)
    }

    /// A request whose whole answer is `ok`; anything else is the
    /// compositor refusing, in its own words.
    fn command(&self, body: &str) -> Result<(), SeatError> {
        let reply = self.request(body)?;
        if reply.trim() == "ok" {
            Ok(())
        } else {
            Err(SeatError::Refused(reply))
        }
    }

    /// Reads the event stream until it ends; `Err` only for a stream that
    /// could not be opened at all. `resumed` says an earlier stream ended:
    /// whatever it carried in between is lost, so listeners are told to
    /// re-read rather than trust a state that missed its events.
    fn pump_events(&self, sink: &dyn EventSink, resumed: bool) -> std::io::Result<()> {
        let stream = connect_bounded(&self.socket2, IO_BOUND)?;
        // A read timeout on a stream that only speaks when something
        // happens is a keep-alive, not a failure: the wait resumes.
        stream.set_read_timeout(Some(Duration::from_secs(300)))?;
        if resumed && sink.listening() {
            sink.send(SeatEvent::Devices);
        }
        pump(stream, sink, |data| {
            self.keyboards()
                .map(|keyboards| layout_event(data, &keyboards))
                .unwrap_or(SeatEvent::Devices)
        });
        Ok(())
    }

    /// Hotplug: an `event*` node appearing in or leaving `/dev/input`.
    ///
    /// Chosen over udev's netlink monitor (a socket family the unit does not
    /// allow, `RestrictAddressFamilies=AF_UNIX`) and over polling (a wake
    /// with nothing to say). The node appears before the compositor has
    /// taken the device in, so a burst is coalesced and then the device list
    /// is re-read until it changes — or a short window passes — before the
    /// listeners are told to re-read it themselves.
    fn watch_hotplug(&self, sink: &dyn EventSink) {
        let Some(watch) = InputNodeWatch::open(Path::new("/dev/input")) else {
            eprintln!("[oskar] cannot watch /dev/input; seat hotplug events are off");
            return;
        };
        let names = || {
            self.keyboards()
                .map(|keyboards| keyboards.into_iter().map(|k| k.name).collect::<Vec<_>>())
                .ok()
        };
        let mut known = names();
        loop {
            match watch.wait(None) {
                Ok(true) => {}
                Ok(false) => continue,
                Err(error) => {
                    eprintln!("[oskar] /dev/input watch failed ({error}); seat hotplug events are off");
                    return;
                }
            }
            // One device is several nodes; let the burst finish.
            while let Ok(true) = watch.wait(Some(Duration::from_millis(200))) {}
            let mut now = names();
            for _ in 0..8 {
                if now != known {
                    break;
                }
                thread::sleep(Duration::from_millis(250));
                now = names();
            }
            known = now;
            if sink.listening() {
                sink.send(SeatEvent::Devices);
            }
        }
    }
}

impl SeatBackend for Hyprland {
    fn keyboards(&self) -> Result<Vec<Keyboard>, SeatError> {
        parse_devices(&self.request("j/devices")?)
    }

    fn kb_file(&self) -> Result<String, SeatError> {
        parse_kb_file(&self.request("j/getoption input:kb_file")?)
    }

    fn switch_group(&self, device: &str, group: u32) -> Result<(), SeatError> {
        // The request is space-separated on the compositor's side, so a
        // name with whitespace would address some other device.
        if device.is_empty() || device.chars().any(|c| c.is_whitespace() || c.is_control()) {
            return Err(SeatError::Refused("device name".to_string()));
        }
        self.command(&format!("/switchxkblayout {device} {group}"))
    }

    fn share(&self, path: Option<&str>) -> Result<(), SeatError> {
        // Cleared and then set, never just set: assigning the value the
        // setting already holds is a no-op, and a keymap republished under
        // the same name has to be re-read, or the compositor keeps compiling
        // the one before it. `eval`, not `keyword`: the Lua config parser
        // refuses `keyword` outright.
        let set = path.map(kb_file_eval);
        if set.as_ref().is_some_and(|body| body.len() > MAX_REQUEST) {
            return Err(SeatError::TooLong);
        }
        self.command(&kb_file_eval(""))?;
        if let Some(set) = set {
            self.command(&set)?;
        }
        // Read back rather than trust: `eval` answers `ok` for a call the
        // parser accepted, which is not the value being in place.
        let wanted = path.unwrap_or("");
        let mut last = Err(SeatError::NotApplied);
        for attempt in 0..READBACK_TRIES {
            if attempt > 0 {
                thread::sleep(READBACK_GAP);
            }
            last = match self.kb_file() {
                Ok(actual) if actual == wanted => return Ok(()),
                Ok(_) => Err(SeatError::NotApplied),
                Err(error) => Err(error),
            };
        }
        last
    }

    fn watch(self: Arc<Self>, sink: Arc<dyn EventSink>) {
        let events = Arc::clone(&self);
        let events_sink = Arc::clone(&sink);
        let spawned = thread::Builder::new()
            .name("osk-seat-events".into())
            .spawn(move || {
                // Reconnects with a growing pause: a compositor that went
                // away takes this helper's Wayland connection with it, so a
                // long outage ends in a restart, not in this loop.
                let mut pause = Duration::from_secs(1);
                let mut resumed = false;
                loop {
                    let opened = events.pump_events(&*events_sink, resumed).is_ok();
                    if opened {
                        pause = Duration::from_secs(1);
                        resumed = true;
                    }
                    thread::sleep(pause);
                    pause = (pause * 2).min(Duration::from_secs(30));
                }
            });
        if spawned.is_err() {
            eprintln!("[oskar] cannot spawn the seat event reader; layout events are off");
        }
        let spawned = thread::Builder::new()
            .name("osk-seat-hotplug".into())
            .spawn(move || self.watch_hotplug(&*sink));
        if spawned.is_err() {
            eprintln!("[oskar] cannot spawn the hotplug watch; device events are off");
        }
    }
}

/// Reads socket2 lines until EOF or a hard error, handing each event the
/// seat cares about to `sink`. `resolve` turns an `activelayout` payload
/// into its event; it is only asked when someone is listening, so an
/// unwatched seat costs no socket1 round trips.
fn pump(stream: impl Read, sink: &dyn EventSink, resolve: impl Fn(&str) -> SeatEvent) {
    let mut reader = BufReader::with_capacity(8 * 1024, stream);
    let mut line = Vec::new();
    let mut skipping = false;
    loop {
        let limit = (MAX_EVENT_LINE + 1).saturating_sub(line.len()) as u64;
        match (&mut reader).take(limit).read_until(b'\n', &mut line) {
            Ok(0) => return,
            Ok(_) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock
                        | std::io::ErrorKind::TimedOut
                        | std::io::ErrorKind::Interrupted
                ) =>
            {
                continue
            }
            Err(_) => return,
        }
        if line.last() != Some(&b'\n') {
            if line.len() > MAX_EVENT_LINE {
                // An overlong line is dropped whole: its tail, when it comes,
                // is not an event either.
                line.clear();
                skipping = true;
            }
            continue;
        }
        let complete = std::mem::take(&mut line);
        if std::mem::take(&mut skipping) {
            continue;
        }
        let Ok(text) = std::str::from_utf8(&complete) else {
            continue;
        };
        let text = text.trim_end_matches(['\n', '\r']);
        if let Some(data) = text.strip_prefix("activelayout>>") {
            if sink.listening() {
                sink.send(resolve(data));
            }
        } else if text.starts_with("configreloaded>>") && sink.listening() {
            sink.send(SeatEvent::Devices);
        }
    }
}

/// An `activelayout` payload (`<device>,<layout name>`) as the event the
/// protocol carries: the device and the group it is on now.
///
/// The layout part is a human name that can itself hold commas ("English
/// (US, intl., with dead keys)"), so the device is found by the longest
/// known name the payload starts with, never by splitting. A device the
/// inventory does not know (it left between the event and the read) asks
/// the listener to re-read instead.
fn layout_event(data: &str, keyboards: &[Keyboard]) -> SeatEvent {
    keyboards
        .iter()
        .filter(|k| {
            !k.name.is_empty()
                && data.len() > k.name.len()
                && data.starts_with(&k.name)
                && data.as_bytes()[k.name.len()] == b','
        })
        .max_by_key(|k| k.name.len())
        .map_or(SeatEvent::Devices, |k| SeatEvent::Layout {
            device: k.name.clone(),
            group: k.active_layout_index,
        })
}

/// The keyboards of a `j/devices` answer. A document without a
/// `keyboards` array, or a keyboard without a name, is unreadable as a
/// whole: half an inventory would steer the device tiers wrong. Absent
/// optional facts read as the panel's own defaults (empty, not current,
/// group 0).
fn parse_devices(text: &str) -> Result<Vec<Keyboard>, SeatError> {
    let document = json::parse(text).ok_or(SeatError::Unreadable)?;
    let list = document
        .get("keyboards")
        .and_then(json::Json::as_array)
        .ok_or(SeatError::Unreadable)?;
    list.iter()
        .map(|entry| {
            let name = entry
                .get("name")
                .and_then(json::Json::as_str)
                .filter(|name| !name.is_empty())
                .ok_or(SeatError::Unreadable)?;
            let text = |key: &str| {
                entry
                    .get(key)
                    .and_then(json::Json::as_str)
                    .unwrap_or("")
                    .to_string()
            };
            Ok(Keyboard {
                name: name.to_string(),
                main: entry.get("main").and_then(json::Json::as_bool).unwrap_or(false),
                active_layout_index: entry
                    .get("active_layout_index")
                    .and_then(json::Json::as_u32)
                    .unwrap_or(0),
                layout: text("layout"),
                variant: text("variant"),
                rules: text("rules"),
                model: text("model"),
                options: text("options"),
            })
        })
        .collect()
}

/// The value of a `j/getoption input:kb_file` answer. Hyprland spells an
/// unset string option `[[EMPTY]]`; it means empty here too.
fn parse_kb_file(text: &str) -> Result<String, SeatError> {
    let value = json::parse(text)
        .as_ref()
        .and_then(|document| document.get("str"))
        .and_then(json::Json::as_str)
        .map(str::to_string)
        .ok_or(SeatError::Unreadable)?;
    Ok(if value == "[[EMPTY]]" { String::new() } else { value })
}

/// The socket1 request that sets `input:kb_file` to `path`.
fn kb_file_eval(path: &str) -> String {
    format!("/eval hl.config({{input = {{kb_file = {}}}}})", lua_quote(path))
}

/// `value` as a single-quoted Lua string literal that nothing inside can
/// close: `\`, `'` and `"` are backslash-escaped, printable ASCII rides as
/// itself, and every other byte — control bytes, a newline, each byte of a
/// non-ASCII character — becomes a three-digit `\ddd` escape (three
/// digits always, so a following digit can never extend the escape). A
/// crafted filename is data, never config-side Lua.
fn lua_quote(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('\'');
    for byte in value.bytes() {
        match byte {
            b'\\' | b'\'' | b'"' => {
                out.push('\\');
                out.push(byte as char);
            }
            32..=126 => out.push(byte as char),
            _ => out.push_str(&format!("\\{byte:03}")),
        }
    }
    out.push('\'');
    out
}

/// A socket1/socket2 connection whose connect is bounded too: a compositor
/// that stopped accepting fills its listen backlog, and a blocking connect
/// would then park the asking thread with no timeout at all.
fn connect_bounded(path: &Path, bound: Duration) -> std::io::Result<UnixStream> {
    let deadline = Instant::now() + bound;
    loop {
        match connect_nonblocking(path) {
            Ok(stream) => {
                stream.set_nonblocking(false)?;
                return Ok(stream);
            }
            Err(error)
                if error.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < deadline =>
            {
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                return Err(std::io::ErrorKind::TimedOut.into())
            }
            Err(error) => return Err(error),
        }
    }
}

/// One non-blocking connect attempt. A full backlog answers `EAGAIN`
/// immediately instead of parking; the caller retries inside its bound.
fn connect_nonblocking(path: &Path) -> std::io::Result<UnixStream> {
    use std::os::fd::{FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;

    let bytes = path.as_os_str().as_bytes();
    // SAFETY: sockaddr_un is plain data; all-zero is a valid value and
    // leaves the path NUL-terminated after the copy below.
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.is_empty() || bytes.len() >= address.sun_path.len() || bytes.contains(&0) {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (slot, byte) in address.sun_path.iter_mut().zip(bytes) {
        *slot = *byte as libc::c_char;
    }
    // SAFETY: socket takes plain integers; a non-negative return is a fresh
    // descriptor, owned from the next line on.
    let raw = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            0,
        )
    };
    if raw < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: `raw` was just returned by socket and nothing else owns it.
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    // SAFETY: the address is a live, initialised sockaddr_un and its size
    // is passed with it.
    let connected = unsafe {
        libc::connect(
            raw,
            (&address as *const libc::sockaddr_un).cast(),
            std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t,
        )
    };
    if connected == 0 {
        return Ok(UnixStream::from(fd));
    }
    let error = std::io::Error::last_os_error();
    if matches!(error.raw_os_error(), Some(libc::EAGAIN) | Some(libc::EINPROGRESS)) {
        return Err(std::io::ErrorKind::WouldBlock.into());
    }
    Err(error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::sync::Mutex;

    /// `hyprctl devices -j` captured from the lab (Hyprland 0.56.2): two
    /// USB keyboard interfaces, a power button, the AT keyboard, a ydotool
    /// device, this helper's own virtual keyboard and fcitx5's, which holds
    /// the `main` flag.
    const DEVICES_FIXTURE: &str = include_str!("../tests/fixtures/hyprctl-devices.json");

    #[test]
    fn the_captured_inventory_parses_into_the_facts_the_panel_reads() {
        let keyboards = parse_devices(DEVICES_FIXTURE).expect("the fixture is a devices answer");
        let names: Vec<&str> = keyboards.iter().map(|k| k.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "qemu-qemu-usb-keyboard",
                "qemu-qemu-usb-keyboard-1",
                "power-button",
                "at-translated-set-2-keyboard",
                "ydotoold-virtual-device",
                "hl-virtual-keyboard-oskar-daemon",
                "hl-virtual-keyboard-fcitx5",
            ]
        );
        let first = &keyboards[0];
        assert_eq!(first.layout, "us,ua,it,ru");
        assert_eq!(first.options, "shift:both_capslock_cancel,grp:caps_toggle");
        assert_eq!(first.active_layout_index, 0);
        assert!(!first.main);
        assert_eq!(first.rules, "");
        let current: Vec<&str> = keyboards
            .iter()
            .filter(|k| k.main)
            .map(|k| k.name.as_str())
            .collect();
        assert_eq!(current, ["hl-virtual-keyboard-fcitx5"]);
    }

    #[test]
    fn a_malformed_inventory_is_unreadable_never_empty() {
        for bad in [
            "",
            "device not found",
            "{\"keyboards\": ",
            "{\"mice\": []}",
            "{\"keyboards\": {}}",
            "{\"keyboards\": [{\"layout\": \"us\"}]}",
            "{\"keyboards\": [{\"name\": \"\"}]}",
        ] {
            assert_eq!(parse_devices(bad), Err(SeatError::Unreadable), "{bad:?}");
        }
        // An empty list is an honest answer: a seat with no keyboards.
        assert_eq!(parse_devices("{\"keyboards\": []}"), Ok(vec![]));
    }

    #[test]
    fn the_kb_file_answer_reads_set_unset_and_refuses_the_rest() {
        assert_eq!(
            parse_kb_file(r#"{"option": "input:kb_file", "str": "/run/user/1000/oskar/keymap.xkb", "set": true }"#),
            Ok("/run/user/1000/oskar/keymap.xkb".to_string())
        );
        assert_eq!(
            parse_kb_file(r#"{"option": "input:kb_file", "str": "[[EMPTY]]", "set": false }"#),
            Ok(String::new())
        );
        assert_eq!(parse_kb_file(r#"{"str": ""}"#), Ok(String::new()));
        // A failed read is an error, never an observed empty kb_file.
        for bad in ["", "no such option", "{\"option\": \"input:kb_file\"}", "{\"str\": 1}"] {
            assert_eq!(parse_kb_file(bad), Err(SeatError::Unreadable), "{bad:?}");
        }
    }

    #[test]
    fn lua_quote_matches_the_panels_escaping() {
        assert_eq!(lua_quote(""), "''");
        assert_eq!(lua_quote("plain.xkb"), "'plain.xkb'");
        assert_eq!(lua_quote("a\"b"), "'a\\\"b'");
        assert_eq!(lua_quote("a\\b"), "'a\\\\b'");
        assert_eq!(lua_quote("it's"), "'it\\'s'");
        // Control bytes pad to three digits: \001 then a literal digit.
        assert_eq!(lua_quote("\u{1}4"), "'\\0014'");
        assert_eq!(lua_quote("\u{7f}"), "'\\127'");
        // Non-ASCII rides as its UTF-8 bytes.
        assert_eq!(lua_quote("é"), "'\\195\\169'");
        assert_eq!(lua_quote("в"), "'\\208\\178'");
    }

    /// Decodes a literal the way Lua does, for the three escapes lua_quote
    /// emits, and fails on anything that would end the literal early.
    fn lua_unquote(literal: &str) -> Vec<u8> {
        let inner = literal
            .strip_prefix('\'')
            .and_then(|rest| rest.strip_suffix('\''))
            .expect("one single-quoted literal");
        let bytes = inner.as_bytes();
        let mut out = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            match bytes[i] {
                b'\\' if bytes[i + 1].is_ascii_digit() => {
                    let digits = std::str::from_utf8(&bytes[i + 1..i + 4]).unwrap();
                    out.push(digits.parse::<u8>().unwrap());
                    i += 4;
                }
                b'\\' => {
                    out.push(bytes[i + 1]);
                    i += 2;
                }
                b'\'' | b'\n' | b'\r' => panic!("the literal closes early at byte {i}: {literal:?}"),
                byte => {
                    out.push(byte);
                    i += 1;
                }
            }
        }
        out
    }

    #[test]
    fn a_path_with_a_quote_and_a_newline_cannot_break_out_of_the_literal() {
        for evil in [
            "/home/user/map'}}); print('INJECTED'); --",
            "/tmp/a\nb'c}})\n--",
            "/tmp/x\\'}}) os.exit() --",
            "/tmp/\"quoted\"\r\n\t\u{0}",
            "/tmp/влад/é.xkb",
        ] {
            let quoted = lua_quote(evil);
            assert!(!quoted.contains('\n') && !quoted.contains('\r') && !quoted.contains('\0'));
            assert!(quoted.is_ascii());
            assert_eq!(lua_unquote(&quoted), evil.as_bytes(), "{evil:?}");
            // And the whole eval request stays one self-contained call.
            let request = kb_file_eval(evil);
            assert!(request.starts_with("/eval hl.config({input = {kb_file = '"));
            assert!(request.ends_with("'}})"));
        }
    }

    #[test]
    fn a_layout_event_names_its_device_and_the_group_it_is_on() {
        let keyboards = vec![
            Keyboard {
                name: "kbd".into(),
                active_layout_index: 0,
                ..Keyboard::default()
            },
            Keyboard {
                name: "kbd-1".into(),
                active_layout_index: 2,
                ..Keyboard::default()
            },
        ];
        assert_eq!(
            layout_event("kbd-1,English (US, intl., with dead keys)", &keyboards),
            SeatEvent::Layout {
                device: "kbd-1".into(),
                group: 2
            }
        );
        assert_eq!(
            layout_event("kbd,Ukrainian", &keyboards),
            SeatEvent::Layout {
                device: "kbd".into(),
                group: 0
            }
        );
        // A device the inventory no longer knows: re-read, never a guess.
        assert_eq!(layout_event("gone,English (US)", &keyboards), SeatEvent::Devices);
        assert_eq!(layout_event("kbd", &keyboards), SeatEvent::Devices);
    }

    struct Recorder {
        listening: bool,
        seen: Mutex<Vec<SeatEvent>>,
    }

    impl EventSink for Recorder {
        fn listening(&self) -> bool {
            self.listening
        }
        fn send(&self, event: SeatEvent) {
            self.seen.lock().unwrap().push(event);
        }
    }

    #[test]
    fn the_event_stream_yields_layout_and_reload_and_skips_the_rest() {
        let overlong = format!("activelayout>>{}\n", "x".repeat(MAX_EVENT_LINE + 10));
        let stream = format!(
            "workspace>>2\nactivelayout>>kbd,English (US)\n{overlong}\
             configreloaded>>\nactivewindow>>foot,title\nactivelayout>>kbd,Ukrainian"
        );
        let sink = Recorder {
            listening: true,
            seen: Mutex::new(Vec::new()),
        };
        pump(stream.as_bytes(), &sink, |data| SeatEvent::Layout {
            device: data.split(',').next().unwrap().to_string(),
            group: 7,
        });
        // The unterminated last line is not an event: the stream ended
        // inside it.
        assert_eq!(
            *sink.seen.lock().unwrap(),
            [
                SeatEvent::Layout {
                    device: "kbd".into(),
                    group: 7
                },
                SeatEvent::Devices,
            ]
        );

        // Nobody listening: nothing resolved, nothing sent.
        let idle = Recorder {
            listening: false,
            seen: Mutex::new(Vec::new()),
        };
        pump("activelayout>>kbd,English (US)\n".as_bytes(), &idle, |_| {
            panic!("resolved an event nobody listens to")
        });
        assert!(idle.seen.lock().unwrap().is_empty());
    }

    /// A stand-in for Hyprland's socket1: answers each connection's request
    /// from `answer` and records what was asked.
    fn fake_compositor(
        tag: &str,
        answer: impl Fn(&str) -> String + Send + 'static,
    ) -> (Hyprland, Arc<Mutex<Vec<String>>>, PathBuf) {
        let dir = std::env::temp_dir().join(format!("osk-h-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let listener = UnixListener::bind(dir.join(".socket.sock")).unwrap();
        let asked = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&asked);
        thread::spawn(move || {
            for mut stream in listener.incoming().flatten() {
                let mut buf = [0u8; 16384];
                let n = stream.read(&mut buf).unwrap_or(0);
                let request = String::from_utf8_lossy(&buf[..n]).to_string();
                log.lock().unwrap().push(request.clone());
                let _ = stream.write_all(answer(&request).as_bytes());
            }
        });
        (Hyprland::at(&dir), asked, dir)
    }

    #[test]
    fn share_clears_sets_and_reads_back_through_socket1() {
        let current = Arc::new(Mutex::new(String::from("[[EMPTY]]")));
        let state = Arc::clone(&current);
        let (hyprland, asked, dir) = fake_compositor("share", move |request| {
            if let Some(lua) = request.strip_prefix("/eval hl.config({input = {kb_file = ") {
                let literal = lua.strip_suffix("}})").unwrap();
                let value = String::from_utf8(lua_unquote(literal)).unwrap();
                *state.lock().unwrap() = if value.is_empty() { "[[EMPTY]]".into() } else { value };
                "ok".to_string()
            } else if request == "j/getoption input:kb_file" {
                format!("{{\"option\": \"input:kb_file\", \"str\": {}, \"set\": true }}",
                    json::quote(&state.lock().unwrap()))
            } else {
                "unknown request".to_string()
            }
        });
        let path = "/run/user/1000/oskar/it's keymap.xkb";
        assert_eq!(hyprland.share(Some(path)), Ok(()));
        assert_eq!(hyprland.kb_file(), Ok(path.to_string()));
        assert_eq!(
            asked.lock().unwrap()[..3],
            [
                "/eval hl.config({input = {kb_file = ''}})".to_string(),
                format!("/eval hl.config({{input = {{kb_file = {}}}}})", lua_quote(path)),
                "j/getoption input:kb_file".to_string(),
            ]
        );
        asked.lock().unwrap().clear();
        assert_eq!(hyprland.share(None), Ok(()));
        assert_eq!(hyprland.kb_file(), Ok(String::new()));
        assert_eq!(asked.lock().unwrap()[0], "/eval hl.config({input = {kb_file = ''}})");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_compositor_that_refuses_or_does_not_apply_is_an_error() {
        let (refusing, _, dir) = fake_compositor("refuse", |request| {
            if request.starts_with("/switchxkblayout") {
                "device not found".to_string()
            } else if request.starts_with("/eval") {
                "error: unknown config key".to_string()
            } else {
                "{\"str\": \"/somewhere/else\"}".to_string()
            }
        });
        assert_eq!(
            refusing.switch_group("nope", 1),
            Err(SeatError::Refused("device not found".into()))
        );
        assert!(matches!(refusing.share(Some("/x")), Err(SeatError::Refused(_))));
        assert_eq!(
            refusing.switch_group("two words", 1),
            Err(SeatError::Refused("device name".into()))
        );
        let _ = std::fs::remove_dir_all(dir);

        let (stale, _, dir) = fake_compositor("stale", |request| {
            if request.starts_with("/eval") {
                "ok".to_string()
            } else {
                "{\"str\": \"/somewhere/else\"}".to_string()
            }
        });
        assert_eq!(stale.share(Some("/x")), Err(SeatError::NotApplied));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn socket1_reads_are_capped_and_a_missing_socket_is_no_backend() {
        let (flood, _, dir) = fake_compositor("flood", |_| "x".repeat(MAX_REPLY + 1));
        assert_eq!(flood.keyboards(), Err(SeatError::Unreadable));
        let _ = std::fs::remove_dir_all(dir);

        let gone = Hyprland::at(Path::new("/nonexistent/osk-hypr"));
        assert_eq!(gone.keyboards(), Err(SeatError::NoBackend));
        assert_eq!(gone.request(&"x".repeat(MAX_REQUEST + 1)), Err(SeatError::TooLong));
    }

    #[test]
    fn a_silent_compositor_is_bounded() {
        let dir = std::env::temp_dir().join(format!("osk-h-silent-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let listener = UnixListener::bind(dir.join(".socket.sock")).unwrap();
        // Accepts and never answers, holding the connection open.
        let held = thread::spawn(move || listener.accept().map(|(stream, _)| {
            thread::sleep(IO_BOUND + Duration::from_secs(1));
            drop(stream);
        }));
        let started = Instant::now();
        assert_eq!(Hyprland::at(&dir).keyboards(), Err(SeatError::Unreachable));
        assert!(started.elapsed() < IO_BOUND + Duration::from_millis(500));
        let _ = held.join();
        let _ = std::fs::remove_dir_all(dir);
    }
}
