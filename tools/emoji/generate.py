#!/usr/bin/env python3
"""Generate EmojiCatalog.js from the vendored Unicode data.

Turns third_party/emoji/ — emoji-test.txt 16.0 for the set, order, groups,
variant structure and names; CLDR 46 English annotations and derived
annotations as name fallbacks and the English keyword source; CLDR 46
Russian and Ukrainian annotations as further keyword sources — into the
.pragma library module at the repo root (decisions.md §37). Offline,
stdlib-only, byte-deterministic: the inputs fix the order of everything,
nothing else is consulted, and two runs on the same inputs produce
identical bytes.

Names come from the emoji-test.txt data-line comments first — they are
regenerated with each emoji-data release, and CLDR 46's derived
annotations have gone stale against 16.0 before (the E15.1 facing-right
family shipped without its tone suffixes) — with the annotations and
derived annotations as fallbacks. Every kept sequence must end with a
non-empty name. Names stay English in every language: the ru and uk files
contribute keywords only, their tts names are read past, not used.

Fails loudly rather than write a bad catalogue:

- any vendored file's SHA-256 no longer matches third_party/emoji/README.md
  (an upgrade replaces the files and the README table together);
- a fully-qualified sequence is listed twice, or two kept sequences
  coincide once presentation selectors are dropped;
- a kept sequence has no name in the comments or either XML file — the
  count and the first offenders are printed, and nothing is written;
- a variant's base sits in another group, which the hoisting cannot
  represent.

What a variant is, is data-driven, not a hardcoded list: strip every
trailing skin-tone modifier (U+1F3FB..U+1F3FF); if what remains is
different and matches a kept entry (compared without U+FE0F, as the name
lookups already compare), the sequence is that entry's variant and is
hoisted to follow it. Everything else is a base — including the two-tone
families whose tone-stripped form is not itself an RGI sequence. Keywords
come from the annotations only, the same file role in every language
(CLDR keywords the same 1948 sequences for en, ru and uk, so the mirror
is exact), with English keywords equal to the name dropped — a Cyrillic
keyword can never equal an English name, so nothing equivalent applies to
ru/uk. Variants are found through their names and carry no keywords in
any language.

Exit codes:

- `0` — EmojiCatalog.js written.
- `1` — the data is unusable (checksum, duplicate, unnamed, misplaced).

Examples:

    tools/emoji/generate.py
"""

import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "third_party" / "emoji"
OUT = ROOT / "EmojiCatalog.js"

# The checksums from third_party/emoji/README.md. A mismatch means the
# vendored data changed without the README changing with it.
SHA256 = {
    "emoji-test.txt": "24f0c534e86cf142e2496953e8f0e46a3e702392911eddcd29c6cced85139697",
    "cldr46-annotations-en.xml": "b33e2e88ed2fb8c438c1efa9747b9d845e8d7d74ef0c32342a805c0f46fdd7ec",
    "cldr46-annotations-derived-en.xml": "461d1578079c5ebc947e506df6b5a55c93f006160e8dff3f05dcf917ce081604",
    "cldr46-annotations-ru.xml": "72a09fb4292687f3538420ebe723da1590f0ef0910e5ced5e0375339ae6c6dcd",
    "cldr46-annotations-uk.xml": "77fbefc84fc99ba28f40103eb7bf755491881b039301c6967ef633c1f1b6990a",
    # Read for checksum only: the ru/uk keywords mirror the English file
    # role and come from the annotations files, never the derived ones.
    "cldr46-annotations-derived-ru.xml": "7532ab16dca25f11d92ed9aed4467d3d1a5f07fb043c09eb6c5a1ea824244226",
    "cldr46-annotations-derived-uk.xml": "25aa443e3ed2f55da4ef49414ef19623203480a154f1fb2c3685d8b19c19afc5",
    "LICENSE": "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96",
}

TONE_MIN, TONE_MAX = 0x1F3FB, 0x1F3FF


def die(message):
    print("tools/emoji/generate.py: " + message, file=sys.stderr)
    sys.exit(1)


