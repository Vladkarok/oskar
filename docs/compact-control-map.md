# Compact control map — the accepted five-row packing

Written 2026-09-06 as a four-row proposal; rewritten 2026-09-07 after the
owner's accepted map (ticket 11 Comments). This is the design deliverable
ticket 12 implements. It is not a shorter keyboard. Baseline: installed
plugin build with `Keyboard.qml` / `KeyboardLayout.js` row tables unchanged
by this ticket; measured against the five Windows reference screenshots in
`.scratch/next-iteration/references/`.

## 1. The decision this ticket settles

**This release keeps today's five-row letters page as the maintained
default.** No persisted arrangement setting. A four-row compact arrangement
is future work, not this release.

The owner's accepted map (2026-09-07):

- Digits stay a dedicated row on the five-row letters page (choice 1.B).
  An ordinary click on a digit cap types that digit. No merged digit/letter
  caps.
- `&123` keeps today's dual caps. Extra curated specials that live at
  keymap level 3/4 of alphanumeric-block positions become **pair caps** on
  that same page: stacked, Shift picks the upper half, press is
  AltGr+position (non-exact). Decisions §17 holds: no clipboard, IME, or
  keymap replacement to type a symbol.
- Fill the current 8-unit spacer on symbols row 3 first. If that is not
  enough slots, use the remaining five-row height (symbols today has four
  rows; letters already pin five) for more pair slots. No second symbols
  page unless that recount still overflows.
- Command row, Fn-in-place, header, and the current-content paste control
  are unchanged.
