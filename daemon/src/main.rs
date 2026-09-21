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
//!   caps <group> [positions...]
//!                     keycap facts for the named group of the installed
//!                     keymap (decisions §23): one line, records separated by
//!                     0x1E, fields by 0x1F, each field `t<text>` (resolved
//!                     character text), `x<keysym>` (a symbol that produces no
//!                     character) or `n` (no symbol at this level). Without a
//!                     position list every named key is answered.
//! Replies are `ok`, `hello <n>`,
//! `configured<TAB><generation>`, `pong`,
//! `keyboards<TAB>name...`, `caps<TAB><generation><TAB><group><TAB><records>`,
//! or `err <reason>`.
//!
//! The generation is the count of keymap installs this process has performed.
//! It is what the panel correlates its keycap facts against: a same-keymap
//! reconfigure keeps the generation (the installed keymap did not change), a
//! changed one bumps it, so a facts reply computed from a superseded keymap is
//! detectable and discardable. The panel and the helper move protocol
//! versions together, which is what keeps an updated panel and an
//! installed old helper from ever negotiating the wrong reply shapes
//! (decisions §23; version 6 — the typed delivery verbs are gone, a v5
//! peer is a reinstall).
//!
//! Key repeat belongs to the compositor: a press is `down`, a release is `up`,
//! and nothing here or in the panel repeats anything. What the helper does add
//! is a cap — a non-modifier code held past fifteen seconds is lifted and
//! logged, because the only way that happens is a panel that is alive but
//! wedged. Modifier codes are exempt; locked Shift is deliberately held.

use std::io::{BufReader, Read, Write};
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
/// reinstalling the helper says so instead of failing silently. Version 4 adds
/// the keycap-facts reply and the generation on `configured`; the panel learned
/// both in the same release, so the version gate is what keeps the pair honest.
/// Version 5 (HISTORICAL) added `text-unicode`: unlike ticket 24's initially additive
/// `text`, it is selected automatically for Chromium-family clients, so an
/// updated panel must fail the hello gate against an older helper instead of
/// accepting clicks that can only earn `err unknown command`.
/// Version 6 (§91): the typed delivery verbs (`text`, `text-unicode`)
/// and their `text-ok`/`text-err` replies are GONE — every emoji pick
/// rides the clipboard; the protocol is configure/caps/keyboards/group/
/// mods/down/up/tap/ping/hello. A v5 panel still sending text verbs
/// fails loudly per line instead of silently mistyping.
const PROTOCOL_VERSION: u32 = 6;

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
        std::env::var("OSKAR_HOLD_CAP_MS")
            .ok()
            .and_then(|raw| raw.trim().parse::<u64>().ok())
            .filter(|ms| *ms > 0)
            .map_or(DEFAULT_HOLD_CAP, Duration::from_millis)
    })
}

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
    /// Whether two configures ask for the same keymap, group aside.
    ///
    /// For an RMLVO configure the fields ARE the keymap: same names, same
    /// compile. For a `kb_file` they are not — the path says where to look,
    /// and the file behind it is edited in place far more often than it is
    /// renamed. Content identity is the caller's to check (`kb_file_mark`),
    /// because it costs a read and this comparison is on the hot path.
    fn same_keymap(&self, other: &Self) -> bool {
        self.rules == other.rules
            && self.model == other.model
            && self.layouts == other.layouts
            && self.variants == other.variants
            && self.options == other.options
            && self.kb_file == other.kb_file
    }
}

/// What the bytes behind a `kb_file` path currently are, as one number.
///
/// Ticket 06: a custom keymap is edited at the same path and the compositor
/// is reloaded. The path has not changed, so a comparison of configure fields
/// says "same keymap" and the helper keeps typing yesterday's map while the
/// panel draws caps for it — the two agreeing with each other and with
/// nothing the user can see.
///
/// The highest keycode this helper will ever walk. Stock evdev tops out
/// at 709; xkbcommon accepts keycodes to 4294967294 and a hostile 60-byte
/// keymap declaring one pinned the shared lock for ~9 s of pure iteration
/// per configure (round eleven's blocker) — the gate refuses such maps at
/// both compile doors, and the keycap walk iterates NAMED keys only.
const MAX_SANE_KEYCODE: u32 = 4096;

/// The largest `kb_file` this helper will ever read. The 2026-09-19 audit:
/// the mark and the compile each read the whole file, unbounded, under the
/// shared lock — a huge file exhausted memory and a FIFO blocked the
/// keyboard for everyone. One bounded read now feeds both callers.
const KB_FILE_LIMIT: u64 = 2 * 1024 * 1024;

/// A custom keymap's bytes, read once and bounded: a regular file no larger
/// than `KB_FILE_LIMIT`, `take`n to the limit plus one byte so a file grown
/// mid-read still answers a bounded number. Anything else — a FIFO (blocks),
/// a directory, a device, a vanished path — is refused before a single byte
/// is waited on.
fn read_kb_file_bounded(path: &str) -> Option<Vec<u8>> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    if path.is_empty() {
        return None;
    }
    // Open NONBLOCKING before anything else, then validate the DESCRIPTOR
    // (fstat), not the path: resolving the path twice — stat, then open —
    // leaves a window where a FIFO swapped in between parks this thread
    // under the shared lock (the review's second round). With the open
    // first and nonblocking, a FIFO opens instantly and the fstat refuses
    // it; what is read is exactly what was checked.
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > KB_FILE_LIMIT {
        return None;
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(KB_FILE_LIMIT + 1).read_to_end(&mut bytes).ok()?;
    if bytes.len() as u64 > KB_FILE_LIMIT {
        return None;
    }
    Some(bytes)
}

fn hash_bytes(bytes: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish()
}

/// A field xkbcommon's CString conversion would panic on. An interior NUL
/// never arrives from a real panel, but the socket is same-user input and
/// the panic fires under the shared lock: the mutex poisons, every later
/// `lock().unwrap()` panics, and the helper stays alive while doing
/// nothing — systemd sees no crash and never restarts it (2026-09-19
/// audit, finding 1). Refused exactly like a failing compile.
fn xkb_field_clean(text: &str) -> bool {
    !text.contains('\0')
}

/// The whole file, not its mtime or its length: an editor that writes in
/// place keeps the length identical often enough (one glyph for another), and
/// mtime is what a `cp -p` or a restored backup does not change. Production
/// composes this inline (one bounded read feeds the mark and the compile);
/// the wrapper exists for the suite, which has no lock to share a read across.
#[cfg(test)]
fn kb_file_mark(path: &str) -> Option<u64> {
    Some(hash_bytes(&read_kb_file_bounded(path)?))
}

/// Builds a keymap for an RMLVO layout list such as "us,ua". The kb_file
/// bytes are the caller's to supply (`install_config` reads once and feeds
/// both the mark and this compile); this reading wrapper exists for the
/// suite, for the same reason.
#[cfg(test)]
fn compile_keymap(config: &XkbConfig) -> Option<String> {
    let bytes = read_kb_file_bounded(&config.kb_file);
    compile_keymap_with(config, bytes.as_deref())
}

fn compile_keymap_with(config: &XkbConfig, kb_file_bytes: Option<&[u8]>) -> Option<String> {
    use xkbcommon::xkb;
    if !xkb_field_clean(&config.rules)
        || !xkb_field_clean(&config.model)
        || !xkb_field_clean(&config.layouts)
        || !xkb_field_clean(&config.variants)
        || !xkb_field_clean(&config.options)
    {
        return None;
    }
    let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    // Never our own published file. It is this helper's OUTPUT (§35), and
    // taking it as input freezes whatever version wrote it: upgrade the
    // helper while the compositor still points at yesterday's file and the
    // new one reads it back, recognises the block, keeps it verbatim and
    // republishes it — the old keymap outliving the code that made it. The
    // compositor's RMLVO is the source; the file is only ever the answer.
    // Compared after canonicalising both, because the panel names this path
    // by building it from `$XDG_RUNTIME_DIR` and the two spellings need not
    // be byte-identical — a doubled separator or a symlinked runtime
    // directory would otherwise let our own output back in as an input.
    let from_file = !config.kb_file.is_empty() && !is_published_keymap(&config.kb_file);
    if from_file {
        let text = String::from_utf8(kb_file_bytes?.to_vec()).ok()?;
        // Same CString boundary as the RMLVO fields above: a NUL inside the
        // keymap text is refused, not panicked on.
        if !xkb_field_clean(&text) {
            return None;
        }
        let keymap = xkb::Keymap::new_from_string(
            &context,
            text,
            xkb::KEYMAP_FORMAT_TEXT_V1,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )?;
        if keymap.max_keycode().raw() > MAX_SANE_KEYCODE {
            return None;
        }
        let compiled = keymap.get_as_string(xkb::KEYMAP_FORMAT_TEXT_V1);
        // A user's own kb_file that somehow already carries the block is
        // taken as it stands: extending it again would put a second copy of
        // the catalogue in. Our own published file never reaches here.
        if compiled.contains("\"OSK_RESERVED\"") {
            return Some(compiled);
        }
        return Some(with_reserved_symbols(compiled));
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
    // The same keycode gate as the file doors (round twelve's blocker):
    // the RMLVO branch resolves the user's own ~/.config/xkb includes,
    // and a planted keycodes file brought maximum = 2000000000 through
    // this door — resurrecting the span-walk DoS the file gates closed.
    if keymap.max_keycode().raw() > MAX_SANE_KEYCODE {
        return None;
    }
    Some(with_reserved_symbols(
        keymap.get_as_string(xkb::KEYMAP_FORMAT_TEXT_V1),
    ))
}

/// The compiled keymap plus the reserved block, or the compiled keymap alone.
///
/// Fail-soft on purpose, and this is the one place it is right to be: the
/// block is an addition, and a keymap that will not compile is a keyboard that
/// types nothing. A map with no hostable position, or whose sections this
/// cannot find, or which the compiler rejects once extended, or whose
/// `<LVL5>` opens nothing, gives the user the layout they configured minus
/// some symbols — never a dead device. `extend_with_reserved` compiles what
/// it built before returning it, so everything that reaches the compositor
/// from here is a keymap; the panel finds out the ordinary way, because the
/// caps facts it draws from are computed from whichever text won.
fn with_reserved_symbols(keymap: String) -> String {
    match extend_with_reserved(&keymap) {
        Some(extended) => extended,
        None => {
            eprintln!("no reserved symbol block for this keymap; keymap unchanged");
            keymap
        }
    }
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

/// The symbols the panel may offer whatever language is configured (ticket 18).
///
/// A layout answers for its own alphabet and for whatever its designer put on
/// AltGr; nothing makes `us` produce `£` or `ua` produce `÷`. These are not a
/// layout's business at all, so the helper carries them itself, identically in
/// every group. Four per position, on levels five to eight: level five, Shift,
/// level three, Shift+level three (decisions §33).
///
/// Ordered by what the user would miss most, because the catalogue does not
/// always fit: it wants fourteen four-entry slots, and a layout that cannot
/// offer fourteen hostable positions gets a shorter one. The fifty-two
/// characters `&123` draws come first, so they survive a short allocation;
/// the last slot is spare capacity. Measured, option-free: `us`, `ua`, `ru`,
/// `de`, `fr`, `it`, `gr`, `hu`, `be`, `vn` and `lt` host all fourteen, `br`
/// thirteen, `cz`/`am`/`jp` twelve, `sk` ten, `kz` eight, and `de(neo)` and
/// `ca(multix)` two — those two put eight levels on nearly every position
/// already, so there is nothing to ride above. Every name is a real keysym — but a name libxkbcommon
/// accepts is not the same as a name an X11 client can turn into text:
/// `approximate` and `permille` reach a native Wayland client and produce
/// NOTHING in a GTK X11 one, reproducibly, while other non-Latin-1 entries
/// here come through fine. Spelling them as Unicode keysyms fixes both
/// (.scratch/unicode-symbols/README.md, gate round 2).
///
/// `U2248` rather than `U223C`: the legacy `approximate` keysym is U+223C
/// TILDE OPERATOR (∼), which is not the almost-equal sign (≈) a symbols page
/// wants and is a near-twin of the ASCII `~` already on the page.
const RESERVED_SYMBOLS: [&str; 56] = [
    // Everything drawn on the direct punctuation page comes first. Keeping
    // these in the helper-owned block removes the temporary switch to a `us`
    // group and makes a layout list such as `ua,ru` honest as well.
    "exclam",
    "1",
    "at",
    "2",
    "numbersign",
    "3",
    "dollar",
    "4",
    "percent",
    "5",
    "asciicircum",
    "6",
    "ampersand",
    "7",
    "asterisk",
    "8",
    "parenleft",
    "9",
    "parenright",
    "0",
    "grave",
    "minus",
    "equal",
    "bracketleft",
    "bracketright",
    "braceleft",
    "braceright",
    "backslash",
    "bar",
    "semicolon",
    "colon",
    "apostrophe",
    "quotedbl",
    "comma",
    "period",
    "slash",
    "underscore",
    "plus",
    "less",
    "greater",
    "question",
    "asciitilde",
    // The ten special glyphs visible on row four.
    "sterling",
    "EuroSign",
    "yen",
    "cent",
    "degree",
    "plusminus",
    "multiply",
    "U2248",
    "division",
    "notequal",
    // Spare catalogue capacity after the complete visible page.
    "notsign",
    "lessthanequal",
    "greaterthanequal",
    "infinity",
];

/// Where the catalogue lives (decisions §33): levels five to eight of the
/// digit row, then the two free positions that survive every consumer measured.
///
/// The digit row because a keycode is not a contract — a table lookup is.
/// Chromium's Ozone/Wayland path drops an evdev code its `DomCode` table does
/// not carry and Wine substitutes for one, so the exotic free positions ticket
/// 18 chose typed in a terminal and produced nothing (or a `?`) in the
/// applications the owner actually uses. `AE01`-`AE12` are in every one of
/// those tables. Letters are deliberately not here: an eight-level type
/// without `map[Lock]` costs a letter position its CapsLock, and `carried_
/// levels` refuses any position whose answer moves under Lock anyway.
const CATALOGUE_ROW: [&str; 12] = [
    "AE01", "AE02", "AE03", "AE04", "AE05", "AE06", "AE07", "AE08", "AE09", "AE10", "AE11", "AE12",
];

/// Positions that host what the digit row could not.
///
/// The digit row is twelve and the catalogue wants fourteen slots, and on a
/// good many stock layouts the row itself gives fewer: `kz`, `am`, `vn`, `cz`,
/// `sk`, `lt`, `gr`, `hu`, `be`, `fr` and `de(neo)` each lose some of it to a
/// position already reaching past four levels or answering to Lock. These
/// non-letter positions of the other three rows make up the difference where
/// the layout allows — each is put through the same refusal as the digit row,
/// so on a Cyrillic layout, where every one of them is a letter, none is
/// taken and nothing is lost that was not lost already.
const CATALOGUE_SPARE: [&str; 10] = [
    "AD11", "AD12", "AC10", "AC11", "AB08", "AB09", "AB10", "TLDE", "BKSL", "LSGT",
];

/// The two of the fourteen free positions ticket 20 measured through: `AB11`
/// is evdev 89, `AE13` is 124, and both reach a native-Wayland Chromium. They
/// carry the catalogue on the same levels five to eight as the digit row, so
/// there is one chord shape and not two; their own levels one to four are left
/// empty, which is what they already were.
const CATALOGUE_FREE: [&str; 2] = ["AB11", "AE13"];

/// The block's own key type. Levels one to four are whatever the position
/// already answered — for a free position, nothing — and `<LVL5>` opens the
/// catalogue above them, with Shift and `<LVL3>` choosing among its four.
///
/// No modifier is reserved for it: every compiled keymap already defines
/// `<LVL3>` as `ISO_Level3_Shift` and `<LVL5>` as `ISO_Level5_Shift` in one
/// unqualified definition each, which means the same levels in every group,
/// `us` included. `Lock` is deliberately absent from `modifiers`: a position
/// that answers to it is refused rather than hosted, so nothing here has to
/// preserve a CapsLock rule it did not write.
const RESERVED_TYPE: &str = "\n    type \"OSK_RESERVED\" {\n\
    \x20       modifiers = Shift+LevelThree+LevelFive;\n\
    \x20       map[None] = Level1;\n\
    \x20       map[Shift] = Level2;\n\
    \x20       map[LevelThree] = Level3;\n\
    \x20       map[Shift+LevelThree] = Level4;\n\
    \x20       map[LevelFive] = Level5;\n\
    \x20       map[Shift+LevelFive] = Level6;\n\
    \x20       map[LevelThree+LevelFive] = Level7;\n\
    \x20       map[Shift+LevelThree+LevelFive] = Level8;\n\
    \x20   };\n";

/// The body of one named xkb section, by brace matching.
///
/// Splitting on `};` the way parse_keycodes can afford to is not enough here:
/// the symbols section is full of nested `};` and the outer keymap closes with
/// one too, so a split lands either twenty lines in or at the end of the file.
fn section_bounds(keymap: &str, name: &str) -> Option<(usize, usize)> {
    let start = keymap.find(name)?;
    let open = keymap[start..].find('{')? + start;
    let mut depth = 0usize;
    for (offset, byte) in keymap[open..].bytes().enumerate() {
        match byte {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some((open + 1, open + offset));
                }
            }
            _ => {}
        }
    }
    None
}