def verify_checksums():
    for name, expected in SHA256.items():
        got = hashlib.sha256((DATA / name).read_bytes()).hexdigest()
        if got != expected:
            die(f"{name} changed (sha256 {got}, expected {expected}); update "
                "third_party/emoji/ together with its README table")


def fmt(sequence):
    return " ".join(f"U+{cp:04X}" for cp in sequence)


def strip_fe0f(sequence):
    return tuple(cp for cp in sequence if cp != 0xFE0F)


def parse_emoji_test():
    """The kept sequences in file order, with group and comment name.

    The trailing comment is the CLDR name published with the emoji-data
    release itself; it is the primary name authority, so it is carried
    even when unreadable and the resolver falls back for it.
    """
    kept = []
    seen = set()
    group = None
    for line in (DATA / "emoji-test.txt").read_text(encoding="utf-8").splitlines():
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            continue
        code, sep, rest = line.partition(";")
        if not sep:
            continue
        status, hash_mark, comment = rest.partition("#")
        if status.strip() != "fully-qualified":
            continue
        sequence = tuple(int(cp, 16) for cp in code.split())
        if sequence in seen:
            die(f"emoji-test.txt lists {fmt(sequence)} twice")
        seen.add(sequence)
        name = None
        if hash_mark:
            match = re.match(r"(.+?) E[0-9]+\.[0-9]+ (.+)", comment.strip())
            if match:
                name = " ".join(match.group(2).split())
        kept.append((sequence, group, name))
    return kept


def parse_annotations(name):
    """Names and keyword lists keyed by FE0F-stripped sequence."""
    names, keywords = {}, {}
    for element in ET.parse(DATA / name).getroot().iter("annotation"):
        key = tuple(ord(ch) for ch in element.get("cp") if ch != "\ufe0f")
        # An annotation may be empty; that is a missing name, not a crash.
        text = element.text or ""
        if element.get("type") == "tts":
            names[key] = " ".join(text.split())
        else:
            keywords[key] = [word.strip() for word in text.split("|") if word.strip()]
    return names, keywords


def split_variants(kept):
    """Bases, and variants grouped under their base's sequence.

    Kept entries are compared without U+FE0F, the same normalization the
    name lookups use: the toned forms of text-presentation-default glyphs
    (26F9 1F3FB against the kept 26F9 FE0F) are variants, not orphans.
    Two kept sequences that coincide even then would make the base index
    ambiguous, so that is a data error, not a silent pick.
    """
    kept_of = {}
    for sequence, _, _ in kept:
        key = strip_fe0f(sequence)
        if key in kept_of:
            die(f"emoji-test.txt keeps {fmt(sequence)} and "
                f"{fmt(kept_of[key])}, the same sequence without U+FE0F")
        kept_of[key] = sequence
    bases, variants = [], {}
    for sequence, _, _ in kept:
        stripped = list(sequence)
        while stripped and TONE_MIN <= stripped[-1] <= TONE_MAX:
            stripped.pop()
        base = tuple(stripped)
        if base != sequence and base in kept_of:
            variants.setdefault(kept_of[base], []).append(sequence)
        else:
            bases.append(sequence)
    return bases, variants


def resolve_names(kept, bases, variants, ann_names, ann_keywords, der_names,
                  ru_keywords, uk_keywords):
    """Names and per-language keywords per sequence; variants carry none.

    The comment name published with emoji-test.txt wins; the annotations
    cover bases and the derived annotations cover variants as fallbacks,
    each falling back to the other file. Keywords come from the three
    annotations files, looked up FE0F-stripped like the names. Every kept
    sequence must come out named — an unnamed entry is a data bug, never
    an empty cap name, so the run dies listing them instead.
    """
    comment_of = {sequence: name for sequence, _, name in kept}

    def name_for(sequence, preferred, fallback):
        key = strip_fe0f(sequence)
        return comment_of.get(sequence) or preferred.get(key) or fallback.get(key)

    resolved = {}
    for sequence in bases:
        key = strip_fe0f(sequence)
        resolved[sequence] = (name_for(sequence, ann_names, der_names),
                              ann_keywords.get(key, []),
                              ru_keywords.get(key, []),
                              uk_keywords.get(key, []))
    for group in variants.values():
        for sequence in group:
            resolved[sequence] = (name_for(sequence, der_names, ann_names),
                                  [], [], [])

    lowered = {sequence: (name or "").lower()
               for sequence, (name, _, _, _) in resolved.items()}
    for sequence, (_, words, _, _) in resolved.items():
        for word in [w for w in words if w.lower() == lowered[sequence]]:
            words.remove(word)

    unnamed = [sequence for sequence, (name, _, _, _) in resolved.items()
               if not name]
    if unnamed:
        print(f"{len(unnamed)} kept sequence(s) have no name in the comments "
              "or either annotations file; the first ones:", file=sys.stderr)
        for sequence in unnamed[:10]:
            print(f"  {fmt(sequence)}", file=sys.stderr)
        sys.exit(1)
    return resolved


