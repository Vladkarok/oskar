//! The socket's wire grammar: commands in, keycap-facts replies out.

use crate::keymap::{XkbConfig, MAX_SANE_KEYCODE};

/// Bumped whenever the command set or a reply shape changes, so a plugin
/// updated without reinstalling the helper fails the hello gate instead of
/// failing silently. The command set is configure/caps/keyboards/group/
/// mods/down/up/tap/ping/hello; any other verb earns `err unknown command`.
pub(crate) const PROTOCOL_VERSION: u32 = 6;

/// A key is named the way xkb names it (`AD01`) or given as a raw evdev code.
#[derive(Debug)]
pub(crate) enum Key {
    Code(u32),
    Name(String),
}

#[derive(Debug)]
pub(crate) enum Command {
    Tap(Key),
    Down(Key),
    Up(Key),
    Mods(u32),
    /// Selects which compiled layout this device types in.
    Group(u32),
    /// Atomically installs complete XKB state and selects its active group.
    Configure(XkbConfig),
    /// Keycap facts: the requested positions' per-level text
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
/// from the very text that was uploaded, so the facts and the typing share one
/// compiled keymap.
///
/// Field grammar, one per level in level order: `t<text>` for a level whose
/// symbols resolve to character text (concatenated when a level carries
/// several symbols), `x<keysym>` for symbols that produce no character (a
/// dead key, a media key), `n` for no symbol at all. Control characters are
/// dropped from resolved text — they are not drawable, and a Linefeed keysym
/// must not inject a newline into a one-line protocol — with a level left
/// with nothing drawable reported as the textless kind it then is.
pub(crate) fn keycap_facts_for_groups(keymap: &str) -> Vec<String> {
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

    // The span walk is bounded only because the compile gates refuse any map
    // with max_keycode above MAX_SANE_KEYCODE. A text-level named-keys walk is
    // not an alternative: include-based keymaps carry no declarations to read.
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
/// a carried key whose level is empty. `None`
/// says the group is past the keymap's own count, which no panel should ask
/// for: xkb would silently wrap it to another group's facts.
pub(crate) fn caps_reply(gen: u64, per_group: &[String], group: u32, positions: &[String]) -> Option<String> {
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

/// The hello handshake's exact grammar: precisely `hello <u32>`.
/// `Some(Ok(v))` is a well-formed version request, `Some(Err(()))` is a
/// hello-shaped line that is not (bare, trailing words, non-numeric
/// version), and `None` is not a hello line at all, belonging to the verb parser.
pub(crate) fn parse_hello(line: &str) -> Option<Result<u32, ()>> {
    let mut words = line.split_whitespace();
    if words.next()? != "hello" {
        return None;
    }
    match (words.next(), words.next()) {
        (Some(version), None) => Some(version.parse::<u32>().map_err(|_| ())),
        _ => Some(Err(())),
    }
}

pub(crate) fn parse(line: &str) -> Option<Command> {
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
    // Fixed-arity verbs take exactly one argument: a third word is a
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keymap::compile_keymap;

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
        // The handshake is a gate, not a default. A bare hello, trailing
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
        // tap/down/up/mods/group take exactly one argument; a third
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
        // The same compiled keymap that types answers for its caps, per
        // group, with the real characters. Group 0 of us,ua
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
        // The number row: shifted and unshifted, same across these groups,
        // plus four levels carrying the reserved block's first catalogue
        // slot. Levels one to four are `us`'s own; five to eight the helper's.
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
}
