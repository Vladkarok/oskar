//! The session around the helper: its runtime directory, the files it
//! publishes there, and the physical keyboards the seat carries.

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