def order_entries(kept, variants):
    """emoji-test.txt order within each group, variants hoisted after
    their base. A base in another group would put a variant on the wrong
    page, so it is refused rather than silently misplaced."""
    group_of = {sequence: group for sequence, group, _ in kept}
    for base, group in variants.items():
        base_group = group_of[base]
        for sequence in group:
            if group_of[sequence] != base_group:
                die(f"variant {fmt(sequence)} sits in group "
                    f"{group_of[sequence]!r} but its base {fmt(base)} sits "
                    f"in {base_group!r}")
    ordered = []
    variant_set = {s for group in variants.values() for s in group}
    for sequence, _, _ in kept:
        if sequence in variant_set:
            continue
        ordered.append(sequence)
        ordered.extend(variants.get(sequence, []))
    return ordered


HEADER = """\
.pragma library

// Generated by tools/emoji/generate.py from third_party/emoji/ (Emoji 16.0, CLDR 46) — do not edit by hand.
//
// Every fully-qualified sequence of Emoji 16.0, in emoji-test.txt order,
// named by that file's own comments with CLDR 46's English annotations as
// fallback; regeneration is offline and byte-deterministic. A sequence
// whose trailing skin-tone modifiers strip to another kept entry (kept
// entries are compared without U+FE0F) is that entry's variant and is
// hoisted to follow it: the variant's `base` is the base's index and the
// base's `variants` lists its variants' indexes, with bases at -1.
// Variants carry no keywords in any language — search reaches them
// through their names. Besides the English keywords, each entry carries
// CLDR 46 Russian (`ru`) and Ukrainian (`uk`) keywords from that
// release's annotation files: search vocabulary only, display names stay
// English, and the entries that carry them are exactly the ones that
// carry English keywords. Groups follow emoji-test.txt; the ones with no
// fully-qualified entry are not here. Treat entries() and groups() as
// read-only; names and keywords are stored verbatim for display and
// lowercased once below for matching, so search is case-insensitive on
// both sides.
"""