- Pair caps fill only where compiled RALT is a real `ISO_Level3_Shift`
  (the owner's `us` group is not).

Height saving this release: **zero**. The four-row prototype in
`.scratch/next-iteration/evidence/11/` remains on disk as the future
option's measurements; it is not the accepted map.

## 2. Pair-slot capacity (the recount)

Every row stays on the shared 15.5-unit half-unit lattice (decisions §22).
Key size and scale do not change. `maxPageRows` stays 5 (letters already
pin it). Adding pair caps must not raise panel or docked exclusive-zone
height.

### 2.1 Today's symbols page

| Row | Content | Units |
|---|---|---|
| 1 | `esc` 1.0 + 13 dual caps (TLDE, AE01–AE12) + `⌫` 1.5 | 15.5 |
| 2 | `Tab` 1.5 + 8 dual caps (AD11, AD12, BKSL, AC10, AC11, AB08–AB10) + `Del` `Home` `End` `Ins` at 1.5 each | 15.5 |
| 3 | `⇧` 2.5 + **spacer 8.0** + `PgUp` 1.0 + `PgDn` 1.0 + `↑` 1.0 + `Enter` 2.0 | 15.5 |
| 4 | Command row, unchanged | 15.5 |

Letters has five rows, so one row of height is already reserved and unused
on `&123`. The 8-unit spacer is the first pair-slot budget: eight unit
caps replace it and keep the 12.5-units-left-of-`↑` invariant
(2.5 + 8 + 1 + 1 = 12.5), so `↑` still sits above `↓`.

Eight slots are not enough: ua needs 12 pair caps. The remaining height
is one extra symbols row, inserted as row 3 (whole-unit lattice, matching
letters' Caps row) so today's Shift…Enter row becomes row 4 (half-unit,
matching letters' Shift row). That extra row is the curated page's free
row shape: 15 unit slots + a 0.5 pad = 15.5.

| Packing | Pair slots |
|---|---|
| 8-unit spacer filled | 8 |
| Extra five-row-height row, when more than 8 pair caps are needed | +15 |
| **Capacity when the extra row is present** | **23** |

The extra row is omitted when it would contain only spacers (the owner's
`us` group). Omitting it does not resize the panel: slack stays at the
top of `&123`, as today. A per-group symbols row count that stays ≤ 5
does not break decisions §22's pinned ordinary-page height.

### 2.2 Demand versus 23 slots

Same inventory and first-occurrence rule as the 2026-09-06 probe
(`.scratch/next-iteration/evidence/11/fit-calculate.py` over
`inventory-*.tsv`). Pair-cap **counts** do not change; only the slot
budget does. The old overflow numbers (ua exact 12/12, fr/gb/de over by
4/7/9) were the four-row twelve-slot budget.

| Layout | Pair caps needed | vs 8 (spacer only) | vs 23 (spacer + extra row) |
|---|---|---|---|
| `us` (group 1, owner RMLVO) | 0 (three curated tokens sit on off-grid media positions; RALT is not `ISO_Level3_Shift`) | fits; extra row omitted | — |
| `ua` (group 2, owner RMLVO) | 12 | overflow by 4 → extra row | **12/23 fits** |
| `fr` | 16 | overflow by 8 → extra row | **16/23 fits** |
| `gb` | 19 | overflow by 11 → extra row | **19/23 fits** |
| `de` | 21 | overflow by 13 → extra row | **21/23 fits** |

No probed layout overflows 23. **No second symbols page this release.**
The curated page remains specified as an overflow valve if some unprobed
keymap exceeds 23; it is not opened for `us`/`ua`/`fr`/`gb`/`de`.

Itemized ua 12 positions (unchanged): AB03, AB06, AB08, AB09, AB10, AD04,
AE02, AE03, AE04, AE05, AE11, AE12. Fill rule in §3.2.

## 3. The accepted map

### 3.1 Main letters page — five rows, as today

| Row | Caps (widths in units) |
|---|---|
| 1 | `esc` (1.0), `` ` ``, digit row AE01–AE12 (`1`–`=`), `⌫` (1.5) |
| 2 | `Tab` (1.5), q–p row + `[` `]` `\`, `Del` (1.0) |
| 3 | `Caps Lock` (2.0), a–l row + `;` `'`, `Enter` (2.5) |
| 4 | `⇧` (2.5), z–m row + `,` `.` `/`, `↑` (1.0), `⇧` (2.0) |
| 5 | Command row (§3.4), unchanged |

- The digit row is a row. Ordinary click = the digit (or that position's
  unshifted keymap level). Shift still selects the upper dual of the same
  cap, as today. No secondary digit legend, no midline split, no merged
  AD/AE caps.
- AD11/AD12/BKSL stay letter-row positions: on `ua` they are `х ї ґ`;
  TLDE on `ua` stays the orthographic apostrophe on row 1. Nothing moves
  to `&123` by glyph.
- Tab, Del, esc, Caps, both Shifts, Enter, ↑ stay where they are.

### 3.2 Symbols page (`&123`) — duals kept, pair caps added

**When the extra row is omitted** (need ≤ 8 pair caps; `us`):

| Row | Caps |
|---|---|
| 1 | `esc` (1.0), 13 dual caps (TLDE, AE01–AE12), `⌫` (1.5) — today's row 1 |
| 2 | `Tab` (1.5), 8 dual caps, `Del` `Home` `End` `Ins` at 1.5 — today's row 2 |
| 3 | `⇧` (2.5), **eight pair slots** (the former 8-unit spacer), `PgUp` `PgDn` `↑`, `Enter` (2.0) |
| 4 | Command row, unchanged |

**When the extra row is present** (need > 8; `ua`/`fr`/`gb`/`de`):

| Row | Caps |
|---|---|
| 1 | duals, as above |
| 2 | duals + nav, as above |
| 3 | 15 pair slots (1.0) + 0.5 pad — whole-unit lattice |
| 4 | `⇧` (2.5), eight pair slots, `PgUp` `PgDn` `↑`, `Enter` (2.0) — half-unit lattice |
| 5 | Command row, unchanged |

- Rows 1–2's dual caps are production's, unchanged. Digits type from row 1
  without leaving the page, as today. `esc`, Tab, Del, Ins, Home, End,
  PgUp, PgDn, ↑, Enter stay.
- **Pair caps:** one position's level 3 as the base (lower half) and
  level 4 as the Shift layer (upper half), stacked with the same
  Shift-swapped emphasis as a dual cap. A press is AltGr+position, with
  a latched or locked Shift selecting level 4. Shape:
  `letter: false, shift: latch-applied, altgr: intrinsic, exact: false`.
  The chord is the keymap's own (decisions §17). Displayed and typed
  levels agree, so the R3 class does not apply.
- **Fill rule:** slots fill in curated-token category order. The first
  occurrence of each curated token that lives at level ≥ 3 of an
  alphanumeric-block position claims that position; one position claims
  one slot hosting both its AltGr levels. Non-curated AltGr glyphs stay
  unexposed (on `ua`: `•`, `¹`, combining acute; ASCII brackets on AltGr
  at AE09–AE10), as today's curated page leaves them. Packing uses the
  spacer's eight slots first, then the extra row — that is why the extra
  row exists, not a second page. Unfilled slots are declared spacers.
- **RALT gate:** a pair cap presses RALT; it fills only for groups whose
  compiled RALT is `ISO_Level3_Shift`. On the owner's `us` group,
  `grp:alt_shift_toggle` binds Alt_R with `ISO_Next_Group` on its second
  level — a pair cap there would switch layouts mid-chord (finding R1).
  Ticket 05's helper-side chord facts own this gate; until a group passes
  it, its pair slots stay spacers. Remapped German
  (`lv3:ralt_alt,lv3:menu_switch`) fails the same gate and must not emit
  Alt+position. Plain `us` has nothing to expose anyway (§2.2).
- `us` therefore shows today's duals, eight spacer slots on row 3, and no
  extra row. `ua` shows eight pair caps on the Shift row and four on the
  extra row (eleven leftover spacers + 0.5 pad). That sparse extra row is
  accepted packing, judged in ticket 12's pointer-feel pass.

### 3.3 Fn layer — unchanged

Fn stays a session-only semantic toggle in the command row, replacing the
top row in place on either page, never changing panel height
(spec-v1.1 §1). The Fn row remains `esc` `` ` `` `F1`–`F12` `⌫` at today's
widths. Ins stays on symbols row 2. Because the letters top row is still
the digit row, Fn-on hides digits, not letters.

### 3.4 Command row — unchanged

`Ctrl Fn Super Alt ☺ Space(4.5) AltGr Ctrl ← ↓ → &123`, identical on both
pages but for the page key's label. Without page 2 (`us` today; `ua`/`fr`/
`gb`/`de` under this map) the symbols page key is `ABC` and returns to
letters, as production already does when the curated page is hidden. The
command row's contract (decisions §22: same caps, same widths, same place
on both pages, 12.5 units left of the arrow column) is untouched. The ☺
cap keeps its picker semantics (v1.1 §1); the language switch stays a
header control.

### 3.5 Header, page controls, clipboard place

Gear, language, mode, size and Close are header controls and unchanged.
The top-centre clipboard place is the current-content paste control from
ticket 14, now in this release; no inert placeholder and no history.
The page key keeps the bottom-right slot and immediate
click semantics; page changes still resize nothing, consume no latches,
and never touch the group or keymap.

### 3.6 Curated page (page 2) — overflow only

Pair caps carry the special-symbol inventory for every probed layout, so
page 2 is not opened for `us`/`ua`/`fr`/`gb`/`de`. It remains the overflow
valve if some keymap needs more than 23 pair caps:

- **Content:** exactly the tokens the pair slots could not host.
- **Rows:** the `⇧ … Enter` row always renders (spec-v1 §5; ticket 03).
- **Threshold:** still eight available curated symbols, and only when
  pair-slot capacity is exceeded. The eight-symbol rule alone must not
  reopen the page on `ua` (17 carried tokens, 12 pair caps, fits).

## 4. Height — zero this release

Unchanged key size, five rows, `maxPageRows` stays 5. Production
`Keyboard.implicitHeight` at forced preset scale (evidence/11, current
grid): **219 / 262 / 318.75** logical px at M/L/XL. This map does not
change those numbers. Docked reservation stays the current visible
height (decisions §21).

The four-row prototype saved exactly one row pitch (45 / 53.8 / 65.55)
and is recorded in evidence/11 as the future compact option, not as a
this-release claim.

## 5. What ticket 12 must implement from this map

1. Letters page, command row, Fn row, header, and paste: **no change**.
2. Pair caps (§3.2): draw L3/L4 stacked with Shift-swapped emphasis;
   press AltGr+position with `letter: false, shift: latch-applied,
   altgr: intrinsic, exact: false`; spacers when unresolved or gated.
   The RALT gate (`ISO_Level3_Shift` check) from ticket 05's helper facts.
3. Replace symbols row 3's 8-unit spacer with eight pair slots; keep
   Shift, PgUp, PgDn, ↑, Enter and the 12.5-unit ↑/↓ invariant.
4. When a group needs more than eight pair caps, insert the extra
   whole-unit pair row (15 × 1.0 + 0.5 pad) as symbols row 3 so the
   Shift row becomes row 4. Omit that row when it would be all spacers.
   Do not raise `maxPageRows` above 5.
5. Do not open the curated page for layouts that fit; keep it as the
   overflow valve (§3.6) with ticket 03's Shift/Enter survival.
6. Do **not** implement merged digit caps, four-row letters, Del/⌫
   narrowing, esc/↑ leaving symbols, or Ins moving to Fn.
7. Verify typed pair-cap output for `ua` (and `fr` if exercised), the
   `us` RALT gate (slots stay spacers; no layout switch mid-chord),
   unchanged five-row height at M/L/XL, and owner pointer-feel on the
   sparse `ua` extra row.

Spec/decision text for this packing is updated with this ticket
(spec-v1.1 §1/§3/§9, decisions §28). Ticket 12 must not reintroduce a
this-release four-row requirement.

## 6. Closed by the owner's 2026-09-07 map

- Digits: dedicated row, ordinary click = digit. Merged caps rejected.
- Four-row compact: future, not this release. Height saving zero.
- `esc` and `↑` stay on `&123`. No Del/⌫ narrowing.
- Fn auto-revert: not needed (Fn still hides only the digit row).
- `fr`/`gb`/`de`: no overflow page; 16/19/21 all fit in 23.
- No persisted arrangement setting.
