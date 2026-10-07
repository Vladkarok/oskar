//! Keymap compilation: the configured XKB source, the reserved symbol block
//! carried above it, and the facts read back out of the compiled text.

use std::io::Write;
use std::os::fd::AsFd;

use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1;

use crate::seat::is_published_keymap;

/// Until the panel reports the real list. Any layout compiles; this one just
/// gives the helper a valid keymap to be ready with.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct XkbConfig {
    pub(crate) rules: String,
    pub(crate) model: String,
    pub(crate) layouts: String,
    pub(crate) variants: String,
    pub(crate) options: String,
    pub(crate) kb_file: String,
    pub(crate) group: u32,
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
    pub(crate) fn same_keymap(&self, other: &Self) -> bool {
        self.rules == other.rules
            && self.model == other.model
            && self.layouts == other.layouts
            && self.variants == other.variants
            && self.options == other.options
            && self.kb_file == other.kb_file
    }
}

/// The highest keycode this helper will ever walk. Stock evdev tops out
/// at 709; xkbcommon accepts keycodes to 4294967294, and walking such a span
/// would pin the shared lock for seconds per configure. Both compile paths
/// refuse larger maps, which keeps the keycap walk over the span bounded.
pub(crate) const MAX_SANE_KEYCODE: u32 = 4096;

/// The largest `kb_file` this helper will ever read. The read happens under
/// the shared lock, so an unbounded one could exhaust memory. One bounded
/// read feeds both the mark and the compile.
const KB_FILE_LIMIT: u64 = 2 * 1024 * 1024;

/// A custom keymap's bytes, read once and bounded: a regular file no larger
/// than `KB_FILE_LIMIT`, `take`n to the limit plus one byte so a file grown
/// mid-read still answers a bounded number. Anything else — a FIFO (blocks),
/// a directory, a device, a vanished path — is refused before a single byte
/// is waited on.
pub(crate) fn read_kb_file_bounded(path: &str) -> Option<Vec<u8>> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    if path.is_empty() {
        return None;
    }
    // Open nonblocking first, then validate the descriptor (fstat), not the
    // path: a stat-then-open leaves a window where a FIFO swapped in parks
    // this thread under the shared lock. Opened nonblocking, a FIFO opens
    // instantly and the fstat refuses it; what is read is what was checked.
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

pub(crate) fn hash_bytes(bytes: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish()
}

/// A field xkbcommon's CString conversion would panic on. An interior NUL
/// never arrives from a real panel, but the socket is same-user input and
/// the panic fires under the shared lock: the mutex poisons, every later
/// `lock().unwrap()` panics, and the helper stays alive while doing
/// nothing — systemd sees no crash and never restarts it. Refused exactly
/// like a failing compile.
fn xkb_field_clean(text: &str) -> bool {
    !text.contains('\0')
}

/// What the bytes behind a `kb_file` path currently are, as one number. A
/// custom keymap is edited at the same path, so equal configure fields do not
/// mean an equal keymap.
///
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
pub(crate) fn compile_keymap(config: &XkbConfig) -> Option<String> {
    let bytes = read_kb_file_bounded(&config.kb_file);
    compile_keymap_with(config, bytes.as_deref())
}