SEARCH = """
// Matching text, lowercased once at load: names and keywords are stored
// verbatim above for display, and search must not depend on the case
// CLDR happens to publish ("flag: Ukraine", "CD", "Mrs.", "Дед Мороз").
var matchNames = []
var matchKeywords = []
var matchRu = []
var matchUk = []
for (var e = 0; e < catalog.length; e++) {
    matchNames.push(catalog[e].name.toLowerCase())
    matchKeywords.push(lowerAll(catalog[e].keywords))
    matchRu.push(lowerAll(catalog[e].ru))
    matchUk.push(lowerAll(catalog[e].uk))
}

function lowerAll(words) {
    var lowered = []
    for (var i = 0; i < words.length; i++) {
        lowered.push(words[i].toLowerCase())
    }
    return lowered
}

// Query terms are ANDed across name and keywords. A term earns the
// strongest tier any of its own matches reaches — the name or a name word
// leading with it, a keyword word leading with it, or merely a substring
// somewhere — and the entry ranks at the weakest of its terms' tiers;
// catalogue order breaks ties inside a tier. The ru and uk keyword lists
// join the keyword tier with the same numbers, but only for terms with a
// character beyond ASCII: CLDR ships the occasional Latin keyword in
// those lists ("100", "SUV"), and an English query's results must stay
// exactly what the English data alone yields. Every Cyrillic term is
// beyond ASCII by construction, so the added vocabulary stays fully
// reachable. limit caps the result; 0 or undefined means all.

function outsideAscii(term) {
    for (var i = 0; i < term.length; i++) {
        if (term.charCodeAt(i) > 127) return true
    }
    return false
}

function termTier(index, term, query, extended) {
    var name = matchNames[index]
    if (name === query) return 1
    var words = name.split(" ")
    for (var i = 0; i < words.length; i++) {
        if (words[i].indexOf(term) === 0) return 1
    }
    var keywordSets = extended
        ? [matchKeywords[index], matchRu[index], matchUk[index]]
        : [matchKeywords[index]]
    for (var s = 0; s < keywordSets.length; s++) {
        var keywords = keywordSets[s]
        for (var k = 0; k < keywords.length; k++) {
            var kw = keywords[k].split(" ")
            for (var j = 0; j < kw.length; j++) {
                if (kw[j].indexOf(term) === 0) return 2
            }
        }
    }
    if (name.indexOf(term) >= 0) return 3
    for (var m = 0; m < keywordSets.length; m++) {
        var substrings = keywordSets[m]
        for (var n = 0; n < substrings.length; n++) {
            if (substrings[n].indexOf(term) >= 0) return 3
        }
    }
    return 0
}

function search(query, limit) {
    var text = String(query === undefined || query === null ? "" : query).trim().toLowerCase()
    var terms = []
    var beyond = []
    var raw = text.split(/\\s+/)
    for (var r = 0; r < raw.length; r++) {
        if (raw[r] !== "") {
            terms.push(raw[r])
            beyond.push(outsideAscii(raw[r]))
        }
    }
    if (terms.length === 0) return []
    var tiers = [[], [], []]
    for (var i = 0; i < catalog.length; i++) {
        var tier = 0
        for (var t = 0; t < terms.length; t++) {
            var earned = termTier(i, terms[t], text, beyond[t])
            if (earned === 0) { tier = 0; break }
            if (earned > tier) tier = earned
        }
        if (tier > 0) tiers[tier - 1].push(i)
    }
    var found = tiers[0].concat(tiers[1], tiers[2])
    var count = limit > 0 ? Math.min(limit, found.length) : found.length
    var results = []
    for (var n = 0; n < count; n++) results.push(catalog[found[n]])
    return results
}
"""


def js(text):
    return json.dumps(text, ensure_ascii=False)


# The marketplace's static scanner refuses a source file over 512 KiB and
# the whole catalogue is nearly twice that, so the entry data is written as
# numbered part files well under the limit (each a library exporting its
# slice of `catalog`, in order) and EmojiCatalog.js assembles them and
# keeps the accessors and the search. Absolute indexes (base/variants)
# survive concatenation untouched.
PART_BUDGET = 400 * 1024
PART_STEM = "EmojiCatalogData"


def entry_line(entry, last):
    parts = [
        f"emoji: {js(entry['emoji'])}",
        f"name: {js(entry['name'])}",
        f"keywords: [{', '.join(js(word) for word in entry['keywords'])}]",
        f"ru: [{', '.join(js(word) for word in entry['ru'])}]",
        f"uk: [{', '.join(js(word) for word in entry['uk'])}]",
        f"group: {js(entry['group'])}",
        f"base: {entry['base']}",
        f"variants: [{', '.join(str(v) for v in entry['variants'])}]",
    ]
    return "    { " + ", ".join(parts) + " }" + ("" if last else ",")


def emit_parts(entries):
    """The part files' texts, in order: [(filename, bytes), ...]."""
    parts = []
    current = []
    size = 0
    for index, entry in enumerate(entries):
        line = entry_line(entry, False)
        if current and size + len(line.encode("utf-8")) > PART_BUDGET:
            parts.append(current)
            current, size = [], 0
        current.append(line)
        size += len(line.encode("utf-8")) + 1
    if current:
        parts.append(current)
    out = []
    for number, lines in enumerate(parts, 1):
        lines = list(lines)
        lines[-1] = lines[-1].rstrip(",")
        text = "\n".join([
            ".pragma library",
            "",
            f"// Generated by tools/emoji/generate.py — part {number} of {len(parts)} of the",
            "// emoji catalogue's entries, in order; EmojiCatalog.js concatenates the",
            "// parts. Split so no source file exceeds what a static scanner reads.",
            "",
            "var catalog = [",
            *lines,
            "]",
            "",
        ])
        out.append((f"{PART_STEM}{number}.js", text.encode("utf-8")))
    return out


