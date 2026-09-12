#!/usr/bin/env python3
"""Builds the levels-5-8 probe keymap (ticket 20, first task).

Takes the stock `us` layout as a source file (probe.xkb, via includes),
retypes AD01..AD10 and AE01 onto an eight-level type whose levels 5-8 are
distinct printable characters — level 5 carries the ten real &123 page
glyphs — and compiles it to the serialized text the helper's `kb_file`
expects. Levels 1-4 of every patched position keep their stock characters:
for the letter keys levels 3 and 4 are filled with the stock level-1 and
level-2 pair, which reproduces exactly what a TWO_LEVEL key does when a
level-3 modifier is held (it falls back to level 1).

Verification is the same two-step trust the helper applies: the source
compiles (xkbcli --from-xkb), and the serialized output compiles again
(xkbcli --keymap --test) before anything is handed to a helper.
"""

import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent

# position -> (levels 1..4 stock, level 5..8 keysyms).
# Level 5 of AD01..AD10 is the ten glyphs the &123 page actually draws.
PATCHES = {
    "AD01": (["q", "Q"], ["sterling", "exclamdown", "aacute", "acircumflex"]),
    "AD02": (["w", "W"], ["EuroSign", "questiondown", "eacute", "ecircumflex"]),
    "AD03": (["e", "E"], ["yen", "copyright", "iacute", "icircumflex"]),
    "AD04": (["r", "R"], ["cent", "registered", "oacute", "ocircumflex"]),
    "AD05": (["t", "T"], ["degree", "mu", "uacute", "ucircumflex"]),
    "AD06": (["y", "Y"], ["plusminus", "onehalf", "ntilde", "agrave"]),
    "AD07": (["u", "U"], ["multiply", "onequarter", "ccedilla", "egrave"]),
    "AD08": (["i", "I"], ["U2248", "threequarters", "odiaeresis", "igrave"]),
    "AD09": (["o", "O"], ["division", "onesuperior", "udiaeresis", "ograve"]),
    "AD10": (["p", "P"], ["notequal", "twosuperior", "aring", "ugrave"]),
    "AE01": (["1", "exclam"], ["currency", "brokenbar", "section", "diaeresis"]),
}

# The ten page glyphs, as the panel draws them — used only for the report.
PAGE_GLYPHS = "£€¥¢°±×≈÷≠"

TYPE_BLOCK = """\
    type "OSK8" {
        modifiers = Shift+LevelThree+LevelFive;
        map[None] = Level1;
        map[Shift] = Level2;
        map[LevelThree] = Level3;
        map[Shift+LevelThree] = Level4;
        map[LevelFive] = Level5;
        map[Shift+LevelFive] = Level6;
        map[LevelFive+LevelThree] = Level7;
        map[Shift+LevelFive+LevelThree] = Level8;
    };\
"""


def key_statement(position, stock, extra):
    one, two = stock
    l1, l2, l3, l4 = one, two, one, two
    syms = ", ".join([l1, l2, l3, l4, *extra])
    return f'    key <{position}> {{ type = "OSK8", symbols[Group1] = [ {syms} ] }};'


def main():
    patches = "\n".join(key_statement(pos, stock, extra) for pos, (stock, extra) in PATCHES.items())
    source = f"""xkb_keymap {{
    xkb_keycodes {{ include "evdev" }};
    xkb_types {{
        include "complete"
{TYPE_BLOCK}
    }};
    xkb_compat {{ include "complete" }};
    xkb_symbols {{
        include "pc+us+inet(evdev)"
{patches}
    }};
    xkb_geometry {{ include "pc(pc105)" }};
}};
"""
    xkb_path = HERE / "probe.xkb"
    keymap_path = HERE / "lvl5-probe.keymap"
    xkb_path.write_text(source, encoding="utf-8")

    def run(cmd, **kw):
        proc = subprocess.run(cmd, capture_output=True, text=True, **kw)
        if proc.returncode != 0:
            sys.exit(f"{' '.join(cmd)} failed:\n{proc.stdout}\n{proc.stderr}")
        return proc.stdout

    # Source -> serialized text; the serialized text must compile again.
    text = run(["xkbcli", "compile-keymap", "--from-xkb", str(xkb_path)])
    keymap_path.write_text(text, encoding="utf-8")
    run(["xkbcli", "compile-keymap", "--keymap", str(keymap_path), "--test"])

    for needle in ("OSK8", "ISO_Level5_Shift", "modifier_map Mod3 { <LVL5> }"):
        if needle not in text:
            sys.exit(f"compiled text is missing {needle!r}")
    print(f"ok: {keymap_path} ({len(text.splitlines())} lines, {len(PATCHES)} positions retyped)")
    print(f"page glyphs on level 5 of AD01..AD10: {PAGE_GLYPHS}")


if __name__ == "__main__":
    main()