/// Positions the keymap gives a keycode and no symbol, in keycode order.
///
/// Capped at 255 because XWayland's keymap is: a position above that reaches
/// native Wayland clients and silently nothing else, and half the point of
/// putting these in the keymap at all is that they work in X11 clients too.
fn free_positions(keymap: &str) -> Vec<String> {
    let Some((lo, hi)) = section_bounds(keymap, "xkb_keycodes") else {
        return Vec::new();
    };
    let mut declared: Vec<(u32, String)> = Vec::new();
    for line in keymap[lo..hi].lines() {
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
        if let Ok(code) = value.trim().trim_end_matches(';').trim().parse::<u32>() {
            if code <= 255 {
                declared.push((code, name.to_string()));
            }
        }
    }
    let Some((slo, shi)) = section_bounds(keymap, "xkb_symbols") else {
        return Vec::new();
    };
    let symbols = &keymap[slo..shi];
    let mut defined = std::collections::HashSet::new();
    for (index, _) in symbols.match_indices("key <") {
        let rest = &symbols[index + 5..];
        if let Some(end) = rest.find('>') {
            defined.insert(rest[..end].to_string());
        }
    }
    declared.sort();
    declared
        .into_iter()
        .filter(|(_, name)| !defined.contains(name))
        .map(|(_, name)| name)
        .collect()
}

/// The modifier masks the block's own type answers to, and the ones it must
/// prove a position ignores.
///
/// Masks, not keys. The first version of this held down `<CAPS>`, `<LALT>` and
/// `<LWIN>` to ask "does this position answer to Lock, Alt or Super?", and
/// under `grp:caps_toggle` — the owner's own option, and the VM's, and the one
/// every integration configure uses — pressing `<CAPS>` switches the GROUP, so
/// every digit-row position looked like it answered to something and every one
/// of them was refused. The catalogue collapsed to the two free positions.
/// The question was never about a key: it is whether the LOCK MODIFIER changes
/// what the position types, and an option is free to move Lock to any key or
/// to no key at all.
struct LevelProbe {
    /// The four chords the block's type reuses for levels one to four.
    chords: [u32; 4],
    /// Modifiers the block's type does not carry, which the position must
    /// therefore ignore for the type to be a faithful replacement.
    others: Vec<u32>,
    level_five: u32,
    /// The same modifier as real bits. `serialize_mods` reports real
    /// modifiers, and the virtual bit an xkb type is written in is not one of
    /// them, so asking what a key holds needs this and not `level_five`.
    level_five_real: u32,
}

impl LevelProbe {
    /// `None` when the keymap does not name one of the modifiers this rests
    /// on, which is a keymap the block has no business extending.
    fn new(compiled: &xkbcommon::xkb::Keymap) -> Option<Self> {
        let mask = |name: &str| -> Option<u32> {
            let index = compiled.mod_get_index(name);
            (index != xkbcommon::xkb::MOD_INVALID).then(|| 1u32 << index)
        };
        let shift = mask("Shift")?;
        let level_three = mask("LevelThree")?;
        let level_five = mask("LevelFive")?;
        let lock = mask("Lock")?;
        let control = mask("Control")?;
        let alt = mask("Mod1")?;
        let super_ = mask("Mod4")?;
        Some(LevelProbe {
            chords: [0, shift, level_three, shift | level_three],
            // Lock is the one ticket 20's rig named — an eight-level type
            // without `map[Lock]` costs an ALPHABETIC position its uppercasing
            // — and the other three are the modifier families the canonical
            // types use for a second level: PC_ALT_LEVEL2, CTRL+ALT,
            // PC_SUPER_LEVEL2. A position answering to any of them cannot be
            // hosted by a type that carries none of them.
            others: vec![lock, control, alt, super_, control | alt, level_five],
            level_five,
            level_five_real: {
                let mut state = xkbcommon::xkb::State::new(compiled);
                state.update_mask(level_five, 0, 0, 0, 0, 0);
                state.serialize_mods(xkbcommon::xkb::STATE_MODS_EFFECTIVE)
            },
        })
    }
}

/// What a position produces today, per group, for the four chords the block's
/// own type reuses — or `None` if it cannot host the catalogue.
///
/// Behavioural, not read off the key's type: a serialized keymap spells out no
/// type at all for an ordinary key (libxkbcommon infers it from the symbol
/// list and the serializer omits it), so there is nothing to read, and
/// reimplementing that inference is how this gets quietly wrong.
///
/// A position is refused when its answer moves under a modifier the block's
/// type does not carry (see `LevelProbe`), when a level carries several
/// keysyms, or when it already reaches past four levels — `de(neo)` puts eight
/// on the digit row and none of that can survive a four-entry slot.
fn carried_levels(
    compiled: &xkbcommon::xkb::Keymap,
    probe: &LevelProbe,
    code: u32,
) -> Option<Vec<[String; 4]>> {
    use xkbcommon::xkb;

    let mut per_group = Vec::with_capacity(compiled.num_layouts() as usize);
    for group in 0..compiled.num_layouts() {
        if compiled.num_levels_for_key(xkb::Keycode::from(code + 8), group) > 4 {
            return None;
        }
        let mut levels = [String::new(), String::new(), String::new(), String::new()];
        for (index, chord) in probe.chords.iter().enumerate() {
            let syms = syms_with_mods(compiled, group, *chord, code);
            if syms.len() > 1 {
                return None;
            }
            for extra in &probe.others {
                if syms_with_mods(compiled, group, chord | extra, code) != syms {
                    return None;
                }
            }
            // An empty level is a level: `ua` leaves AE01's Shift+AltGr with
            // NoSymbol, and spelling that back is what keeps the extended key
            // the same key.
            levels[index] = match syms.first() {
                Some(sym) => xkb::keysym_get_name(*sym),
                None => "NoSymbol".to_string(),
            };
        }
        per_group.push(levels);
    }
    Some(per_group)
}

/// The keysyms a position produces with those modifiers held, in a state that
/// starts clean and is thrown away afterwards.
fn syms_with_mods(
    compiled: &xkbcommon::xkb::Keymap,
    group: u32,
    mods: u32,
    code: u32,
) -> Vec<xkbcommon::xkb::Keysym> {
    use xkbcommon::xkb;
    let mut state = xkb::State::new(compiled);
    // The group rides in the locked-layout slot alone, for the reason
    // `modifier_masks_for_keymap` spells out: the three layout arguments add.
    state.update_mask(mods, 0, 0, 0, 0, group);
    state.key_get_syms(xkb::Keycode::from(code + 8)).to_vec()
}

/// Whether some ordinary key already carries `ISO_Level5_Shift`.
///
/// `lv5:ralt_switch_lock` and its cousins hand a physical key the modifier the
/// block's own levels answer to. Adding levels five to eight to a position
/// would then change what that key types — the one thing §33 promises it never
/// does — so when this is true the block stays off ordinary positions and
/// takes only the free ones, which had nothing to change.
fn a_physical_key_carries_level_five(
    compiled: &xkbcommon::xkb::Keymap,
    codes: &std::collections::HashMap<String, u32>,
    probe: &LevelProbe,
) -> bool {
    use xkbcommon::xkb;
    let dedicated = codes.get("LVL5").copied();
    for code in codes.values() {
        if Some(*code) == dedicated {
            continue;
        }
        let mut state = xkb::State::new(compiled);
        state.update_key(xkb::Keycode::from(code + 8), xkb::KeyDirection::Down);
        if state.serialize_mods(xkb::STATE_MODS_EFFECTIVE) & probe.level_five_real != 0 {
            return true;
        }
    }
    false
}

/// The whole `key <NAME> { … };` statement's byte range, its own lines included.
fn key_statement_bounds(keymap: &str, position: &str) -> Option<(usize, usize)> {
    let (lo, hi) = section_bounds(keymap, "xkb_symbols")?;
    let at = keymap[lo..hi].find(&format!("key <{position}>"))? + lo;
    let open = keymap[at..hi].find('{')? + at;
    let mut depth = 0usize;
    let mut close = None;
    for (offset, byte) in keymap[open..hi].bytes().enumerate() {
        match byte {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    close = Some(open + offset + 1);
                    break;
                }
            }
            _ => {}
        }
    }
    let mut end = close?;
    if keymap[end..].starts_with(';') {
        end += 1;
    }
    if keymap[end..].starts_with('\n') {
        end += 1;
    }
    let start = keymap[..at]
        .rfind('\n')
        .map(|newline| newline + 1)
        .unwrap_or(at);
    Some((start, end))
}

/// Adds the reserved symbol block to a compiled keymap.
///
/// Every group is spelled out rather than relying on xkb wrapping a
/// single-group key forward: the wrap would be right here only by accident,
/// and wrong the first time the catalogue differs per group.
///
/// A hosted position keeps every level it already had — `carried_levels` reads
/// them off the keymap's own behaviour and they are written back verbatim —
/// and the catalogue rides above them on levels five to eight. A position that
/// cannot host it is skipped and the catalogue is simply shorter, which is why
/// the head of `RESERVED_SYMBOLS` is the visible page and its tail is spare.
fn extend_with_reserved(keymap: &str) -> Option<String> {
    use xkbcommon::xkb;

    let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    let compiled = xkb::Keymap::new_from_string(
        &context,
        keymap.to_string(),
        xkb::KEYMAP_FORMAT_TEXT_V1,
        xkb::KEYMAP_COMPILE_NO_FLAGS,
    )?;
    let codes = parse_keycodes(keymap);
    let groups = compiled.num_layouts() as usize;
    let probe = LevelProbe::new(&compiled)?;

    // Which of the free positions this keymap actually leaves free, counted
    // BEFORE the ordinary ones are taken. `jp` defines both of them and `br`
    // defines `AB11`, so holding two slots back for them unconditionally
    // spent the catalogue's tail on positions that were never going to be
    // available — `jp` lost `× ≈ ÷ ≠` off the visible page with fourteen
    // hostable positions sitting unused.
    let free = free_positions(keymap);
    let available: Vec<&str> = CATALOGUE_FREE
        .into_iter()
        .filter(|position| free.iter().any(|name| name == position))
        .collect();

    // Levels one to four per group for a position the block extends; nothing
    // for a free position, which has none to keep.
    let mut slots: Vec<(&str, Option<Vec<[String; 4]>>)> = Vec::new();
    if !a_physical_key_carries_level_five(&compiled, &codes, &probe) {
        for position in CATALOGUE_ROW.iter().chain(CATALOGUE_SPARE.iter()) {
            if slots.len() == RESERVED_SYMBOLS.len() / 4 - available.len() {
                break;
            }
            let Some(code) = codes.get(*position) else {
                continue;
            };
            if let Some(kept) = carried_levels(&compiled, &probe, *code) {
                slots.push((position, Some(kept)));
            }
        }
    }
    for position in available {
        slots.push((position, None));
    }
    let usable = slots.len().min(RESERVED_SYMBOLS.len() / 4);
    if usable == 0 {
        return None;
    }
    let slots = &slots[..usable];

    let mut keys = String::new();
    for (index, (position, kept)) in slots.iter().enumerate() {
        let catalogue = &RESERVED_SYMBOLS[index * 4..index * 4 + 4];
        keys.push_str(&format!("\tkey <{position}> {{\n"));
        for group in 1..=groups {
            keys.push_str(&format!("\t\ttype[{group}]= \"OSK_RESERVED\",\n"));
        }
        for group in 1..=groups {
            let tail = if group < groups { "," } else { "" };
            let below = match kept {
                Some(per_group) => per_group[group - 1].join(", "),
                None => "NoSymbol, NoSymbol, NoSymbol, NoSymbol".to_string(),
            };
            keys.push_str(&format!(
                "\t\tsymbols[{group}]= [ {below}, {} ]{tail}\n",
                catalogue.join(", ")
            ));
        }
        keys.push_str("\t};\n");
    }

    // The hosted positions' old definitions, cut in one pass over ranges that
    // were all found in the original text, so no cut invalidates another.
    let mut cuts: Vec<(usize, usize)> = slots
        .iter()
        .filter(|(_, kept)| kept.is_some())
        .filter_map(|(position, _)| key_statement_bounds(keymap, position))
        .collect();
    cuts.sort();
    let mut trimmed = String::with_capacity(keymap.len());
    let mut at = 0usize;
    for (start, end) in cuts {
        trimmed.push_str(&keymap[at..start]);
        at = end;
    }
    trimmed.push_str(&keymap[at..]);

    // Types first, then symbols, so the second insertion point is still
    // valid — inserting the type shifts every offset after it.
    let (_, types_end) = section_bounds(&trimmed, "xkb_types")?;
    let (_, symbols_end) = section_bounds(&trimmed, "xkb_symbols")?;
    let mut out = String::with_capacity(trimmed.len() + RESERVED_TYPE.len() + keys.len());
    out.push_str(&trimmed[..types_end]);
    out.push_str(RESERVED_TYPE);
    out.push_str(&trimmed[types_end..symbols_end]);
    out.push_str(&keys);
    out.push_str(&trimmed[symbols_end..]);

    // The catalogue is only there if the chord that opens it works. A keymap
    // can declare `<LVL5>` and bind nothing to `ISO_Level5_Shift`, and then
    // the caps facts would advertise glyphs that type the position's own
    // level one instead — silent wrong characters, which is worse than the
    // layout minus some symbols this is allowed to fail to. Proved, not
    // assumed: the first slot's level five is asked of the built keymap.
    let built = xkb::Keymap::new_from_string(
        &context,
        out.clone(),
        xkb::KEYMAP_FORMAT_TEXT_V1,
        xkb::KEYMAP_COMPILE_NO_FLAGS,
    )?;
    let first = codes.get(slots[0].0)?;
    let wanted = xkb::keysym_from_name(RESERVED_SYMBOLS[0], xkb::KEYSYM_NO_FLAGS);
    if syms_with_mods(&built, 0, probe.level_five, *first) != vec![wanted] {
        eprintln!("<LVL5> does not open the reserved symbol block; keymap unchanged");
        return None;
    }
    Some(out)
}

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
///
/// The probe runs once per GROUP, not once per keymap: a position's modifier
/// meaning is a fact about the group it resolves in, and multi-group keymaps
/// disagree. Under `us,ua` without an `lv3:` option, RALT is Alt_R (Mod1) in
/// the us group and ISO_Level3_Shift (Mod5) in the ua group — a group-0 probe
/// made every AltGr chord report Alt at group ua, and the level-3 keysyms
/// came out as their level-1 selves. `Shared::modifier_mask` picks the entry
/// for the group the device is typing in.
fn modifier_masks_for_keymap(
    keymap: &str,
    codes: &std::collections::HashMap<String, u32>,
) -> std::collections::HashMap<u32, Vec<u32>> {
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
    let groups = compiled.num_layouts() as usize;

    let mut masks = std::collections::HashMap::new();
    for code in codes.values() {
        let mut per_group = Vec::with_capacity(groups);
        for group in 0..groups {
            // A fresh state per position rather than press-then-release: a key
            // carrying LockMods (Caps Lock) does not undo itself on release, and
            // would leave its bit set for every position probed after it. The
            // group rides in the locked-layout slot only: the three layout
            // arguments of update_mask are depressed+latched+locked and xkb
            // adds them, so repeating the group in all three asked for it
            // three times — right in a two-group keymap only because 3g wraps
            // back to g, and collapsed to group 0 at three. One ask, in the
            // locked slot, is exact for any layout count; it is also the slot
            // the compositor fills from the virtual-keyboard protocol.
            let mut state = xkb::State::new(&compiled);
            let group = group as u32;
            state.update_mask(0, 0, 0, 0, 0, group);
            state.update_key(xkb::Keycode::from(code + 8), xkb::KeyDirection::Down);
            per_group.push(state.serialize_mods(xkb::STATE_MODS_EFFECTIVE));
        }
        if per_group.iter().any(|&mask| mask != 0) {
            masks.insert(*code, per_group);
        }
    }
    masks
}