pub(crate) fn compile_keymap_with(config: &XkbConfig, kb_file_bytes: Option<&[u8]>) -> Option<String> {
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
    // Never our own published file. It is this helper's output, and taking
    // it as input freezes whatever version wrote it: the block is recognised
    // and kept verbatim, so an old keymap outlives the code that made it. The
    // compositor's RMLVO is the source; the file is only ever the answer.
    // `is_published_keymap` compares canonical paths, because the panel builds
    // this path from `$XDG_RUNTIME_DIR` and the spellings need not match.
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
    // The same keycode gate as the file path: RMLVO resolves the user's own
    // ~/.config/xkb includes, which can declare an arbitrarily high maximum.
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
pub(crate) fn upload_keymap(keyboard: &ZwpVirtualKeyboardV1, text: &str) -> std::io::Result<()> {
    use std::io::{Seek, SeekFrom};
    let mut file = tempfile::tempfile()?;
    file.write_all(text.as_bytes())?;
    file.write_all(&[0])?;
    file.seek(SeekFrom::Start(0))?;
    keyboard.keymap(1, file.as_fd(), text.len() as u32 + 1);
    Ok(())
}

/// The symbols the panel may offer whatever language is configured.
///
/// A layout answers for its own alphabet and for whatever its designer put on
/// AltGr; nothing makes `us` produce `£` or `ua` produce `÷`. These are not a
/// layout's business at all, so the helper carries them itself, identically in
/// every group. Four per position, on levels five to eight: level five, Shift,
/// level three, Shift+level three.
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
/// here come through fine. Spelling them as Unicode keysyms fixes both.
///
/// `U2248` rather than `U223C`: the legacy `approximate` keysym is U+223C
/// TILDE OPERATOR (∼), which is not the almost-equal sign (≈) a symbols page
/// wants and is a near-twin of the ASCII `~` already on the page.
const RESERVED_SYMBOLS: [&str; 56] = [
    // Everything drawn on the direct punctuation page comes first, so the
    // page types without switching to a `us` group, even for `ua,ru`.
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

/// Where the catalogue lives: levels five to eight of the digit row, then the
/// two free positions that survive every consumer measured.
///
/// The digit row because a keycode is not a contract — a table lookup is.
/// Chromium's Ozone/Wayland path drops an evdev code its `DomCode` table does
/// not carry and Wine substitutes for one, so exotic free positions type
/// nothing (or a `?`) there. `AE01`-`AE12` are in every one of those tables. Letters are deliberately not here: an eight-level type
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

/// Free positions that reach a native-Wayland Chromium: `AB11` is evdev 89,
/// `AE13` is 124. They
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
/// Masks, not keys: the question is whether the Lock modifier changes what a
/// position types, and an option is free to move Lock to any key or none.
/// Probing by pressing `<CAPS>` breaks under `grp:caps_toggle`, where it
/// switches the group and every position looks like it answers to something.
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
            // Lock because an eight-level type without `map[Lock]` costs an
            // alphabetic position its uppercasing; the other three are the modifier families the canonical
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
/// would then change what that key types, which the block must never do, so
/// when this is true the block stays off ordinary positions and
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
    // before the ordinary ones are taken, so slots are held back only for
    // positions that exist: `jp` defines both of them and `br` defines `AB11`.
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

pub(crate) fn parse_keycodes(keymap: &str) -> std::collections::HashMap<String, u32> {
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
/// the modifier map is the union of every modifier a position can reach on
/// any level, while xkb resolves a press through the level actually selected.
/// Under `shift:both_capslock_cancel` with `grp:caps_toggle` the map says
/// `modifier_map Lock { <LFSH> }`; a union would report a held Shift as
/// Shift+Lock, and letters would come out lowercase.
///
/// Pressing the position in a clean state and serializing what comes out is
/// what the compositor would do for a physical keyboard, so it agrees by
/// construction, and it sees positions that become modifiers through a compat
/// interpret rather than a modifier map.
///
/// The probe runs once per group: a position's modifier meaning depends on
/// the group it resolves in. Under `us,ua` without an `lv3:` option, RALT is
/// Alt_R (Mod1) in us and ISO_Level3_Shift (Mod5) in ua. `Shared::modifier_mask`
/// picks the entry for the group the device is typing in.
pub(crate) fn modifier_masks_for_keymap(
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
            // adds them, so the group must appear in exactly one. The locked
            // slot is the one the compositor fills from the protocol.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{keycap_facts_for_groups, parse};
    use std::time::{Duration, Instant};

    /// Layout and option sets the block has to survive. The options are the
    /// point: a probe that presses `<CAPS>` to ask about Lock switches the
    /// group under `grp:caps_toggle` and refuses the whole digit row, and
    /// option-free fixtures cannot see that.
    const BLOCK_FIXTURES: [(&str, &str); 10] = [
        ("us", ""),
        ("us,ua", ""),
        ("us,ua", "grp:caps_toggle"),
        ("us,ua", "compose:caps,grp:alt_shift_toggle"),
        ("us,ua", "shift:both_capslock_cancel,grp:caps_toggle"),
        ("ua,ru", "grp:caps_toggle"),
        ("de,fr", "lv3:alt_switch"),
        ("us,it,ua,ru", "grp:alt_shift_toggle"),
        // `jp` defines both free positions and `br` defines `AB11`: the
        // allocator must not hold slots back for positions that are taken.
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

    /// The positions the block actually landed on, read back out of the
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

        // The symbols resolve, on levels five to eight, in every group — which
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
    /// is.
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
    /// behind it, and the catalogue rests on it — so the chord is asked of a
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

    /// Levels one to four of every position still produce exactly what they
    /// produced before the block, under every modifier the panel or a hand
    /// can hold.
    ///
    /// Behaviour, not text: a hosted key is rewritten by definition, so
    /// comparing its source would only restate that. What must not move is
    /// what it types — the CapsLock trap is invisible in a symbol list and
    /// obvious here.
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
            // own — that is what levels five to eight are, and what holding it
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
    /// The trap a symbol list cannot show: an
    /// eight-level type with no `map[Lock]` silently costs an alphabetic
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
        let published = std::env::temp_dir().join(format!("osk-published-test-{}.xkb", std::process::id()));
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

    /// A custom keymap edited at its own path is a different keymap.
    ///
    /// The path is what a configure carries and the file behind it
    /// is what the user edits, so comparing configure fields alone reports
    /// "same keymap" for a map whose every key may have changed — and the
    /// helper goes on typing the old one while the panel draws caps for it.
    #[test]
    fn a_kb_file_edited_in_place_is_not_the_same_keymap() {
        let path = std::env::temp_dir().join(format!("osk-kbfile-refresh-{}.xkb", std::process::id()));
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
    /// which the block must never do.
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
        // Splitting on "};" lands inside the first nested key definition,
        // and splitting on the last one lands past the keymap's own close.
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
        // Under `lv3:ralt_switch` AltGr emits ISO_Level3_Shift and reaches
        // Mod5 through a compat interpret, with no modifier-map entry to read.
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
        // Under `us,ua` without an `lv3:` option, RALT is Alt_R (Mod1) in the
        // us group and ISO_Level3_Shift (Mod5) in the ua group. A group-0
        // probe would serve Mod1 to both, and Alt_R+5 would type `5`, not `°`.
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
        // locked layout indices, and xkb adds them into the effective group.
        // Asking in all three asks three times: a two-layout keymap wraps
        // 3g back to g, but a three-layout one collapses every group to the
        // first. One ask, in the locked slot — the slot the compositor
        // receives the helper's group in over the protocol.
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
        // group ua's `°`.
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
    /// a wrong mask can look plausible while only the letter comes out wrong.
    ///
    /// `shift:both_capslock_cancel` puts Caps_Lock on the second level of the
    /// Shift keys and `grp:caps_toggle` takes CAPS out of Lock, so the
    /// compiled keymap ends up with `modifier_map Lock { <LFSH> }` alongside
    /// `modifier_map Shift { <LFSH>, <RTSH> }`. A mask OR-ed straight out of
    /// the modifier map would report Shift+Lock for a held Shift — and
    /// Shift+Lock on an ALPHABETIC key selects level 1, a lowercase letter.
    /// The number row is TWO_LEVEL and ignores Lock, so digits would still
    /// shift while letters did not.
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
        // The TWO_LEVEL number row shifts too.
        assert_eq!(typed("AE01"), "!", "a held Shift must shift the number row");
    }

    /// A stock-shaped letter map, spelled the way the real layouts spell one:
    /// four levels per position, reached by the block's own chords, Lock
    /// answering nothing, and the level modifiers bound the way every
    /// compiled keymap binds them — their keysyms on the level keys, over
    /// `modifier_map Mod5 { <LVL3> }` and `Mod3 { <LVL5> }`.
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

    // ---- malformed input must never wedge the helper ----

    #[test]
    fn nul_in_rmlvo_fields_is_refused_not_fatal() {
        // xkbcommon's CString conversion panics on an interior NUL, and the
        // compile runs under the shared lock — one poisoned mutex and the
        // helper is alive-but-dead until a restart systemd never orders.
        // Refused like any compile failure, from every field.
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

    // ---- the descriptor is the truth ----

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

    // ---- keycode and group bounds ----

    #[test]
    fn a_keycode_beyond_the_sane_range_is_refused_at_every_gate() {
        // A tiny keymap declaring a keycode near u32::MAX would make the
        // keycap walk iterate for seconds under the shared lock. Every
        // compile path refuses it; this one drives the configure gate, where
        // one compile serves the ceiling and the install.
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
        // A map that declares no keys answers no facts.
        assert_eq!(keycap_facts_for_groups("xkb_keymap {}"), Vec::<String>::new());
    }

    #[test]
    fn a_custom_keymaps_groups_come_from_the_compiled_map() {
        // A real two-group fixture read through the whole bounded path: the
        // file's own groups count, whatever the layouts string says. The
        // compiled keymap is the authority — the same text the configure
        // gate counts and hands to install_config, so the ceiling and the
        // installed map can never be two different files.
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