def emit(entries, groups, part_names):
    """The module text: the parts assembled, then the accessors and search."""
    lines = [HEADER.rstrip("\n"), ""]
    for number, _ in enumerate(part_names, 1):
        lines.append(f'.import "{PART_STEM}{number}.js" as Part{number}')
    lines += ["", "var catalog = " + ".concat(".join(
        [f"Part1.catalog"] + [f"Part{n}.catalog" for n in range(2, len(part_names) + 1)])
        + ")" * (len(part_names) - 1), "", "var groupNames = ["]
    for index, group in enumerate(groups):
        lines.append(f"    {js(group)}" + ("," if index + 1 < len(groups) else ""))
    lines += ["]", "", "function entries() { return catalog }", "",
              "function groups() { return groupNames }", SEARCH]
    return "\n".join(lines).encode("utf-8")


def build():
    verify_checksums()
    kept = parse_emoji_test()
    ann_names, ann_keywords = parse_annotations("cldr46-annotations-en.xml")
    # tts names are read past for ru/uk: only the keyword maps are kept.
    _, ru_keywords = parse_annotations("cldr46-annotations-ru.xml")
    _, uk_keywords = parse_annotations("cldr46-annotations-uk.xml")
    der_names, _ = parse_annotations("cldr46-annotations-derived-en.xml")
    bases, variants = split_variants(kept)
    resolved = resolve_names(kept, bases, variants, ann_names, ann_keywords,
                             der_names, ru_keywords, uk_keywords)
    ordered = order_entries(kept, variants)

    index_of = {sequence: index for index, sequence in enumerate(ordered)}
    # Base lookup is FE0F-normalized, matching split_variants: the toned
    # 26F9 1F3FB links to the entry kept as 26F9 FE0F.
    base_index_of = {strip_fe0f(sequence): index for index, sequence in enumerate(ordered)}
    group_of = {sequence: group for sequence, group, _ in kept}
    entries = []
    for sequence in ordered:
        name, keywords, ru, uk = resolved[sequence]
        stripped = strip_trailing_tones(sequence)
        # A base strips to itself; only a genuine reduction that lands on
        # a kept entry names a base — two-tone families strip to a
        # sequence that is not RGI and stay bases.
        base = -1
        if stripped != sequence:
            base = base_index_of.get(strip_fe0f(stripped), -1)
        entries.append({
            "emoji": "".join(chr(cp) for cp in sequence),
            "name": name,
            "keywords": keywords,
            "ru": ru,
            "uk": uk,
            "group": group_of[sequence],
            "base": base,
            "variants": [index_of[v] for v in variants.get(sequence, [])],
        })
    groups = []
    for entry in entries:
        if entry["group"] not in groups:
            groups.append(entry["group"])
    return entries, groups


def strip_trailing_tones(sequence):
    stripped = list(sequence)
    while stripped and TONE_MIN <= stripped[-1] <= TONE_MAX:
        stripped.pop()
    return tuple(stripped)


def main():
    entries, groups = build()
    parts = emit_parts(entries)
    # Stale parts from an earlier, larger split must not linger as
    # runtime files nobody imports.
    for old in sorted(ROOT.glob(f"{PART_STEM}*.js")):
        old.unlink()
    for name, data in parts:
        (ROOT / name).write_bytes(data)
    OUT.write_bytes(emit(entries, groups, [name for name, _ in parts]))
    variant_count = sum(1 for entry in entries if entry["base"] >= 0)
    print(f"EmojiCatalog.js: {len(entries)} entries "
          f"({len(entries) - variant_count} bases, {variant_count} variants), "
          f"{len(groups)} groups, {OUT.stat().st_size} bytes + "
          + ", ".join(f"{name} {len(data)} bytes" for name, data in parts))


if __name__ == "__main__":
    main()