/// A key is named the way xkb names it (`AD01`) or given as a raw evdev code.
#[derive(Debug)]
enum Key {
    Code(u32),
    Name(String),
}

#[derive(Debug)]
enum Command {
    Tap(Key),
    Down(Key),
    Up(Key),
    Mods(u32),
    /// Selects which compiled layout this device types in.
    Group(u32),
    /// Atomically installs complete XKB state and selects its active group.
    Configure(XkbConfig),
    /// Keycap facts (decisions §23): the requested positions' per-level text
    /// in the named group of the installed keymap. No positions means every
    /// named key the keymap carries.
    Caps {
        group: u32,
        positions: Vec<String>,
    },
}

/// The two separator bytes of a `caps` reply. Both are outside everything a
/// keysym can resolve to — `xkb_keysym_to_utf8` never emits a C0 control other
/// than the handful (Tab, Return, Escape) that no layout puts on a keycap —
/// so the panel can split records and fields without an escape grammar.
const CAPS_RECORD_SEP: char = '\u{001e}';
const CAPS_FIELD_SEP: char = '\u{001f}';

/// Resolves every named key's levels to text through libxkbcommon, one
/// record string per GROUP of the keymap, so a group switch answers from
/// storage with no recompile and no upload. Built once per keymap install,
/// from the very text that was uploaded — the facts and the typing share one
/// compiled keymap authority (decisions §23), which is the whole point of
/// moving them off the panel's separate xkbcli pipeline.
///
/// Field grammar, one per level in level order: `t<text>` for a level whose
/// symbols resolve to character text (concatenated when a level carries
/// several symbols), `x<keysym>` for symbols that produce no character (a
/// dead key, a media key), `n` for no symbol at all. Control characters are
/// dropped from resolved text — they are not drawable, and a Linefeed keysym
/// must not inject a newline into a one-line protocol — with a level left
/// with nothing drawable reported as the textless kind it then is.
fn keycap_facts_for_groups(keymap: &str) -> Vec<String> {
    use xkbcommon::xkb;

    let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    let Some(compiled) = xkb::Keymap::new_from_string(
        &context,
        keymap.to_string(),
        xkb::KEYMAP_FORMAT_TEXT_V1,
        xkb::KEYMAP_COMPILE_NO_FLAGS,
    ) else {
        return Vec::new();
    };
    let groups = compiled.num_layouts();
    let mut per_group = vec![String::new(); groups as usize];

    // The span walk itself is safe ONLY behind the compile gates: a map
    // that reached here has max_keycode at most MAX_SANE_KEYCODE (4096 —
    // stock evdev tops at 709), so this loop is bounded small. The gates
    // refuse anything bigger precisely because this loop would not be
    // (round eleven's blocker — and a text-level named-keys walk was tried
    // and reverted: include-based keymaps carry no declarations to read).
    debug_assert!(compiled.max_keycode().raw() <= MAX_SANE_KEYCODE);
    for raw in compiled.min_keycode().raw()..=compiled.max_keycode().raw() {
        let code = xkb::Keycode::from(raw);
        let Some(name) = compiled.key_get_name(code) else {
            continue;
        };
        for group in 0..groups {
            let levels = compiled.num_levels_for_key(code, group);
            let mut record = String::from(name);
            for level in 0..levels {
                let syms = compiled.key_get_syms_by_level(code, group, level);
                record.push(CAPS_FIELD_SEP);
                if syms.is_empty() {
                    record.push('n');
                    continue;
                }
                let mut text = String::new();
                for sym in syms {
                    text.extend(xkb::keysym_to_utf8(*sym).chars().filter(|c| {
                        !c.is_control() && *c != CAPS_FIELD_SEP && *c != CAPS_RECORD_SEP
                    }));
                }
                if text.is_empty() {
                    record.push('x');
                    record.push_str(&xkb::keysym_get_name(syms[0]));
                } else {
                    record.push('t');
                    record.push_str(&text);
                }
            }
            if record.contains(CAPS_FIELD_SEP) {
                per_group[group as usize].push_str(&record);
                per_group[group as usize].push(CAPS_RECORD_SEP);
            }
        }
    }
    per_group
}

/// Builds one `caps` reply line: the generation the facts were computed from,
/// the group they describe, and the requested positions' records in the order
/// they were asked. A position the keymap does not carry answers as a bare
/// record with no level fields — the panel's "no keymap entry", distinct from
/// a carried key whose level is empty (spec-v1.1 §3's honest hole). `None`
/// says the group is past the keymap's own count, which no panel should ask
/// for: xkb would silently wrap it to another group's facts.
fn caps_reply(gen: u64, per_group: &[String], group: u32, positions: &[String]) -> Option<String> {
    let records = per_group.get(group as usize)?;
    // The header fields are tabs, like every other protocol reply's; the
    // 0x1F fields begin inside the record section, where level text lives.
    let mut reply = format!("caps\t{gen}\t{group}\t");
    if positions.is_empty() {
        reply.push_str(records.trim_end_matches(CAPS_RECORD_SEP));
        return Some(reply);
    }
    for wanted in positions {
        let found = records
            .split(CAPS_RECORD_SEP)
            .find(|record| record.split(CAPS_FIELD_SEP).next() == Some(wanted.as_str()))
            .filter(|record| !record.is_empty());
        match found {
            Some(record) => reply.push_str(record),
            None => reply.push_str(wanted),
        }
        reply.push(CAPS_RECORD_SEP);
    }
    reply.pop();
    Some(reply)
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
    /// The bytes behind the installed `kb_file`, if it came from one. `None`
    /// for an RMLVO keymap, where the configure's own fields are the identity.
    kb_file_mark: Option<u64>,
    /// Set before shutdown releases the device. Socket threads may still have
    /// buffered commands, but none may mutate the keyboard after this point.
    shutting_down: bool,
    /// A virtual keyboard drops key events until it has been given a keymap.
    ready: bool,
    /// xkb key name -> evdev code, taken from the keymap in use.
    codes: std::collections::HashMap<String, u32>,
    /// evdev code -> modifier bit per group, for the codes the keymap calls
    /// modifiers. A position may carry different bits in different groups —
    /// RALT is Alt_R in us and ISO_Level3_Shift in ua — so the active group
    /// picks the entry (see `modifier_mask`).
    modifier_masks: std::collections::HashMap<u32, Vec<u32>>,
    /// The generation stamped on every keycap-facts reply: the number of
    /// keymap installs this process has performed. A same-keymap reconfigure
    /// keeps it (the installed keymap did not change), a changed one bumps it.
    caps_gen: u64,
    /// Pre-resolved keycap-facts records, one string per group of the
    /// installed keymap (see `keycap_facts_for_groups`). Rebuilt exactly when
    /// `caps_gen` is bumped, so a `caps` request compiles nothing.
    caps_per_group: Vec<String>,
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
    /// a code some connection currently holds, read at the group the device is
    /// typing in — the same position can mean different modifiers per group.
    /// Derived from `held` rather than accumulated, so it cannot drift out of
    /// step with what is pressed.
    fn modifier_mask(&self) -> u32 {
        self.held
            .keys()
            .filter_map(|code| match self.modifier_masks.get(code) {
                // A group beyond the keymap's own count wraps in xkb; the
                // first group's bit is the honest answer for it.
                Some(per_group) => per_group
                    .get(self.group as usize)
                    .or_else(|| per_group.first())
                    .copied(),
                None => None,
            })
            .fold(0, |mask, bit| mask | bit)
    }

    /// Compiles `layouts` and installs the result. Held by the caller's lock so
    /// a keystroke can never observe a half-swapped keymap.
    fn install_config(
        &mut self,
        config: &XkbConfig,
        kb_file_bytes: Option<&[u8]>,
        precompiled: Option<&str>,
    ) -> bool {
        // Same fields AND, for a kb_file, the same bytes behind them. The
        // bytes arrive from the caller — ONE read validates the group
        // ceiling and installs the map (the review's fourth round: the
        // count and the install each reading the path left a swap between
        // them validating one file and installing another); the `group`
        // command reaches none of this and still moves a group without
        // touching the file (ticket 06). `precompiled` is the SAME text
        // the caller's ceiling counted (round 18: one compile serves
        // both) — None means compile here, the way the default install
        // always did.
        let file_bytes = kb_file_bytes.map(|bytes| bytes.to_vec());
        let mark = file_bytes.as_deref().map(hash_bytes);
        if self
            .config
            .as_ref()
            .is_some_and(|current| current.same_keymap(config))
            && mark == self.kb_file_mark
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
                // Logged because the failure this catches is invisible from
                // both ends: the panel believes it asked, the compositor
                // believes it was told, and the user is the only one who
                // finds out — by typing the previous alphabet.
                eprintln!("group -> {}", self.group);
            }
            self.config = Some(config.clone());
            return true;
        }
        // The churn budget is paid by apply's configure gate, before any
        // compile attempt — counting it here again would double-bill every
        // changed configure.
        let text = match precompiled {
            Some(text) => text.to_string(),
            None => match compile_keymap_with(config, file_bytes.as_deref()) {
                Some(text) => text,
                None => {
                    eprintln!("cannot compile requested XKB configuration");
                    return false;
                }
            },
        };
        let Some(keyboard) = self.keyboard.as_ref() else {
            return false;
        };
        if self.ready {
            for (code, _) in self.held.drain() {
                keyboard.key(stamp(), code, 0);
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
        self.kb_file_mark = mark;
        self.codes = parse_keycodes(&text);
        self.modifier_masks = modifier_masks_for_keymap(&text, &self.codes);
        // The keycap facts are the same install's answer about itself: built
        // from the exact text that was just uploaded, so the panel's caps and
        // the compositor's typing can never disagree about the keymap.
        self.caps_gen += 1;
        self.caps_per_group = keycap_facts_for_groups(&text);
        // Published after the upload, never before: the file is an offer to
        // the compositor to share this exact keymap, and offering one that
        // was not installed would invite the divergence it exists to end.
        publish_keymap(&text);
        self.ready = !self.codes.is_empty();
        self.config = Some(config.clone());
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
        shared.install_config(&XkbConfig::default(), None, None);
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

/// Where the helper publishes the keymap it installed, for the compositor to
/// compile the very same one (decisions §35).
///
/// Two keymaps on a seat is not a cosmetic difference. The compositor hands a
/// focused client whichever keyboard is active, so with the block making ours
/// differ, a client was handed one keymap and then the other on every focus
/// change — and every swap resets the group it resolves keys in. Measured on
/// the owner's machine: six focus changes, nine keymap events, two distinct
/// keymaps; with the block off, one. Applications that do not re-read the
/// group after a keymap swap then type the previous alphabet until any
/// modifier key arrives, which is exactly what Telegram, WhatsApp and Viber
/// did while Discord and the browser were fine.
///
/// Under `$XDG_RUNTIME_DIR` beside the socket: the unit sets `PrivateTmp` so
/// `/tmp` is the helper's own, and `ProtectHome=read-only` rules out `$HOME`.
/// It also means the file dies with the session, which is what keeps a stale
/// `kb_file` from outliving the panel that pointed at it.
fn published_keymap_path() -> Option<PathBuf> {
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
/// Whether a group index can be carried by the installed keymap. The
/// caps facts are per-group, so their count IS the group count; nothing
/// installed validates nothing (ticket 31: the daemon is the defence in
/// depth — the panel bounds its remembered group at the selection seam,
/// and an out-of-range `group` command from ANY client is refused here
/// without touching device state).
fn group_in_range(group: u32, installed_groups: usize) -> bool {
    installed_groups > 0 && (group as usize) < installed_groups
}

/// The group count a configure DECLARES for itself: the non-empty
/// entries of its layouts field. A configure's group is bounded by the
/// map it is INSTALLING, not the one already installed — bounding by the
/// old map refuses every grow (a one-group map installing two), which is
/// a client acting correctly. Zero declared layouts still carries group
/// 0: a file-only configure owes no layout list.
fn is_published_keymap(path: &str) -> bool {
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

/// Ticket 06: the recovery record's file name, beside the published keymap
/// in the runtime directory this helper owns — the one place
/// `ProtectSystem=strict` leaves writable. The unit preserves that
/// directory across service stops (`RuntimeDirectoryPreserve=yes`) because
/// the record must survive helper restarts within the graphical session —
/// `oskar upgrade` restarts the helper as a routine step — while
/// systemd still removes it when the session ends, which is exactly the
/// record's intended lifetime. The helper survives a shell crash; the
/// panel does not, and the panel's in-memory `userKeymapFile` was the only
/// record — a SIGKILLed shell left the compositor still compiling the
/// published keymap with the source lost, and the custom keymap silently
/// dropped for the session.
const SOURCE_SIDECAR: &str = "user-keymap-source";

/// What a configure's `kb_file` says about the user's own keymap source.
#[derive(Debug, PartialEq)]
enum SourceDecision {
    /// The user's own file: remember it verbatim for shell-crash recovery.
    Remember(String),
    /// No custom source: the recovery record must not outlive the setting.
    Clear,
    /// Our own published path: ambiguous input, refused as an input
    /// elsewhere; keep whatever is recorded rather than destroy it.
    Leave,
}

fn user_source_decision(kb_file: &str) -> SourceDecision {
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
fn persist_user_source(dir: &Path, source: Option<&str>) -> std::io::Result<()> {
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
fn publish_keymap(text: &str) {
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

fn socket_path() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let dir = std::env::var("XDG_RUNTIME_DIR")
        .map_err(|_| "XDG_RUNTIME_DIR is unset; this must run inside a user session")?;
    let dir = PathBuf::from(dir).join("oskar");
    std::fs::create_dir_all(&dir)?;
    let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    // The daemon's own guarantee, not systemd's (the audit's 1.5/7.1):
    // the directory must belong to THIS uid and carry no group/other
    // bits — a pre-created group-writable directory (or one another
    // user planted before our first start, binding their own socket
    // for the panel to talk to) is refused loudly instead of trusted.
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

fn startup_keyboard_reply() -> String {
    let names = physical_keyboard_names(Path::new("/sys/class/input"), Path::new("/run/udev/data"));
    if names.is_empty() {
        "keyboards".to_string()
    } else {
        format!("keyboards\t{}", names.join("\t"))
    }
}

/// The hello handshake's exact grammar (F6): precisely `hello <u32>`.
/// `Some(Ok(v))` is a well-formed version request, `Some(Err(()))` is a
/// hello-shaped line that is not (bare, trailing words, non-numeric
/// version — the old parser defaulted all three to the current version),
/// and `None` is not a hello line at all, belonging to the verb parser.
fn parse_hello(line: &str) -> Option<Result<u32, ()>> {
    let mut words = line.split_whitespace();
    if words.next()? != "hello" {
        return None;
    }
    match (words.next(), words.next()) {
        (Some(version), None) => Some(version.parse::<u32>().map_err(|_| ())),
        _ => Some(Err(())),
    }
}

fn parse(line: &str) -> Option<Command> {
    if let Some(raw) = line.strip_prefix("configure\t") {
        let fields: Vec<&str> = raw.split('\t').collect();
        if fields.len() != 7 {
            return None;
        }
        // An interior NUL in a field is refused at the door: xkbcommon's
        // CString conversion panics on it, and that panic fires under the
        // shared lock (see xkb_field_clean). Malformed input is not a
        // configure at all.
        if fields[..6].iter().any(|field| field.contains('\0')) {
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
    // `caps` has variable arity (the position list is optional), so it is
    // peeled off before the fixed-shape verb match. A bare "caps" — no group
    // — is not a caps command at all.
    if let Some(rest) = line.strip_prefix("caps ") {
        let mut parts = rest.split_whitespace();
        let group = parts.next()?.parse::<u32>().ok()?;
        return Some(Command::Caps {
            group,
            positions: parts.map(str::to_string).collect(),
        });
    }
    let mut parts = line.split_whitespace();
    let verb = parts.next()?;
    let raw = parts.next()?;
    // Fixed-arity verbs take exactly one argument (F6): a third word is a
    // malformed line, not a silently truncated one. The variable-arity
    // verb (`caps`) and the tab-separated `configure` are peeled off
    // above with their own rules.
    if parts.next().is_some() {
        return None;
    }
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
            // Refuse LOUDLY (the audit: the silent drop kept the panel
            // believing the helper healthy while it could not get in).
            // The message names the condition; SocketWatch's rebuild
            // path reads any error the same way it always did.
            let _ = writeln!(&mut { stream }, "err too many clients");
            continue;
        }
        let shared = Arc::clone(&shared);
        let connection = connection.clone();
        let spawned = {
            let clients = Arc::clone(&clients);
            thread::Builder::new()
                .name("osk-client".into())
                .spawn(move || {
                    handle_client(stream, shared, connection);
                    clients.fetch_sub(1, Ordering::AcqRel);
                })
                .is_err()
        };
        if spawned {
            // The client is dropped, never the helper (round eleven's
            // finding 10): exit(70) skipped every release path a live
            // connection's keys still depended on — and the slot the
            // failed spawn never returned is four failures from a
            // permanent lockout (round twelve's finding 5).
            eprintln!("cannot spawn socket client worker; dropping the client");
            clients.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

/// The pre-handshake window and the write bound are both ABSOLUTE: neither
/// a client that streams frames without pausing nor one that stops reading
/// may extend them (2026-09-19 audit, finding 4).
const HANDSHAKE_WINDOW: Duration = Duration::from_secs(5);
const WRITE_BOUND: Duration = Duration::from_secs(5);

/// Whether a connection that never completed its `hello` has worn the
/// pre-handshake window out. Evaluated per iteration, not only when a read
/// times out — continuous traffic must not extend the window.
fn handshake_expired(handshaked: bool, connected_for: Duration) -> bool {
    !handshaked && connected_for >= HANDSHAKE_WINDOW
}

/// One bounded reply. `bound` is the caller's REMAINING time (the review's
/// second round): while the handshake window is open, a write may not
/// outlive it — a parked write would let a late hello complete long past
/// the window. `false` means the bound is spent or the client is not
/// draining its pipe; the connection is dropped either way.
fn write_reply(out: &mut UnixStream, text: &str, bound: Duration) -> bool {
    if bound.is_zero() {
        return false;
    }
    if out.set_write_timeout(Some(bound)).is_err() {
        return false;
    }
    match writeln!(out, "{text}") {
        Ok(()) => true,
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            false
        }
        // EPIPE and friends: the read side notices the disconnect on its
        // own; an idle writer gains nothing by tearing the loop down here.
        Err(_) => true,
    }
}

/// The bound on the NEXT reply write: never more than `WRITE_BOUND`, and
/// while the handshake window is open, never past its end.
fn reply_bound(handshaked: bool, connected_for: Duration) -> Duration {
    if handshaked {
        WRITE_BOUND
    } else {
        HANDSHAKE_WINDOW
            .saturating_sub(connected_for)
            .min(WRITE_BOUND)
    }
}

fn handle_client(stream: UnixStream, shared: SharedRef, connection: Connection) {
    let Ok(mut out) = stream.try_clone() else {
        return;
    };
    // A client that stops reading while its pipe is full would park a
    // reply forever: every write on this connection is bounded, and one
    // that times out drops the connection — its read side would only ever
    // notice at an EOF that client never sends.
    if out.set_write_timeout(Some(WRITE_BOUND)).is_err() {
        return;
    }
    // Keys this connection pressed and has not released. If the shell restarts
    // mid-chord the compositor would otherwise keep Ctrl logically down for the
    // rest of the session, which looks like a broken machine rather than a
    // broken plugin.
    let mut held: Vec<u32> = Vec::new();
    static CONNECTION: AtomicU64 = AtomicU64::new(1);
    let conn_id = CONNECTION.fetch_add(1, Ordering::Relaxed);

    let mut reader = BufReader::with_capacity(8 * 1024, match stream.try_clone() {
        Ok(handle) => handle,
        Err(_) => return,
    });
    // Bytes of the line in flight. A raw byte buffer, not a String: the
    // manual chunk loop below enforces the frame cap per read (the
    // cross-round's finding — read_line accumulates without bound
    // inside ONE call while an active sender streams newline-free
    // bytes, so every post-hoc length check arrived too late).
    let mut pending: Vec<u8> = Vec::new();
    let mut handshaked = false;
    let connected_at = Instant::now();
    // Round 17: an idle NEGOTIATED client also owes traffic. Before
    // this, only the pre-handshake window was absolute — a client that
    // hello'd and never spoke again parked one of the four slots for
    // the process lifetime, and three hung probe clients would lock
    // the real panel out with `err too many clients` until a restart.
    // 60 s of post-handshake silence drops the connection through the
    // ordinary release path; the real panel survives by construction —
    // §80's never-stopping probe speaks every 15 s, healthy or not,
    // and a held key already arms its own tighter deadline.
    let mut last_activity = Instant::now();
    const NEGOTIATED_IDLE: Duration = Duration::from_secs(60);
    loop {
        // The only thing this connection ever waits on is its own next line.
        // Arming that wait with the cap's deadline is what enforces the cap
        // without a timer thread: no hold means no deadline and the read
        // blocks the way it always did, and a hold means exactly one wakeup,
        // at the moment the key is due to be lifted.
        // The pre-handshake window (the audit's slot-starvation
        // finding): four idle connections that never send a byte used
        // to hold every slot forever — the socket stayed alive, the
        // panel's probes reported the helper healthy, and the real
        // client could not get in. Until this connection has completed
        // a `hello`, its read deadline is 5 s out; a hold's deadline
        // still wins when it is sooner.
        // The pre-handshake window is ABSOLUTE (the cross-round: a
        // renewed timeout evicted nobody — an idle connection woke
        // every 5 s and held its slot forever). 5 s from CONNECT to a
        // completed `hello`, then the window is gone. A hold's deadline
        // still wins when it is sooner; post-handshake with no holds
        // the read blocks the way it always did.
        let handshake = if handshaked {
            None
        } else {
            Some(
                connected_at
                    .checked_add(Duration::from_secs(5))
                    .map(|deadline| {
                        deadline
                            .saturating_duration_since(Instant::now())
                            .max(Duration::from_millis(1))
                    })
                    .unwrap_or(Duration::from_millis(1)),
            )
        };
        let hold = hold_deadline(&shared, conn_id).map(|deadline| {
            deadline
                .saturating_duration_since(Instant::now())
                .max(Duration::from_millis(1))
        });
        let idle = if handshaked && hold.is_none() {
            Some(
                last_activity
                    .checked_add(NEGOTIATED_IDLE)
                    .map(|deadline| {
                        deadline
                            .saturating_duration_since(Instant::now())
                            .max(Duration::from_millis(1))
                    })
                    .unwrap_or(Duration::from_millis(1)),
            )
        } else {
            None
        };
        let timeout = [handshake, hold, idle].into_iter().flatten().min();
        if stream.set_read_timeout(timeout).is_err() {
            break;
        }
        // Deadline enforcement must not depend on the traffic going quiet
        // (2026-09-19 audit): a client that streams frames keeps the read
        // succeeding forever, and checks that lived only in the timeout arm
        // never ran. Both deadlines are evaluated here too, every turn,
        // whether or not bytes arrived.
        if handshake_expired(handshaked, connected_at.elapsed()) {
            break;
        }
        if hold_deadline(&shared, conn_id).is_some_and(|deadline| deadline <= Instant::now()) {
            for code in expire_stuck_keys(&shared, &connection) {
                held.retain(|entry| *entry != code);
            }
        }
        // The idle window is traffic-gated like the others (a client
        // streaming frames keeps the reads succeeding; only silence
        // closes it).
        if handshaked
            && hold_deadline(&shared, conn_id).is_none()
            && last_activity.elapsed() >= NEGOTIATED_IDLE
        {
            break;
        }
        // The frame cap, enforced per CHUNK (the cross-round's core
        // finding: the audits' HIGH realization of known item 7 — an
        // active newline-free stream grew `pending` without bound inside
        // a single read_line call, and MemoryMax plus StartLimitBurst
        // turned that into a permanent lockout a keyboard user cannot
        // type their way out of). 4 KiB is generous (the longest live
        // line — a configure naming a kb_file path plus its layouts —
        // is a few hundred bytes); one chunk is one buffer
        // fill, so `pending` is bounded by cap + 8 KiB whatever the
        // sender's pace. Overflow answers once and closes.
        const MAX_LINE: usize = 4096;
        let mut chunk = [0u8; 8192];
        let read = match reader.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => n,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                // The deadline came due. Pre-handshake past the window:
                // this connection never said hello — drop it, freeing
                // the slot (the audits' starvation finding). Post-
                // handshake with no hold due, it is the negotiated-idle
                // window closing — same cure, same release path.
                // Otherwise this is the hold cap's wakeup: lift what is
                // due and keep waiting for the rest of the line.
                if handshake_expired(handshaked, connected_at.elapsed()) {
                    break;
                }
                // Round 18's audit: the arm used to break on
                // handshaked-and-holdless ALONE, but the read deadline
                // was computed BEFORE the loop-top hold expiry — a
                // claim that expired between the two (its key hit the
                // 15 s cap, or another client's install drained it)
                // leaves a stale past-due timeout that wakes this read
                // instantly, and a connection whose last traffic was
                // milliseconds ago would be dropped for "idleness" it
                // does not have. Only the real window closes it.
                if handshaked
                    && hold_deadline(&shared, conn_id).is_none()
                    && last_activity.elapsed() >= NEGOTIATED_IDLE
                {
                    break;
                }
                for code in expire_stuck_keys(&shared, &connection) {
                    held.retain(|entry| *entry != code);
                }
                continue;
            }
            Err(_) => break,
        };
        last_activity = Instant::now();
        pending.extend_from_slice(&chunk[..read]);
        // Dispatch every COMPLETE line the buffer now holds; the tail
        // without its newline stays for the next chunk.
        let mut poisoned = false;
        let mut write_dead = false;
        while let Some(nl) = pending.iter().position(|byte| *byte == b'\n') {
            // A COMPLETE line is capped here, before it is parsed (the
            // review's fourth round: moving the cap after dispatch let a
            // 5 000-byte line with its newline through untouched). Breaking
            // without draining leaves the oversized bytes in `pending` for
            // the tail check below, which answers and closes.
            if nl + 1 > MAX_LINE {
                break;
            }
            // Deadlines between commands, not only between reads (the
            // review's second round): one chunk can carry a whole burst,
            // paced slow enough to cross the window, and its late hello
            // must not complete. Breaking here drops the rest of the
            // buffer; the loop-top check finishes dropping the connection.
            if handshake_expired(handshaked, connected_at.elapsed()) {
                break;
            }
            if hold_deadline(&shared, conn_id).is_some_and(|deadline| deadline <= Instant::now()) {
                for code in expire_stuck_keys(&shared, &connection) {
                    held.retain(|entry| *entry != code);
                }
            }
            let mut line_bytes = pending.drain(..=nl).collect::<Vec<u8>>();
            line_bytes.pop(); // the newline itself
            let Ok(line_str) = String::from_utf8(line_bytes) else {
                // Invalid UTF-8 disconnects rather than guesses — but
                // THROUGH the release path (the final review's stray-bug
                // finding: a bare `return` here jumped release_all and
                // stranded every key this client held, locked modifiers
                // included, until a daemon restart).
                poisoned = true;
                break;
            };
            let line = line_str.trim();
            if line.is_empty() {
                // Even this answers one line (round eleven's finding 7):
                // the reply-per-command invariant has no silent case, and
                // the correlation queue on the other end pops on it.
                if !write_reply(&mut out, "err empty",
                    reply_bound(handshaked, connected_at.elapsed()))
                {
                    write_dead = true;
                    break;
                }
                continue;
            }
            // `hello` reports more than "the process is up": a keyboard without a
            // keymap accepts commands and drops every key, so the client must not
            // enable keys until one is loaded. `ping` stays a plain liveness check.
            // The grammar is exactly `hello <u32>` (F6): the handshake is a
            // version gate, not a default, so an old or broken client fails
            // closed instead of negotiating the current version by omission.
            if let Some(hello) = parse_hello(line) {
                let reply = match hello {
                    Ok(wanted) if wanted == PROTOCOL_VERSION => {
                        if shared.lock().unwrap().is_ready() {
                            format!("hello {PROTOCOL_VERSION}")
                        } else {
                            "err not ready".to_string()
                        }
                    }
                    _ => {
                        format!("err protocol {PROTOCOL_VERSION} required, helper needs reinstall")
                    }
                };
                if !write_reply(&mut out, &reply,
                    reply_bound(handshaked, connected_at.elapsed()))
                {
                    write_dead = true;
                    break;
                }
                // Set, never cleared (round eleven's finding 8): a
                // post-handshake wrong-version hello is a protocol
                // confusion, not a de-negotiation.
                handshaked |= matches!(hello, Ok(wanted) if wanted == PROTOCOL_VERSION);
                continue;
            }
            // Protocol negotiation is a gate, not a suggestion (round
            // seven): until this connection has completed a `hello` the
            // version it speaks for is unknown, and nothing — not ping,
            // not keyboards, and above all not a command that moves keys
            // or keymaps — executes. A client that never negotiates gets
            // its slot's five seconds and one refusal per line.
            if !handshaked {
                if !write_reply(&mut out, "err hello first",
                    reply_bound(handshaked, connected_at.elapsed()))
                {
                    write_dead = true;
                    break;
                }
                continue;
            }
            if line == "ping" {
                if !write_reply(&mut out, "pong",
                    reply_bound(handshaked, connected_at.elapsed()))
                {
                    write_dead = true;
                    break;
                }
                continue;
            }
            if line == "keyboards" {
                if !write_reply(&mut out, &startup_keyboard_reply(),
                    reply_bound(handshaked, connected_at.elapsed()))
                {
                    write_dead = true;
                    break;
                }
                continue;
            }
            let reply = match parse(line) {
                Some(command) => apply(&shared, &connection, command, Some(&mut held), conn_id),
                None => "err unknown command".to_string(),
            };
            if !write_reply(&mut out, &reply,
                reply_bound(handshaked, connected_at.elapsed()))
            {
                write_dead = true;
                break;
            }
        }
        if poisoned || write_dead {
            break;
        }
        // The frame cap is per LINE, not per batch (the review's third
        // round): coalesced complete commands share this chunk legally, so
        // the cap is measured on what REMAINS — the tail without its
        // newline, which is the one line still growing. A newline-free
        // stream still trips it exactly as before.
        if pending.len() > MAX_LINE {
            let _ = writeln!(out, "err line too long");
            break;
        }
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
    let mut released_any = false;
    for code in held {
        let before = shared.held.contains_key(&code);
        apply_locked(
            &mut shared,
            connection,
            Command::Up(Key::Code(code)),
            None,
            conn_id,
        );
        released_any |= before;
    }
    // The mask is zeroed only when THIS connection's departure actually
    // lifted something (round eleven's finding 6): a manual `mods <mask>`
    // carries no claim, and a connection that held nothing used to wipe a
    // survivor's mask on its way out.
    if released_any && shared.held.is_empty() {
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

/// Lifts every code the device is holding, zeroes the modifier mask and
/// flushes, so nothing is left pressed when this process stops.
///
/// Every other way of losing a hold is already covered — a departing client
/// runs `release_all`, a wedged one is caught by the cap in
/// `expire_stuck_keys`, a keymap-changing configure drains in
/// `install_config` — and all three run on a thread that dies with the
/// process. A SIGTERM landing mid-press therefore destroyed the virtual
/// keyboard with the key still down, and Hyprland does not lift a destroyed
/// keyboard's presses: the key repeated for the rest of the session, and a
/// restarted helper could not clear it because its keyboard is a new object.
///
/// Unconditional rather than per-claim, like the cap: the device holds a key
/// once, so lifting it means dropping every claim on it. Modifiers are NOT
/// exempt here — the cap exempts them because a locked Shift is meant to stay
/// down, and that reason ends with the process.
///
/// Returns the codes it lifted, so the caller can say what happened rather
/// than claim a release that had nothing to release.
fn release_everything(shared_arc: &SharedRef, connection: &Connection) -> Vec<u32> {
    // Close the command gate under the lock used by every command. From
    // this instant a client thread can only receive `err shutting down`;
    // a command already under the lock completes or is refused, and
    // nothing new starts while the release round-trips — the gate closes
    // first precisely so the release is the last writer.
    {
        let mut shared = shared_arc.lock().unwrap();
        shared.shutting_down = true;
    }
    let mut shared = shared_arc.lock().unwrap();
    let Some(keyboard) = shared.keyboard.clone() else {
        return Vec::new();
    };
    let held: Vec<u32> = shared.held.keys().copied().collect();
    for code in &held {
        shared.held.remove(code);
        keyboard.key(stamp(), *code, 0);
    }
    keyboard.modifiers(0, 0, 0, shared.group);
    // The lock is dropped before the round trip: it blocks on the compositor,
    // and holding `shared` across that would stall any client thread still
    // serving a line.
    drop(shared);
    // A round trip, not a flush. `flush` only writes the bytes; the process
    // then exits and closes the connection, and a compositor that reaches the
    // disconnect with the release still unread destroys the virtual keyboard
    // holding the key — which is the defect, unchanged. Measured in the VM:
    // with `flush` alone, a stop triggered by the very Enter still held left
    // the key repeating (50 -> 131 -> 211 bytes captured after the helper had
    // gone). The sync callback is the proof that the compositor processed the
    // release before this process leaves.
    let _ = connection.roundtrip();
    held
}

fn apply(
    shared: &SharedRef,
    connection: &Connection,
    command: Command,
    held: Option<&mut Vec<u32>>,
    conn_id: u64,
) -> String {
    // Every command runs under the lock (the typed deliveries that once
    // paced lock-free between beats are gone with §91); the lock is held
    // only for bounded work — compiles pay the churn budget at the gate.
    let mut guard = shared.lock().unwrap();
    apply_locked(&mut guard, connection, command, held, conn_id)
}

fn apply_locked(
    shared: &mut Shared,
    connection: &Connection,
    command: Command,
    held: Option<&mut Vec<u32>>,
    conn_id: u64,
) -> String {
    if shared.shutting_down {
        return "err shutting down".to_string();
    }
    if let Command::Configure(ref config) = command {
        // Ticket 06: record the user's own `kb_file` source BEFORE
        // anything else happens to it. Recorded from what the panel sends
        // — the intent — and not from whether this compile succeeds: even
        // a refused configure is evidence of what the user had configured,
        // and the recovery read happens on a shell that no longer has the
        // value anywhere else.
        if let Some(published) = published_keymap_path() {
            let dir = published
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(|| Path::new(".").to_path_buf());
            let outcome = match user_source_decision(&config.kb_file) {
                SourceDecision::Remember(path) => persist_user_source(&dir, Some(&path)),
                SourceDecision::Clear => persist_user_source(&dir, None),
                SourceDecision::Leave => Ok(()),
            };
            if let Err(error) = outcome {
                eprintln!("[oskar] could not record the user keymap source: {error}");
            }
        }
        // Ticket 31's defence in depth: a group the configure's OWN map
        // cannot carry is refused whole, with no device state changed —
        // the same refusal `caps` already made, extended to the two
        // commands that MOVE the group. Bounded by the INCOMING map, never
        // the installed one: a shrink-then-grow would otherwise refuse a
        // correct grow. For RMLVO the layouts string IS the map (same count
        // once compiled); a custom keymap's groups are the FILE's — asked
        // of the ONE bounded snapshot that will also be installed, so the
        // ceiling and the map cannot describe two different files.
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
        // An unchanged keymap skips the ceiling compile entirely (round
        // eleven's finding 4): identical reconfigures — group flips — used
        // to pay a full file compile under the lock each, at no rate cap.
        // The installed map's own group count is the ceiling that fits it.
        let mark = kb_file_bytes.as_deref().map(hash_bytes);
        let unchanged = shared.config.as_ref().is_some_and(|c| c.same_keymap(config))
            && shared.kb_file_mark == mark;
        if !unchanged {
            // Compile ATTEMPTS pay the churn budget here, before any work
            // (round eleven's finding 4): a file engineered to fail late
            // in parse used to burn the full compile cost at no cap, and
            // only successful installs were ever counted. install_config's
            // own accounting is retired in favour of this one gate.
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
        // ONE compile serves the whole changed path (round 18's audit):
        // the ceiling counts it, the install uploads it. The gate used
        // to compile for its count and throw the result away — four xkb
        // passes per changed configure under the lock where two
        // sufficed before §82 — and the two compiles were the only
        // channel for a gate-counts-one-map, install-uploads-another
        // TOCTOU (the system xkb database changing between them). One
        // text now decides both, so the ceiling IS the installed map's
        // count by construction.
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
        let installed = shared.install_config(config, kb_file_bytes.as_deref(), compiled.as_deref());
        let _ = connection.flush();
        // The generation rides on the reply (decisions §23): it is what the
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
        Command::Mods(mask) => keyboard.modifiers(mask, 0, 0, shared.group),
        // A language switch mid-chord must not drop what is held, so the
        // group goes out alongside the mask the held keys imply rather than
        // alongside a zero.
        Command::Group(group) => {
            if !group_in_range(group, shared.caps_per_group.len()) {
                return "err bad group".to_string();
            }
            let keyboard = keyboard.clone();
            shared.group = group;
            keyboard.modifiers(shared.modifier_mask(), 0, 0, group);
        }
        // Facts, not keys: nothing is pressed, nothing is held, and the
        // answer is read out of the installed keymap's pre-resolved records.
        // The group is validated rather than wrapped — xkb would silently
        // answer another group's facts for a past-the-count group, and the
        // panel must never be handed a lie (decisions §23).
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
    // only ever pressed and released arrives modifierless: `down LFSH / tap
    // AD01 / up LFSH` typed `q`, which is how this shipped broken. Re-assert
    // the mask whenever a modifier code goes down or comes up, and the tap in
    // between lands under it.
    if let Some(code) = pressed.or(released) {
        if shared.modifier_masks.contains_key(&code) {
            keyboard.modifiers(shared.modifier_mask(), 0, 0, shared.group);
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

    // The shutdown wait. It does the release with ordinary Wayland writes on
    // a thread of its own — the socket threads already write to this same
    // connection, so this is the shape the file already has, and it is the
    // only sound one: a signal handler may not touch a mutex or a Wayland
    // queue.
    // Blocked HERE, not at the top of main: everything above this point is
    // startup, holds no key, and has nothing to release — so the default
    // disposition is the right answer for a signal arriving during it, and
    // blocking that early only made the process ignore SIGTERM for the whole
    // of a connect, eight roundtrips and a bind. A startup that hangs would
    // then have sat out systemd's stop timeout waiting for SIGKILL.
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

    let socket_shared = Arc::clone(&shared);
    let socket_connection = connection.clone();
    thread::spawn(move || serve(listener, socket_shared, socket_connection));
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
        // A RUNTIME failure (a dispatch error with the session standing):
        // exit 1 keeps Restart=always — a stopped-here 78 would leave the
        // keyboard dead until a manual restart (review finding).
        eprintln!("oskar-daemon: runtime failure: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Layout and option sets the block has to survive. The options are the
    /// point: the first version of this probe held down `<CAPS>` to ask about
    /// Lock, and under `grp:caps_toggle` — the owner's own option, and the
    /// VM's, and every integration configure's — that switches the group and
    /// refused the whole digit row. Option-free fixtures cannot see it.
    const BLOCK_FIXTURES: [(&str, &str); 10] = [
        ("us", ""),
        ("us,ua", ""),
        ("us,ua", "grp:caps_toggle"),
        ("us,ua", "compose:caps,grp:alt_shift_toggle"),
        ("us,ua", "shift:both_capslock_cancel,grp:caps_toggle"),
        ("ua,ru", "grp:caps_toggle"),
        ("de,fr", "lv3:alt_switch"),
        ("us,it,ua,ru", "grp:alt_shift_toggle"),
        // `jp` defines both free positions and `br` defines `AB11`, which is
        // the case the allocator used to hold slots back for and then never
        // fill. Without these two the guard below cannot see it.
        ("jp", ""),
        ("br", ""),
    ];

    fn fixture_keymap(layouts: &str, options: &str) -> String {
        use xkbcommon::xkb;
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        xkb::Keymap::new_from_names(
            &context,
            "evdev",
            "pc105",
            layouts,
            "",
            (!options.is_empty()).then(|| options.to_string()),
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .expect("fixture keymap")
        .get_as_string(xkb::KEYMAP_FORMAT_TEXT_V1)
    }

    /// The positions the block ACTUALLY landed on, read back out of the
    /// extended keymap rather than recomputed.
    ///
    /// A helper that re-ran the allocation would agree with itself whatever
    /// the allocation did; this reads `type[1]= "OSK_RESERVED"` out of the
    /// text the compositor would be handed.
    fn catalogue_hosts(extended: &str) -> Vec<String> {
        let mut out = Vec::new();
        for (index, _) in extended.match_indices("key <") {
            let rest = &extended[index + 5..];
            let Some(name_end) = rest.find('>') else {
                continue;
            };
            let Some(open) = rest.find('{') else { continue };
            let Some(close) = rest[open..].find('}') else {
                continue;
            };
            if rest[open..open + close].contains("\"OSK_RESERVED\"") {
                out.push(rest[..name_end].to_string());
            }
        }
        out
    }

    #[test]
    fn the_reserved_block_rides_above_the_digit_row_and_changes_nothing_below() {
        use xkbcommon::xkb;
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let baseline = fixture_keymap("us,ua", "grp:caps_toggle");
        let extended = extend_with_reserved(&baseline).expect("block composes");
        let hosts = catalogue_hosts(&extended);
        assert_eq!(
            hosts.len(),
            RESERVED_SYMBOLS.len() / 4,
            "the owner's own option set should host the whole catalogue, hosts {hosts:?}"
        );

        // Every key the block does not host is still defined exactly as it
        // was. The hosted ones are checked by behaviour in the next test,
        // which is the claim that actually matters: their levels one to four
        // do not move.
        let before = key_definitions(&baseline);
        let after = key_definitions(&extended);
        for (name, body) in &before {
            if hosts.contains(name) {
                continue;
            }
            assert_eq!(
                after.get(name),
                Some(body),
                "the block changed the existing key <{name}>"
            );
        }
        assert_eq!(
            after.len(),
            before.len() + CATALOGUE_FREE.len(),
            "the block should add only the free positions it fills"
        );
        // `key_definitions` is a map, so a hosted position left in the text
        // twice would collapse into one entry and the count above would still
        // pass. The cut is asserted directly instead.
        for host in &hosts {
            assert_eq!(
                extended.matches(&format!("key <{host}>")).count(),
                1,
                "<{host}> is defined twice: the old statement was not cut"
            );
        }

        // And the result is a keymap, not just text that looks like one.
        let compiled = xkb::Keymap::new_from_string(
            &context,
            extended.clone(),
            xkb::KEYMAP_FORMAT_TEXT_V1,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .expect("the extended keymap compiles");

        // The symbols resolve, on levels five to eight, in EVERY group — which
        // is the point of the block: they do not belong to a layout.
        let codes = parse_keycodes(&extended);
        let groups = compiled.num_layouts();
        assert!(groups >= 2, "fixture should have two groups, has {groups}");
        for (index, position) in hosts.iter().enumerate() {
            let code = codes[position] + 8;
            for group in 0..groups {
                for entry in 0..4u32 {
                    let syms = compiled.key_get_syms_by_level(code.into(), group, 4 + entry);
                    let wanted = RESERVED_SYMBOLS[index * 4 + entry as usize];
                    assert_eq!(
                        syms.len(),
                        1,
                        "<{position}> group {group} level {} should carry {wanted}",
                        5 + entry
                    );
                    // Compared as keysyms, not as names: xkbcommon
                    // canonicalises, so `U2248` comes back as `approxeq` and
                    // a name comparison fails on a keymap that is correct.
                    assert_eq!(
                        syms[0],
                        xkb::keysym_from_name(wanted, xkb::KEYSYM_NO_FLAGS),
                        "<{position}> group {group} level {} should be {wanted}, got {}",
                        5 + entry,
                        xkb::keysym_get_name(syms[0])
                    );
                }
            }
        }
    }

    /// The whole visible page survives every fixture, options included.
    ///
    /// Thirteen of the fourteen slots carry the fifty-two characters `&123`
    /// draws, so "the block landed" is not the claim — "the page is complete"
    /// is, and it is the one that broke when the probe refused the digit row.
    #[test]
    fn every_fixture_hosts_the_whole_visible_page() {
        for (layouts, options) in BLOCK_FIXTURES {
            let extended = extend_with_reserved(&fixture_keymap(layouts, options))
                .unwrap_or_else(|| panic!("{layouts} {options}: block composes"));
            let hosts = catalogue_hosts(&extended);
            assert!(
                hosts.len() >= 13,
                "{layouts} {options}: only {} slots, page incomplete: {hosts:?}",
                hosts.len()
            );
        }
    }

    /// The chord the panel actually sends selects the catalogue.
    ///
    /// `key_get_syms_by_level` says where a symbol sits; it does not say that
    /// holding `<LVL5>` gets there. That needs the modifier to have an action
    /// behind it, and the whole move rests on it — so the chord is asked of a
    /// state the way `ModifierReducer` builds it: LevelFive, plus Shift and
    /// LevelThree, around the position.
    #[test]
    fn holding_lvl5_selects_the_catalogue_the_way_the_panel_holds_it() {
        use xkbcommon::xkb;
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        for (layouts, options) in BLOCK_FIXTURES {
            let extended = extend_with_reserved(&fixture_keymap(layouts, options))
                .unwrap_or_else(|| panic!("{layouts} {options}: block composes"));
            let compiled = xkb::Keymap::new_from_string(
                &context,
                extended.clone(),
                xkb::KEYMAP_FORMAT_TEXT_V1,
                xkb::KEYMAP_COMPILE_NO_FLAGS,
            )
            .expect("extended compiles");
            let probe = LevelProbe::new(&compiled).expect("the fixture names its modifiers");
            let codes = parse_keycodes(&extended);
            let hosts = catalogue_hosts(&extended);
            let (shift, lvl3) = (probe.chords[1], probe.chords[2]);
            let typed = |group: u32, mods: u32, position: &str| -> String {
                syms_with_mods(&compiled, group, mods, codes[position])
                    .iter()
                    .map(|sym| xkb::keysym_to_utf8(*sym).trim_end_matches('\0').to_string())
                    .collect()
            };

            // In every group and on every host, because that is the block's
            // entire claim: the catalogue is not a layout's business.
            for group in 0..compiled.num_layouts() {
                for (index, position) in hosts.iter().enumerate() {
                    for (entry, mods) in [
                        (0, probe.level_five),
                        (1, probe.level_five | shift),
                        (2, probe.level_five | lvl3),
                        (3, probe.level_five | lvl3 | shift),
                    ] {
                        let wanted = xkb::keysym_to_utf8(xkb::keysym_from_name(
                            RESERVED_SYMBOLS[index * 4 + entry],
                            xkb::KEYSYM_NO_FLAGS,
                        ));
                        assert_eq!(
                            typed(group, mods, position),
                            wanted.trim_end_matches('\0'),
                            "{layouts} {options}: <{position}> group {group} level {}",
                            5 + entry
                        );
                    }
                }
            }
        }
    }

    /// Ticket 20's acceptance criterion, as an assertion: levels one to four of
    /// every position still produce exactly what they produced before, under
    /// every modifier the panel or a hand can hold.
    ///
    /// Behaviour, not text: a hosted key is rewritten by definition, so
    /// comparing its source would only restate that. What must not move is
    /// what it types — the CapsLock trap ticket 20's rig named is invisible in
    /// a symbol list and obvious here.
    #[test]
    fn levels_one_to_four_are_untouched_on_every_layout_the_block_hosts() {
        use xkbcommon::xkb;
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        for (layouts, options) in BLOCK_FIXTURES {
            let baseline = fixture_keymap(layouts, options);
            let extended = extend_with_reserved(&baseline)
                .unwrap_or_else(|| panic!("{layouts} {options}: block composes"));

            let before = xkb::Keymap::new_from_string(
                &context,
                baseline.clone(),
                xkb::KEYMAP_FORMAT_TEXT_V1,
                xkb::KEYMAP_COMPILE_NO_FLAGS,
            )
            .expect("baseline compiles");
            let after = xkb::Keymap::new_from_string(
                &context,
                extended.clone(),
                xkb::KEYMAP_FORMAT_TEXT_V1,
                xkb::KEYMAP_COMPILE_NO_FLAGS,
            )
            .expect("extended compiles");
            let probe = LevelProbe::new(&before).expect("the fixture names its modifiers");

            // Every pair of the modifiers a keyboard actually has, which is
            // where a wrong key type shows: Lock alone is the CapsLock trap
            // and Lock+Shift is what an ALPHABETIC type does differently from
            // a plain one. LevelFive is left out because it is the block's
            // own — that is what levels five to eight ARE, and what holding it
            // must do is asserted in
            // `holding_lvl5_selects_the_catalogue_the_way_the_panel_holds_it`.
            // A keymap where a physical key already carries it is refused
            // outright; see `an_lv5_option_keeps_the_block_off_ordinary_positions`.
            let singles: Vec<u32> = std::iter::once(0)
                .chain(probe.chords.iter().copied())
                .chain(
                    probe
                        .others
                        .iter()
                        .copied()
                        .filter(|mods| *mods != probe.level_five),
                )
                .collect();
            let mut chords: Vec<u32> = Vec::new();
            for one in &singles {
                for two in &singles {
                    chords.push(one | two);
                }
            }
            chords.sort_unstable();
            chords.dedup();

            for group in 0..before.num_layouts() {
                for raw in before.min_keycode().raw()..=before.max_keycode().raw() {
                    for mods in &chords {
                        assert_eq!(
                            syms_with_mods(&before, group, *mods, raw - 8),
                            syms_with_mods(&after, group, *mods, raw - 8),
                            "{layouts} {options}: <{}> group {group} moved under {mods:#x}",
                            before.key_get_name(raw.into()).unwrap_or("?")
                        );
                    }
                }
            }
        }
    }

    /// A position whose answer moves under CapsLock is refused, not hosted.
    ///
    /// The trap ticket 20's rig found and a symbol list cannot show: an
    /// eight-level type with no `map[Lock]` silently costs an ALPHABETIC
    /// position its uppercasing. The digit row is not alphabetic in any stock
    /// layout, so the refusal is proved against a keymap that puts a letter
    /// there deliberately.
    #[test]
    fn a_position_that_answers_to_capslock_is_not_hosted() {
        let stock = fixture_keymap("us", "");
        assert!(
            catalogue_hosts(&extend_with_reserved(&stock).expect("block composes"))
                .contains(&"AE01".to_string()),
            "the stock digit row should host the block"
        );

        let (lo, hi) = key_statement_bounds(&stock, "AE01").expect("AE01 is defined");
        let mut lettered = String::new();
        lettered.push_str(&stock[..lo]);
        lettered.push_str(
            "\tkey <AE01> {\n\t\ttype[1]= \"ALPHABETIC\",\n\t\tsymbols[1]= [ a, A ]\n\t};\n",
        );
        lettered.push_str(&stock[hi..]);

        let hosts = catalogue_hosts(&extend_with_reserved(&lettered).expect("block composes"));
        assert!(
            !hosts.contains(&"AE01".to_string()),
            "an alphabetic AE01 must be refused, hosts {hosts:?}"
        );
        // Refusing one position costs a spare, not the page: CATALOGUE_SPARE
        // is what the row could not carry.
        assert_eq!(hosts.len(), RESERVED_SYMBOLS.len() / 4);
    }

    /// A user's own `kb_file` that already carries the block is not extended
    /// a second time.
    ///
    /// Not the helper's own published file — that one never reaches
    /// `compile_keymap`'s file arm at all, which is asserted separately below.
    /// This is the other case: someone hands the helper a keymap that already
    /// has a catalogue in it, and a second pass would duplicate the type and
    /// the keys.
    #[test]
    fn a_kb_file_that_already_carries_the_block_is_taken_as_it_is() {
        let stock = fixture_keymap("us,ua", "grp:caps_toggle");
        let extended = extend_with_reserved(&stock).expect("block composes");
        let published = std::env::temp_dir().join("osk-published-test.xkb");
        std::fs::write(&published, &extended).expect("write the published keymap");

        let again = compile_keymap(&XkbConfig {
            kb_file: published.to_string_lossy().to_string(),
            ..XkbConfig::default()
        })
        .expect("the published keymap compiles");
        let _ = std::fs::remove_file(&published);

        // One catalogue, not two: the type is declared once and every hosted
        // position still carries exactly four entries.
        assert_eq!(
            again.matches("type \"OSK_RESERVED\" {").count(),
            1,
            "the block's type was added a second time"
        );
        assert_eq!(
            catalogue_hosts(&again).len(),
            catalogue_hosts(&extended).len(),
            "re-reading the published keymap changed how much it hosts"
        );
        for host in catalogue_hosts(&again) {
            assert_eq!(
                again.matches(&format!("key <{host}>")).count(),
                1,
                "<{host}> is defined twice after re-reading"
            );
        }
    }

    /// The helper's own published keymap is never an input.
    ///
    /// The compositor is pointed at that file so the seat has one keymap
    /// (§35), and the path comes back on the next configure. Reading it would
    /// freeze whichever version wrote it: upgrade the helper while the
    /// compositor still points at yesterday's file and the new one adopts it
    /// verbatim and republishes it, the old keymap outliving the code that
    /// made it. Found in the VM doing exactly that.
    ///
    /// Asked of the decision and not of the filesystem: the earlier version of
    /// this test wrote a fixture to the REAL published path and deleted it
    /// again, which is the live session's keymap — `cargo test` took the
    /// running compositor's keymap out from under it.
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

    /// Ticket 06: the recovery record's three-way decision. A user's own
    /// `kb_file` is remembered verbatim — including a path that merely
    /// CONTAINS our suffix, which is a user's file by exact identity, not
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
        // The audit's misclassification: an unrelated custom path whose
        // suffix resembles the published path.
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

    /// Ticket 31: the installed keymap's group count is the authority for
    /// what a `configure` or `group` command may carry. Nothing installed
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
        // The INCOMING map is the authority (round 17 made that literal:
        // the ceiling counts what the configure compiles to, never the
        // declaration — classic evdev drops layouts past the fourth).
        // A grow from one group to two must not be refused for the old
        // map's count.
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

    /// Ticket 06: the sidecar sits BESIDE the published keymap — the one
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

    /// Ticket 06: the sidecar itself. Written atomically (temp + rename),
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
        // the sidecar holds the PATH, content is read fresh each compile.
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

    /// A custom keymap edited at its own path is a different keymap.
    ///
    /// Ticket 06. The path is what a configure carries and the file behind it
    /// is what the user edits, so comparing configure fields alone reports
    /// "same keymap" for a map whose every key may have changed — and the
    /// helper goes on typing the old one while the panel draws caps for it.
    #[test]
    fn a_kb_file_edited_in_place_is_not_the_same_keymap() {
        let path = std::env::temp_dir().join("osk-ticket-06.xkb");
        let write = |layouts: &str| {
            std::fs::write(&path, fixture_keymap(layouts, "")).expect("write the custom keymap");
        };

        write("us");
        let first = kb_file_mark(&path.to_string_lossy());
        assert!(first.is_some(), "a readable file has a mark");

        // Same path, different content: a different keymap.
        write("de");
        let second = kb_file_mark(&path.to_string_lossy());
        assert_ne!(first, second, "an edited file must not look unchanged");

        // And the same content twice is the same keymap, or every configure
        // would reinstall and the churn ceiling would be spent on nothing.
        write("de");
        assert_eq!(second, kb_file_mark(&path.to_string_lossy()));

        // The two compile to genuinely different keymaps, which is what makes
        // the mark worth reading.
        let config = XkbConfig {
            kb_file: path.to_string_lossy().to_string(),
            ..XkbConfig::default()
        };
        let de = compile_keymap(&config).expect("the custom keymap compiles");
        write("us");
        let us = compile_keymap(&config).expect("the custom keymap compiles");
        assert_ne!(de, us, "the fixture must actually differ");

        // A path that is not there answers None rather than pretending.
        let _ = std::fs::remove_file(&path);
        assert_eq!(kb_file_mark(&path.to_string_lossy()), None);
        assert_eq!(
            kb_file_mark(""),
            None,
            "an RMLVO configure has no file to mark"
        );
    }

    /// A keymap whose `<LVL5>` opens nothing gets its own layout back.
    ///
    /// Declaring the keycode is not the same as binding `ISO_Level5_Shift` to
    /// it. Installing the block anyway would advertise glyphs through the caps
    /// facts that type the position's own level one — silent wrong characters,
    /// which is worse than the missing symbols this is allowed to fail to.
    #[test]
    fn a_keymap_whose_level_five_opens_nothing_gets_no_block() {
        let stock = fixture_keymap("us", "");
        let unbound = stock.replace("\tmodifier_map Mod3 { <LVL5> };\n", "");
        assert_ne!(unbound, stock, "the fixture must actually unbind <LVL5>");
        assert!(
            extend_with_reserved(&unbound).is_none(),
            "a keymap whose <LVL5> opens nothing must not get the block"
        );
    }

    /// A layout option that hands a physical key `ISO_Level5_Shift` keeps the
    /// block off ordinary positions.
    ///
    /// `lv5:ralt_switch_lock` makes AltGr the level-five switch. Hosting the
    /// catalogue above the digit row would then change what AltGr types on it,
    /// which is the one thing §33 promises never happens.
    #[test]
    fn an_lv5_option_keeps_the_block_off_ordinary_positions() {
        let keymap = fixture_keymap("us", "lv5:ralt_switch_lock");
        let hosts = match extend_with_reserved(&keymap) {
            Some(extended) => catalogue_hosts(&extended),
            None => Vec::new(),
        };
        for host in &hosts {
            assert!(
                CATALOGUE_FREE.contains(&host.as_str()),
                "with a physical level-five switch only free positions may host, got {hosts:?}"
            );
        }
    }

    #[test]
    fn a_keymap_with_no_room_is_returned_unchanged() {
        // Fail-soft: an addition that cannot be made is not a reason to hand
        // the compositor nothing. `extend_with_reserved` says no, and
        // `with_reserved_symbols` keeps the keymap that does work.
        assert!(extend_with_reserved("nonsense").is_none());
        assert_eq!(with_reserved_symbols("nonsense".to_string()), "nonsense");
    }

    #[test]
    fn section_bounds_survives_the_nested_braces_a_split_cannot() {
        // The bug this replaced: splitting on "};" lands inside the first
        // nested key definition, and splitting on the last one lands past the
        // keymap's own close.
        let text = "xkb_types \"t\" {\n type \"X\" { a; };\n};\nxkb_symbols \"s\" {\n key <A> { [ a ] };\n};\n";
        let (lo, hi) = section_bounds(text, "xkb_types").expect("types found");
        assert!(text[lo..hi].contains("type \"X\""));
        assert!(!text[lo..hi].contains("xkb_symbols"));
        let (slo, shi) = section_bounds(text, "xkb_symbols").expect("symbols found");
        assert!(text[slo..shi].contains("key <A>"));
        assert!(!text[slo..shi].contains("xkb_types"));
    }

    /// Every `key <NAME> { ... }` in a keymap, whitespace-normalised so the
    /// block writer's indentation is not mistaken for a change.
    fn key_definitions(keymap: &str) -> std::collections::HashMap<String, String> {
        let mut out = std::collections::HashMap::new();
        for (index, _) in keymap.match_indices("key <") {
            let rest = &keymap[index + 5..];
            let Some(name_end) = rest.find('>') else {
                continue;
            };
            let name = rest[..name_end].to_string();
            let Some(open) = rest.find('{') else { continue };
            let mut depth = 0usize;
            for (offset, byte) in rest[open..].bytes().enumerate() {
                match byte {
                    b'{' => depth += 1,
                    b'}' => {
                        depth -= 1;
                        if depth == 0 {
                            let body: String = rest[open..open + offset + 1]
                                .split_whitespace()
                                .collect::<Vec<_>>()
                                .join(" ");
                            out.insert(name.clone(), body);
                            break;
                        }
                    }
                    _ => {}
                }
            }
        }
        out
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
        let first = |code: &u32| masks.get(code).and_then(|per_group| per_group.first());
        // xkb fixes the order of the real modifiers, so Shift is bit 0,
        // Control bit 2 and Mod4 — which is where `us` puts Super — bit 6.
        assert_eq!(first(&codes["LFSH"]), Some(&0b1));
        assert_eq!(first(&codes["RTSH"]), Some(&0b1));
        assert_eq!(first(&codes["LCTL"]), Some(&0b100));
        assert_eq!(first(&codes["LWIN"]), Some(&0b100_0000));
        // An ordinary letter carries no modifier bit at all, which is what
        // keeps the mask from being re-asserted on every keystroke.
        assert_eq!(masks.get(&codes["AD01"]), None);
        // Plain `us` puts RALT on Mod1, alongside LALT.
        assert_eq!(first(&codes["RALT"]), Some(&0b1000));
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
        let first = |code: &u32| masks.get(code).and_then(|per_group| per_group.first());
        assert_eq!(first(&codes["LALT"]), Some(&0b100_0000));
        assert_eq!(first(&codes["LWIN"]), Some(&0b1000));
        // And the modifiers the option does not touch are unmoved.
        assert_eq!(first(&codes["LFSH"]), Some(&0b1));
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
        assert_eq!(
            masks
                .get(&codes["RALT"])
                .and_then(|per_group| per_group.first()),
            Some(&0b1000_0000)
        );
    }

    #[test]
    fn an_altgr_position_carries_the_bit_of_the_group_it_resolves_in() {
        // The curated page's AltGr levels exposed this: under the owner's
        // `us,ua` without an `lv3:` option, RALT is Alt_R (Mod1) in the us
        // group and ISO_Level3_Shift (Mod5) in the ua group. A group-0 probe
        // served Mod1 to both, and every level-3 chord came out as the
        // position's level-1 self — Alt_R+5 typed `5`, not `°`.
        use xkbcommon::xkb;

        let text = compile_keymap(&XkbConfig {
            layouts: "us,ua".into(),
            options: "shift:both_capslock_cancel,grp:caps_toggle".into(),
            ..XkbConfig::default()
        })
        .expect("the owner's RMLVO should compile");
        let codes = parse_keycodes(&text);
        let masks = modifier_masks_for_keymap(&text, &codes);
        let ralt = masks.get(&codes["RALT"]).expect("RALT is a modifier");

        assert_eq!(ralt.first(), Some(&0b1000), "us group: Alt_R is Mod1");
        assert_eq!(
            ralt.get(1),
            Some(&0b1000_0000),
            "ua group: AltGr must reach Mod5"
        );

        // Stand in for the compositor once more, now at group 1: told the
        // helper's Mod5 mask, the level-3 chord must produce degree, not `5`.
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let keymap = xkb::Keymap::new_from_string(
            &context,
            text,
            xkb::KEYMAP_FORMAT_TEXT_V1,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .expect("the helper's own keymap text should compile");
        let mut state = xkb::State::new(&keymap);
        // The compositor receives the helper's group in the locked-layout
        // slot of its update_mask (that is what the protocol's group field
        // is), so the stand-in fills that slot alone.
        state.update_mask(0, 0, 0, 0, 0, 1);
        state.update_mask(*ralt.get(1).expect("ua group mask"), 0, 0, 0, 0, 1);
        assert_eq!(
            state.key_get_utf8(xkb::Keycode::from(codes["AE05"] + 8)),
            "°",
            "the AltGr mask must select the ua group's third level"
        );
    }

    #[test]
    fn the_probe_sets_the_group_once_on_a_three_layout_keymap() {
        // `update_mask`'s last three arguments are the depressed, latched and
        // locked LAYOUT indices, and xkb adds them into the effective group.
        // Asking for the probed group in all three therefore asked for it
        // three times: a two-layout keymap absorbed the triple in its wrap
        // (3g mod 2 == g for every g the probe visits) and came out right by
        // luck, while a three-layout keymap collapses 3g mod 3 to 0 and every
        // group probed as the first. One ask, in the locked slot — the same
        // slot the compositor receives the helper's group in over the
        // virtual-keyboard protocol.
        use xkbcommon::xkb;

        let text = compile_keymap(&XkbConfig {
            layouts: "us,ua,de".into(),
            ..XkbConfig::default()
        })
        .expect("us,ua,de should compile");
        let codes = parse_keycodes(&text);
        let masks = modifier_masks_for_keymap(&text, &codes);
        let ralt = masks.get(&codes["RALT"]).expect("RALT is a modifier");

        assert_eq!(ralt.first(), Some(&0b1000), "us group: Alt_R is Mod1");
        assert_eq!(
            ralt.get(1),
            Some(&0b1000_0000),
            "ua group: AltGr must reach Mod5"
        );
        assert_eq!(
            ralt.get(2),
            Some(&0b1000_0000),
            "de group: AltGr must reach Mod5 too, not the us group's answer"
        );

        // Stand in for the compositor once more, now at the third group and
        // told the helper's own answer for it: the level-3 chord must type
        // the de group's own AltGr character, not group us's plain `5` or
        // group ua's `°` — under the tripled ask every probe resolved at
        // group 0 and this came out `5`.
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let keymap = xkb::Keymap::new_from_string(
            &context,
            text,
            xkb::KEYMAP_FORMAT_TEXT_V1,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .expect("the helper's own keymap text should compile");
        let mut state = xkb::State::new(&keymap);
        let de_mask = *ralt.get(2).expect("de group mask");
        state.update_mask(de_mask, 0, 0, 0, 0, 2);
        assert_eq!(
            state.key_get_utf8(xkb::Keycode::from(codes["AE05"] + 8)),
            "½",
            "the AltGr mask must select the de group's third level"
        );
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
            .and_then(|per_group| per_group.first())
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

    #[test]
    fn hello_is_exactly_one_version_word() {
        // F6: the handshake is a gate, not a default. A bare hello, trailing
        // words, or a non-numeric version word is a malformed hello — an
        // err protocol answer — and only `hello <u32>` negotiates.
        assert_eq!(parse_hello("hello 6"), Some(Ok(6)));
        assert_eq!(parse_hello("hello 0"), Some(Ok(0)));
        assert_eq!(parse_hello("hello"), Some(Err(())));
        assert_eq!(parse_hello("hello 6 extra"), Some(Err(())));
        assert_eq!(parse_hello("hello garbage"), Some(Err(())));
        assert_eq!(parse_hello("hello -1"), Some(Err(())));
        // Not hello lines at all: the verb parser owns them.
        assert_eq!(parse_hello("hellox 5"), None);
        assert_eq!(parse_hello("tap AD01"), None);
        assert_eq!(parse_hello(""), None);
    }

    #[test]
    fn fixed_arity_verbs_refuse_extra_arguments() {
        // F6: tap/down/up/mods/group take exactly one argument; a third
        // word is a malformed line, not a silently truncated command.
        assert!(parse("tap AD01").is_some());
        assert!(parse("tap AD01 extra").is_none());
        assert!(parse("down LFSH").is_some());
        assert!(parse("down LFSH now").is_none());
        assert!(parse("up 16").is_some());
        assert!(parse("up 16 17").is_none());
        assert!(parse("mods 3").is_some());
        assert!(parse("mods 3 4").is_none());
        assert!(parse("group 1").is_some());
        assert!(parse("group 1 2").is_none());
    }

    /// Pulls one position's tab-style fields (`CAPS_FIELD_SEP`-separated) out
    /// of a per-group facts string, so the tag assertions below read like the
    /// protocol they pin.
    fn record_fields<'a>(facts: &'a [String], group: usize, name: &str) -> Vec<&'a str> {
        facts[group]
            .split(CAPS_RECORD_SEP)
            .find(|record| record.split(CAPS_FIELD_SEP).next() == Some(name))
            .map(|record| record.split(CAPS_FIELD_SEP).collect())
            .unwrap_or_default()
    }

    #[test]
    fn keycap_facts_resolve_text_for_every_group_of_the_installed_keymap() {
        // The heart of ticket 04: the same compiled keymap that types answers
        // for its caps, per group, with the real characters. Group 0 of us,ua
        // is Latin; group 1 is the Ukrainian alphabet on the same positions.
        let text = compile_keymap(&XkbConfig {
            layouts: "us,ua".into(),
            ..XkbConfig::default()
        })
        .expect("us,ua should compile");
        let facts = keycap_facts_for_groups(&text);
        assert_eq!(facts.len(), 2);

        assert_eq!(record_fields(&facts, 0, "AD01"), ["AD01", "tq", "tQ"]);
        // Group 1 is four-level: ua carries the Serbian ј/Ј on the AltGr
        // levels of the same position, and the facts answer every level the
        // keymap defines, not just the two the main page draws.
        assert_eq!(
            record_fields(&facts, 1, "AD01"),
            ["AD01", "tй", "tЙ", "tј", "tЈ"]
        );
        // The number row: shifted and unshifted, same across these groups —
        // and, since ticket 20 moved the reserved block onto it (§33), four
        // more levels carrying the block's first catalogue slot. Levels one to
        // four are what `us` always had; five to eight are the helper's.
        assert_eq!(
            record_fields(&facts, 0, "AE01"),
            ["AE01", "t1", "t!", "t1", "t!", "t!", "t1", "t@", "t2"]
        );
        // A modifier position answers too — its keysyms are real, they just
        // produce no character (the `x` kind).
        let shift = record_fields(&facts, 0, "LFSH");
        assert_eq!(shift[0], "LFSH");
        assert!(shift[1..].iter().all(|f| f.starts_with('x')), "{shift:?}");
    }

    #[test]
    fn a_textless_keysym_and_a_missing_level_are_reported_honestly() {
        // The three unavailable shapes the panel must tell apart: real text,
        // a symbol that produces no character (dead_acute, Linefeed — whose
        // resolved control character is dropped rather than injected into the
        // one-line protocol), and no symbol at all. A FOUR_LEVEL type keeps
        // the level count at four so NoSymbol lands on its own level.
        let keymap = "xkb_keymap {\n\
            xkb_keycodes { include \"evdev\" };\n\
            xkb_types { include \"basic+extra\" };\n\
            xkb_compat { include \"basic\" };\n\
            xkb_symbols {\n\
                include \"pc+us\"\n\
                key <AD01> { type[Group1] = \"FOUR_LEVEL\", [ a, A, dead_acute, NoSymbol ] };\n\
                key <AC01> { type[Group1] = \"FOUR_LEVEL\", [ z, Z, Linefeed, NoSymbol ] };\n\
            };\n\
        };";
        let facts = keycap_facts_for_groups(keymap);
        assert_eq!(
            record_fields(&facts, 0, "AD01"),
            ["AD01", "ta", "tA", "xdead_acute", "n"]
        );
        assert_eq!(
            record_fields(&facts, 0, "AC01"),
            ["AC01", "tz", "tZ", "xLinefeed", "n"]
        );
    }

    #[test]
    fn a_caps_reply_echoes_generation_and_group_and_answers_the_positions_asked() {
        let text = compile_keymap(&XkbConfig {
            layouts: "us,ua".into(),
            ..XkbConfig::default()
        })
        .expect("us,ua should compile");
        let facts = keycap_facts_for_groups(&text);

        // Requested positions answer in request order. The header is tab
        // separated like every other reply; 0x1F begins at the levels.
        assert_eq!(
            caps_reply(7, &facts, 0, &["AD01".to_string(), "AE01".to_string()])
                .expect("group 0 exists"),
            format!(
                "caps\t7\t0\tAD01{f}tq{f}tQ{r}AE01\
                 {f}t1{f}t!{f}t1{f}t!{f}t!{f}t1{f}t@{f}t2",
                f = CAPS_FIELD_SEP,
                r = CAPS_RECORD_SEP
            )
        );
        // No position list: the group's whole record set.
        let full = caps_reply(7, &facts, 1, &[]).expect("group 1 exists");
        assert!(full.starts_with("caps\t7\t1\t"));
        assert!(full
            .split(CAPS_RECORD_SEP)
            .any(|r| r.starts_with("AD01\u{1f}")));
        // A position the keymap does not carry answers bare — the panel's
        // "no keymap entry", never another position's facts.
        let with_unknown = caps_reply(7, &facts, 0, &["AD01".to_string(), "ZZ09".to_string()])
            .expect("group 0 exists");
        assert!(with_unknown.split(CAPS_RECORD_SEP).any(|r| r == "ZZ09"));
        // A group past the keymap's own count is refused rather than wrapped:
        // xkb would silently answer another group's facts for it.
        assert_eq!(caps_reply(7, &facts, 2, &["AD01".to_string()]), None);
    }

    #[test]
    fn parses_the_caps_command_with_and_without_a_position_list() {
        match parse("caps 1 AD01 AE02") {
            Some(Command::Caps { group, positions }) => {
                assert_eq!(group, 1);
                assert_eq!(positions, vec!["AD01".to_string(), "AE02".to_string()]);
            }
            other => panic!("expected a caps command, got {other:?}"),
        }
        match parse("caps 0") {
            Some(Command::Caps { group, positions }) => {
                assert_eq!(group, 0);
                assert!(positions.is_empty());
            }
            other => panic!("expected a bare caps command, got {other:?}"),
        }
        // No group, no space-prefixed verb: neither is a caps command.
        assert!(parse("caps").is_none());
        assert!(parse("capsfoo 1").is_none());
        assert!(parse("caps x").is_none());
    }

    /// A stock-shaped letter map, spelled the way the real layouts spell one:
    /// four levels per position, reached by the block's own chords, Lock
    /// answering nothing, and the level modifiers bound the way every
    /// compiled keymap binds them — their keysyms on the level keys, over
    /// `modifier_map Mod5 { <LVL3> }` and `Mod3 { <LVL5> }` (decisions §33).
    /// Without the keysyms the virtual modifiers never reach the types, the
    /// chords go inert and nothing is hostable — a property of the fixture,
    /// not of the gates. `<AB11>` is declared and carries no key statement,
    /// so it is the one free position `extend_with_reserved` can fill.
    const TEXT_FIXTURE: &str = "xkb_keymap {\n\
        xkb_keycodes {\n\
            <AD01> = 24;\n\
            <AD02> = 25;\n\
            <AC01> = 38;\n\
            <LVL3> = 50;\n\
            <LVL5> = 94;\n\
            <AB11> = 97;\n\
        };\n\
        xkb_types {\n\
            virtual_modifiers LevelThree, LevelFive;\n\
            type \"FOUR_LEVEL\" {\n\
                modifiers = Shift + LevelThree;\n\
                map[None] = Level1;\n\
                map[Shift] = Level2;\n\
                map[LevelThree] = Level3;\n\
                map[Shift+LevelThree] = Level4;\n\
            };\n\
        };\n\
        xkb_compat {\n\
            interpret 0xfe03+AnyOf(all) {\n\
                virtualModifier= LevelThree;\n\
                useModMapMods=level1;\n\
                action= SetMods(modifiers=LevelThree,clearLocks);\n\
            };\n\
            interpret 0xfe11+AnyOf(all) {\n\
                virtualModifier= LevelFive;\n\
                useModMapMods=level1;\n\
                action= SetMods(modifiers=LevelFive,clearLocks);\n\
            };\n\
        };\n\
        xkb_symbols {\n\
            key <AD01> {\n\
                type[1]= \"FOUR_LEVEL\", type[2]= \"FOUR_LEVEL\",\n\
                symbols[1]= [1, exclam, onesuperior, exclamdown],\n\
                symbols[2]= [2, at, oneeighth, threeeighths]\n\
            };\n\
            key <AC01> {\n\
                type[1]= \"FOUR_LEVEL\", type[2]= \"FOUR_LEVEL\",\n\
                symbols[1]= [3, numbersign, sterling, section],\n\
                symbols[2]= [4, dollar, onequarter, currency]\n\
            };\n\
            key <LVL3> { [ISO_Level3_Shift] };\n\
            key <LVL5> { [ISO_Level5_Shift] };\n\
            modifier_map Mod5 { <LVL3> };\n\
            modifier_map Mod3 { <LVL5> };\n\
        };\n\
    };";

    #[test]
    fn probe_surrogate_unicode_keysyms() {
        use xkbcommon::xkb;
        let text = TEXT_FIXTURE.replace("onesuperior", "0x100d83d");
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let map = xkb::Keymap::new_from_string(
            &context,
            text,
            xkb::KEYMAP_FORMAT_TEXT_V1,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .expect("numeric surrogate keysym compiles");
        let codes = parse_keycodes(TEXT_FIXTURE);
        assert_eq!(
            map.key_get_syms_by_level(xkb::Keycode::from(codes["AD01"] + 8), 0, 2),
            &[xkb::Keysym::from(0x0100_d83d)]
        );
        let mut state = xkb::State::new(&map);
        let probe = LevelProbe::new(&map).expect("fixture has LevelThree");
        state.update_mask(probe.chords[2], 0, 0, 0, 0, 0);
        assert_eq!(
            state.key_get_utf32(xkb::Keycode::from(codes["AD01"] + 8)),
            0
        );
    }

    /// Round 17: the RMLVO ceiling counts the COMPILED map, never the
    /// declaration — classic evdev rules resolve only layout[1..=4], so
    /// five declared layouts compile to four groups and a group-4
    /// configure must be refused (before, it silently typed group 0's
    /// alphabet under the fifth language's name). Round 18 unified the
    /// gate: this is the exact path apply's configure arm walks.
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

    // ---- the 2026-09-19 audit: malformed input must never wedge the helper ----

    #[test]
    fn nul_in_rmlvo_fields_is_refused_not_fatal() {
        // xkbcommon's CString conversion panics on an interior NUL, and the
        // compile runs under the shared lock — one poisoned mutex and the
        // helper is alive-but-dead until a restart systemd never orders.
        // Refused like any compile failure now, from every field.
        let config = XkbConfig {
            layouts: "us\x00ua".into(),
            ..XkbConfig::default()
        };
        assert!(compile_keymap(&config).is_none());
        let config = XkbConfig {
            model: "pc10\x005".into(),
            ..XkbConfig::default()
        };
        assert!(compile_keymap(&config).is_none());
        let config = XkbConfig {
            options: "compose:caps\x00grp:alt_shift_toggle".into(),
            ..XkbConfig::default()
        };
        assert!(compile_keymap(&config).is_none());
        // And the parse gate: a configure carrying a NUL is not a command.
        assert!(parse("configure\tevdev\tpc105\tus\x00ua\t\t\t0").is_none());
        // A clean configure still parses.
        assert!(parse("configure\tevdev\tpc105\tus,ua\t\tcompose:caps\t\t1").is_some());
    }

    #[test]
    fn nul_inside_a_custom_keymap_is_refused_not_fatal() {
        let path = std::env::temp_dir().join(format!("osk-nul-keymap-{}.xkb", std::process::id()));
        std::fs::write(&path, b"xkb_keymap {\x00};").expect("write the NUL keymap");
        let config = XkbConfig {
            kb_file: path.display().to_string(),
            ..XkbConfig::default()
        };
        assert!(compile_keymap(&config).is_none());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn custom_keymap_reads_are_bounded_and_regular_file_only() {
        // Empty path, a device, a directory: refused before a single byte.
        assert!(read_kb_file_bounded("").is_none());
        assert!(read_kb_file_bounded("/dev/null").is_none());
        assert!(read_kb_file_bounded("/tmp").is_none());
        // At the limit passes; one byte past it is refused unread.
        let path = std::env::temp_dir().join(format!("osk-kbfile-limit-{}", std::process::id()));
        let path = path.to_str().unwrap();
        std::fs::write(path, vec![b'x'; KB_FILE_LIMIT as usize]).expect("write at the limit");
        assert_eq!(
            read_kb_file_bounded(path).map(|bytes| bytes.len()),
            Some(KB_FILE_LIMIT as usize)
        );
        std::fs::write(path, vec![b'x'; KB_FILE_LIMIT as usize + 1])
            .expect("write past the limit");
        assert!(read_kb_file_bounded(path).is_none());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn the_handshake_window_is_absolute_under_traffic() {
        // Continuous frames never pause the read, so the window is checked
        // per iteration — a connection that streams without a hello is
        // dropped once the window wears out, not only when it goes quiet.
        assert!(handshake_expired(false, Duration::from_secs(5)));
        assert!(handshake_expired(false, Duration::from_secs(600)));
        assert!(!handshake_expired(false, Duration::from_secs(4)));
        assert!(!handshake_expired(true, Duration::from_secs(600)));
    }

    // ---- the review's second round: the descriptor is the truth ----

    #[test]
    fn a_fifo_is_refused_through_the_opened_descriptor() {
        use std::ffi::CString;
        let path = std::env::temp_dir()
            .join(format!("osk-kbfile-fifo-{}", std::process::id()));
        let cpath = CString::new(path.display().to_string()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(cpath.as_ptr(), 0o644) }, 0);
        // A FIFO opened read-only blocks until a writer appears; the
        // nonblocking open plus fstat-on-the-descriptor refuses it
        // instantly — and no swap between a by-name stat and the open can
        // change what the descriptor then says about itself.
        let started = Instant::now();
        assert!(read_kb_file_bounded(path.to_str().unwrap()).is_none());
        assert!(started.elapsed() < Duration::from_secs(2));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn reply_writes_are_bounded_by_the_remaining_handshake_window() {
        // Handshaked, the fixed write bound stands. Inside the window the
        // write gets only what is LEFT of it; past the window, nothing —
        // a parked write must not carry a late hello home.
        assert_eq!(reply_bound(true, Duration::from_secs(600)), WRITE_BOUND);
        assert_eq!(reply_bound(false, Duration::from_secs(1)), Duration::from_secs(4));
        assert!(reply_bound(false, Duration::from_secs(6)).is_zero());
        assert_eq!(reply_bound(false, Duration::ZERO), HANDSHAKE_WINDOW);
    }

    // ---- the review's third round ----

    #[test]
    fn a_keycode_beyond_the_sane_range_is_refused_at_every_gate() {
        // Round eleven's blocker: a 60-byte keymap declaring a keycode near
        // u32::MAX made the keycap walk iterate for seconds under the
        // shared lock. Every compile door refuses it now — this one
        // drives the unified gate path (round 18: one compile serves the
        // ceiling and the install).
        let sane = fixture_keymap("us,ua", "");
        let hostile = sane.replace(
            "<ESC> = 9;",
            "<ZZZZ> = 2147483647;\n\t<ESC> = 9;",
        );
        assert!(hostile.contains("<ZZZZ> = 2147483647;"));
        let config = XkbConfig {
            rules: "evdev".into(),
            model: "pc105".into(),
            layouts: "us".into(),
            variants: "".into(),
            options: "".into(),
            kb_file: "/nonexistent-fixture.xkb".into(),
            group: 0,
        };
        assert_eq!(
            compile_keymap_with(&config, Some(hostile.as_bytes())),
            None,
            "the compile refuses the huge keycode"
        );
        // The walk itself only ever visits NAMED keys: a map that declares
        // none answers no facts, in bounded time by construction.
        assert_eq!(keycap_facts_for_groups("xkb_keymap {}"), Vec::<String>::new());
    }

    #[test]
    fn a_custom_keymaps_groups_come_from_the_compiled_map() {
        // A real two-group fixture read through the whole bounded path: a
        // layouts string of one entry used to refuse group 1 for a map the
        // file itself carries two groups on (the review's finding 3). The
        // compiled keymap is the authority — the SAME text round 18's
        // unified gate counts and hands to install_config, so the ceiling
        // and the installed map can never be two different files.
        let path = std::env::temp_dir()
            .join(format!("osk-groups-{}.xkb", std::process::id()));
        std::fs::write(&path, fixture_keymap("us,ua", ""))
            .expect("write the two-group keymap");
        let two = read_kb_file_bounded(path.to_str().unwrap()).expect("read it back");
        let config = XkbConfig {
            rules: "evdev".into(),
            model: "pc105".into(),
            layouts: "us".into(),
            variants: "".into(),
            options: "".into(),
            kb_file: path.to_string_lossy().into_owned(),
            group: 0,
        };
        let text = compile_keymap_with(&config, Some(two.as_slice()))
            .expect("the two-group fixture compiles");
        assert_eq!(keycap_facts_for_groups(&text).len(), 2);
        let _ = std::fs::remove_file(&path);
        let one_config = XkbConfig {
            kb_file: "/nonexistent-fixture.xkb".into(),
            ..config
        };
        let one = compile_keymap_with(
            &one_config,
            Some(fixture_keymap("us", "").as_bytes()),
        )
        .expect("the one-group fixture compiles");
        assert_eq!(keycap_facts_for_groups(&one).len(), 1);
        // Uncompilable bytes answer None, not a guess.
        assert_eq!(
            compile_keymap_with(&one_config, Some(b"not a keymap")),
            None
        );
    }
}
