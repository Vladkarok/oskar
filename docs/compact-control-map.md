# Compact control map — the four-row arrangement proposal

Written 2026-09-06 for [the next-iteration board's ticket 11]
(../.scratch/next-iteration/issues/11-compact-control-map.md); revised the
same day after two independent review rounds (verdicts in the ticket
Comments). This is a design deliverable, not a shipped behaviour: ticket 12
implements the map the owner accepts here. Baseline: installed plugin build
with `Keyboard.qml`, `KeyboardLayout.js`, `Theme.qml`, `Config.js`,
`ModifierReducer.js` byte-identical to `7bbd74c5`; measured against the five
Windows reference screenshots in `.scratch/next-iteration/references/`.

## 1. The decision this ticket settles

**Recommendation: the compact arrangement below becomes the maintained
default for this release.** No persisted setting is added: per CONTEXT.md's
roles this is a maintainer default changing in a later release, not a user
choice, and nothing else in the release reads a persisted arrangement flag.

The owner's direction (ticket 11 Comments, 2026-09-06) wants the compact
direction with two amendments to the Windows reference: digits visible on
the main letters page with no extra click, and special symbols fitting on
one symbols page using Shift for overflow where the arithmetic allows. One
fact frames the first amendment: **the Windows reference already shows
small digit legends on the q–p caps** — the owner amended a design that
hides digits behind an undisclosed gesture. The merged caps of §3.1 are
that legend made clickable: digits visible on the main letters page,
exactly one click, ordinary click unchanged. What the compact page cannot
hold is a *dedicated digit row*: the unit arithmetic (§2.1) admits no
four-row letters page with a digit row plus 26 letters plus the
ordinary-page commands. The two clauses of the owner's direction therefore
resolve differently, and both are recorded honestly:

- **Symbols: fits.** On the owner's layouts (`us`, `ua`) the complete
  special-symbol inventory fits one symbols window plus its Shift layer
  (§4). For `fr`, `gb` and `de` it does not; for those layouts the
  existing curated page survives as a conditional overflow page that never
  adds height (§4.3).
- **Digits as a dedicated row: does not fit a four-row page.** The map
  merges the number row into the top letter row as stacked, directly
  clickable caps (§3.1). If the owner reads the amendment literally as "a
  digit row", the alternative is the current five-row page with zero
  height saving (§2.3); that alternative is recorded rather than forced.

## 2. The row arithmetic

Every row is declared to the shared 15.5-unit grid (decisions §22); row
count is the only height variable. Common row pitch and unchanged key size
mean: `keyHeight = space(42) × presetScale`, `gap = round(spacingMd ×
presetScale)`, both untouched by this design.

### 2.1 Why a digit row and four rows are irreconcilable

A four-row letters page offers 4 × 15.5 = 62 units. The minimum a letters
page must host at unchanged key size, itemised:

| content | units |
|---|---|
| digit row as a row: `esc` 1.0 + ten digit positions 10 + row-end `⌫` 1.5 | 12.5 |
| 26 letters (26 unit positions minimum; `ua` needs 34 — its rows carry letters through AD11, AD12, BKSL, AC01–11, AB01–09) | 26 |
| `Tab` | 1.5 |
| `Caps Lock` | 2.0 |
| two `⇧` | 4.5 |
| `Enter` | 2.5 |
| `↑` | 1.0 |
| command row (§3.4, unchanged) | 15.5 |
| **total** | **65.5** |

65.5 > 62: deficit 3.5 units before any punctuation (`- = [ ] \ `` ` ``),
`Del`, or the arrows beyond ↑ find a home. **A dedicated digit row plus the
letters plus ordinary-page commands cannot fit 62 units.** A five-row
letters page (today) is the only arrangement that keeps a digit row.

### 2.2 Positions whose glyphs differ per layout never move by page

The compact top row keeps every alphanumeric-block position on the letters
page — as lower halves where a digit pair does not fill the slot. On `us`
the positions AD11/AD12/BKSL are `[ ] \`; on `ua` they are the letters
`х ї ґ` (compiled keymap: `AD11 = Cyrillic_ha`, `AD12 = Ukrainian_yi`,
`BKSL = Ukrainian_ghe_with_upturn`). On `ua` TLDE level 1 is the
orthographic apostrophe (п'ять, ім'я) — not punctuation to file on a
symbols page. The top row therefore merges them too (§3.1): every layout
keeps `- = ` and the grave/apostrophe at one click, and no layout loses
letters. The same rule is why `; '` stay on row 2 (on `ua`, AC10/AC11 are
ж є) and why `, . /` stay on row 3 (on `ua`, AB10 is `.`).

### 2.3 The alternative recorded, not chosen

Keeping today's five-row letters page (digit row intact as a row) with the
compact symbols page of §4 applied yields a complete, working keyboard at
**zero height saving**. It honours a literal reading of the digits
amendment and is available to the owner as a one-line rejection of §3.1.
It is not the recommendation, because it fails the ticket's own goal
("saves one row of height") and the plan's target ("one existing row pitch
of reduction"). Note this alternative is all-or-nothing across groups: one
keymap holds every layout, so a per-group row count would resize the panel
on every language switch and break decisions §22's fixed ordinary-page
height.

## 3. The accepted map (proposal)

### 3.1 Main letters page — four rows

| Row | Caps (widths in units) |
|---|---|
| 1 | `esc` (1.5), **merged caps** (13 × 1.0): `[1/й][2/ц][3/у][4/к][5/е][6/н][7/г][8/ш][9/щ][0/з]` on `us` `[1/q]…[0/p]`, then `[-/х][=/ї]['/ґ]` — on `us` `[-/[][=/]][`/\]`; `⌫` (1.0) |
| 2 | `Caps Lock` (2.0), a–l row (9 × 1.0), `; :` ` ' "` (2 × 1.0), `Enter` (2.5) — today's row 3, unchanged |
| 3 | `⇧` (2.5), z–m row + `,` `.` `/` (10 × 1.0), `↑` (1.0), `⇧` (2.0) — today's row 4, unchanged |
| 4 | Command row (§3.4), unchanged |

Merged cap semantics (the demonstrated mouse action of ticket AC 4):

- Each merged cap is two stacked positions: upper half = the number-row
  position (AE01–AE12, TLDE), lower half = the letter position
  (AD01–AD12, BKSL). Each half draws exactly ONE glyph — the level Shift
  (and Caps, for the letter half) would type — from the compiled keymap,
  never three glyphs in one cap. The upper half draws at the small glyph
  size and dim when Shift is inactive, the lower at full size.
- The press splits at the cap's drawn midline: upper half presses the
  upper position (+held modifiers), lower half the lower position. The
  digit half and the AE11/AE12/TLDE halves carry `letter: false` (Caps
  never moves them); the letter half keeps the ordinary letter semantics.
  An ordinary click in the lower half — the majority of the cap — means
  the letter, always.
- **Distinct affordance (review round 1):** the digit half must not read
  as a Shift legend (a symbols-page dual cap's top half clicks its own
  position's shifted level; a merged cap's top half clicks a different
  position). Ticket 12 draws merged caps with a hairline divider at the
  split — dual caps have none — and the settled split ratio is **40 % top
  / 60 % bottom**, not the visual 50 %, so the letter target keeps the
  larger share. The prototype renders the halves without the divider;
  the ratio and divider are spec'd here and judged by the owner's
  pointer-feel pass in ticket 12.
- Built-in fallbacks: merged caps ship with the US `t`/`s` pairs behind
  both halves so a keycap-pipeline failure draws the fallback and raises
  the §11 log instead of a silent blank (spec-v1.1 §3).
- Stagger: esc widens to 1.5 and the row-end `⌫` narrows to 1.0 so row 1
  lands on the half lattice and the production row 1/2 gap-line
  alternation survives (decisions §22). The `⌫` narrowing is
  owner-vetoable (§7); the alternative is a whole-lattice row 1 whose gap
  lines coincide with row 2's.

Destinations of what leaves the letters page:

| Control | Today | Compact destination |
|---|---|---|
| Digit row as a row | letters row 1 | §3.1 merged caps (one click, no page change; the Windows reference's digit legends, made clickable) |
| Tab | letters row 2 leading | symbols page row 2 leading (its other current home; row 1 is full at esc 1.5 + 13 merged + ⌫ 1.0) |
| Del | letters row 2 end, symbols row 2 | symbols page row 2 only, narrowed 1.5 → 1.0 to fund a pair slot (owner-vetoable; matches the Windows reference, where letters carry no Del) |
| ↑ on symbols row 3 | symbols page | letters row 3 (unchanged there); one `&123` press away from symbols |
| `Ins` | symbols row 2 | Fn row (§3.3), replacing `` ` `` |

The command row is **untouched** — both Ctrls stay. Removing the second
Ctrl is not on the table: the 12.5-units-left-of-`↓` invariant
(decisions §22) fixes the arrow positions, and a latch survives a page
switch anyway, so the second Ctrl costs nothing and moving anything else
would break the stagger.

### 3.2 Symbols page (`&123`) — three content rows

| Row | Caps |
|---|---|
| 1 | 13 dual caps (TLDE, AE01–AE12; `1!` `2@` … stacked as today), one pair slot, `⌫` (1.5) |
| 2 | `Tab` (1.5), 8 dual caps (AD11, AD12, BKSL, AC10, AC11, AB08–AB10), `Del` (1.0), `Home` (1.5), `End` (1.5), two pair slots |
| 3 | `⇧` (2.5), `PgUp` (1.0), `PgDn` (1.0), nine pair slots, `Enter` (2.0) |
| 4 | Command row, unchanged |

- Rows 1–2's dual caps are production's, unchanged. Digits type from row 1
  without leaving the page, as today.
- **Pair caps** are the Shift-layer overflow the owner asked for: a pair
  cap draws one position's level 3 as its base and level 4 as its Shift
  layer (the same stacked, Shift-swapped emphasis as every dual cap), and
  presses AltGr+position — with a latched or locked Shift deciding level
  4. The chord is the keymap's own (decisions §17's boundary holds: no
  clipboard, no IME, no keymap replacement). Because the press is
  non-exact and the cap draws exactly the level Shift would pick, the
  displayed and typed levels agree — the R3 class is resolved by
  construction, not moved.
- **Fill rule (stated, per review):** slots fill in the curated category
  order — the first occurrence of each curated token that lives at level
  ≥ 3 of an alphanumeric-block position claims that position, and one
  position claims one slot hosting both its AltGr levels. The inventory is
  the curated palette (39 tokens), not every keymap level: on `ua` the
  non-curated AltGr glyphs (`•`, `¹`, the combining acute) stay unexposed,
  exactly as today's curated page leaves them. Consequence, recorded: on
  `ua` the ASCII brackets on AltGr (`[{` `]}` `\|` at AE09–AE10) remain
  unexposed — as today.
- **RALT gate (R1 stays attached):** a pair cap presses RALT for its
  chord; it fills a slot only for groups whose compiled RALT is a real
  level-3 modifier (`ISO_Level3_Shift`). On the owner's `us` group,
  `grp:alt_shift_toggle` binds Alt_R with `ISO_Next_Group` on its second
  level — a pair cap there would switch layouts mid-chord, the exact R1
  mechanism. Ticket
  05's helper-side chord facts own this gate; until a group passes it, its
  pair slots stay spacers. On plain `us` there is nothing to expose
  anyway (§4).
- Slots the active keymap cannot fill are declared spacers (the curated
  page's existing rule).
- `esc` leaves the symbols page: it stays on the letters page's row 1 and
  the Fn row (one `&123` press away). Recorded trade (Windows' symbols
  pages keep an Esc); owner-vetoable — but see §7: a veto costs `ua` its
  exact fit and would need the second row-2 slot back.

### 3.3 Fn layer — unchanged mechanism, one cap different

Fn stays a session-only semantic toggle in the command row, replacing the
top row in place on either page, never changing panel height
(spec-v1.1 §1). The Fn row becomes `esc Ins F1–F12 ⌫` at the compact row
widths — `esc` 1.5 and `⌫` 1.0, matching letters row 1 so the toggle does
not resize caps or shift the stagger: 1.5 + 1.0 + 12 + 1.0 = 15.5. `Ins`
moves here from symbols row 2, and `` ` `` leaves the row (its upper half
lives on letters row 1, its dual on symbols row 1).

Named consequence: on the compact letters page the replaced top row is the
letter row (plus digits), so Fn on hides thirteen letters until toggled
back — today it hides only the digit row. Spec-compliant but semantically
heavier; §7 offers the owner an auto-revert (Fn falls back after the next
F-key press) as an option. Spec-v1 §4's Fn wording ("off shows the page's
ordinary top row") needs the grave→Ins update recorded with ticket 12.

### 3.4 Command row — untouched

`Ctrl Fn Super Alt ☺ Space(4.5) AltGr Ctrl ← ↓ → &123`, identical on both
pages but for the page key's label (`&123` / `ABC`; the curated page, when
present, labels it `ABC`). The command row's contract (decisions §22:
same caps, same widths, same place on both pages, 12.5 units left of the
arrow column) survives the compact change untouched. The ☺ cap keeps its
picker semantics (v1.1 §1); the language switch stays a header control.

### 3.5 Header, page controls, clipboard place

Gear, language, mode, size and Close are header controls and unchanged.
The top-centre clipboard place stays reserved and empty for ticket 14 —
no inert button. The page key keeps the bottom-right slot and immediate
click semantics; page changes still resize nothing, consume no latches,
and never touch the group or keymap.

### 3.6 Curated page (page 2) — removed on `us`/`ua`, conditional elsewhere

With the pair caps carrying the special-symbol inventory, the curated page
has nothing to add on `us` and `ua` and disappears there — and with it the
R1/R2 curated-cap display classes for those layouts (R3 is resolved by the
pair caps themselves, §3.2). For layouts whose inventory exceeds the
twelve pair slots (§4.2), the existing curated page survives as the
overflow valve, with two amendments so it cannot regress:

- **Content:** exactly the tokens the pair slots could not host — not a
  repeat of the full palette.
- **Rows:** the `⇧ … Enter` row always renders (a locked Shift must keep
  its visible control across the page switch — spec-v1 §5 — and a symbols
  page without Enter strands the user), so an overflow of a few caps
  cannot re-trigger R2's vanish-a-row behaviour. Its three content rows
  plus command row (4 total) fit the compact pin exactly: the overflow
  page never adds height.

## 4. The symbols fit calculation

Delegated to this ticket by the owner. Pipeline: the panel's own keycap
path — `xkbcli compile-keymap` over each RMLVO, the production awk record
shape, first-occurrence token resolution. Rule: a token already carried at
levels 1/2 of the alphanumeric block is one click on an ordinary page; a
token first occurring off the block cannot be drawn at all; the rest need
pair caps, one per position. The committed script is
`.scratch/next-iteration/evidence/11/fit-calculate.py` over
`inventory-*.tsv` (regenerate with `probe-inventory.sh`); counts depend on
the first-occurrence rule and are itemised in `fit-calculation.txt`.

| Layout | Curated tokens carried | Already one click (block L1/L2) | Glyphs needing caps | Pair caps after same-position L3/L4 pairing | Verdict vs 12 pair slots |
|---|---|---|---|---|---|
| `us` (group 1, owner RMLVO) | 3 | 0 | 0 | 0 (all three live on off-grid media positions: I443, I126, LSGT) | **fits** — nothing to expose |
| `ua` (group 2, owner RMLVO) | 17 | 1 (`№`) | 16 | 12 | **fits exactly** (12/12) |
| `fr` | 23 | 3 | 19 | 16 | overflow by 4 |
| `gb` | 26 | 2 | 23 | 19 | overflow by 7 |
| `de` | 29 | 0 | 29 | 21 | overflow by 9 |

- The twelve pair slots are the page's whole spare capacity after dual
  caps, nav, `Tab`, `⇧`, `Enter`, `⌫`: 46.5 units − (duals 21, `Tab` 1.5,
  `Del` 1.0, `Home`/`End` 3.0, `PgUp`/`PgDn` 2.0, `⇧` 2.5, `Enter` 2.0,
  `⌫` 1.5).
- `us` and `ua` — the owner's configuration — fit; `ua` exactly, and only
  because `esc` and `↑` left the symbols page (§7: vetoing either costs
  one slot and puts `ua` at 13/12). The released default ships without a
  second symbols page.
- `fr`, `gb`, `de` overflow: §3.6's conditional overflow page covers them.
  R2 counted 18/23/26 for `ua`/`fr`/`gb`; this probe reproduces 23/26 for
  fr/gb exactly and 17 for `ua` — the one-token gap is the exact-string
  index (`ua` spells U+2019, the index looks for `rightsinglequotemark`).
  The pair fill inherits that exposure for *selection* (a position is
  pulled in by any carried token, and both its AltGr levels display), and
  ticket 05's helper-side inventory resolves it properly.
- us 3/12 in an earlier draft was wrong twice over: those three tokens sit
  on off-grid media positions (no cap can press them), and on the owner's
  `us` group RALT is `ISO_Next_Group`, so no pair cap may fill there
  regardless (§3.2's RALT gate).

## 5. Measured height — unchanged key size, one row pitch

Environment: disposable nested Hyprland (never the working compositor),
the real production components loaded from the installed plugin build, the
real Omarchy theme (probe: `space(42) = 39`, `spacingMd = 6`,
`fontScale = 11/12`), output 1276×749 @ scale 2 (638×375 logical).

**Grid heights (authoritative):** read from a probe instance of the
production `Keyboard` component inside the running panel process, whose
`uiScale` the harness sets per preset — i.e. computed from the production
`implicitHeight` binding (`maxPageRows × keyHeight + (maxPageRows − 1) ×
gap`) at forced scale, while the visible panel stayed at medium. The
binding is exactly what the docked reservation is built from, so no
window clamp can distort these numbers. `[grid]` lines in
`quickshell-*.log`; raw JSON beside them.

| Preset | keyHeight | gap | current grid (5 rows) | compact grid (4 rows) | measured saving | expected (keyHeight+gap) |
|---|---|---|---|---|---|---|
| M (×1.0) | 39 | 6 | 219 | 174 | **45** | 45 ✓ |
| L (×1.2) | 46.8 | 7 | 262 | 208.2 | **53.8** | 53.8 ✓ |
| XL (×1.45) | 56.55 | 9 | 318.75 | 253.2 | **65.55** | 65.55 ✓ |

**Window truth at M** (docked layer surface, `hyprctl layers`): current
283, compact 238 — the same 45, with identical panel chrome
(`cardHeight = keyboard.implicitHeight + gap×2 + dragBar + …`; the two
captures may sit on different sides of the headless session's readiness
notice — the grid delta above is the authoritative number). Real typing
target at M: a tiled `foot` window is left 8 px tall over the current
panel and 53 px over the compact one — the +45 reaches the client
(decisions §21: reservation is exact). `maxPageRows` drops 5 → 4
(probe-verified), so the pinned height every page shares drops one pitch
and the compact pages remain equal-height (AC 5).

**Recorded limitation:** the nested output's 375-logical height clamps
large panels, so L/XL window heights are not directly readable here; their
grid sizes are directly measured and ticket 12 re-measures the window at
L/XL in the VM at representative output sizes. The `large` row in
`measurements.txt` mixing a stale capture (the "6") is a raced read, kept
on disk and disowned here.

## 6. What ticket 12 must implement from this map

1. The four-row tables (§3.1): merged caps with built-in fallback pairs
   (`t`/`s`) behind both halves, `[-/х][=/ї][`/’]`-style upper/lower
   pairs, `esc` 1.5 + `⌫` 1.0, rows 2–3 verbatim from production.
2. Merged-cap interaction: 40/60 midline hit split, hairline divider
   affordance, one glyph per half from the keymap, `letter: false` upper
   halves; split ratio is owner-tunable.
3. Pair caps (§3.2): draw L3/L4 stacked with Shift-swapped emphasis;
   press AltGr+position with `letter: false, shift: latch-applied,
   altgr: intrinsic, exact: false`; spacers when unresolved; the RALT
   gate (`ISO_Level3_Shift` check) from ticket 05's helper facts.
4. Symbols page repack (§3.2) with `esc` removed; Fn row swap (§3.3) at
   the compact esc/⌫ widths.
5. Curated page conditional (§3.6): overflow-only content, `⇧…Enter` row
   always kept.
6. Spec/decision updates before landing: v1 §4 (page inventory, arrows per
   page, Fn row wording with grave→Ins), v1.1 §3 (symbols page
   composition, curated show rule), decisions §22 (five-row references,
   esc-on-symbols, Del placements). Marked pending the owner's acceptance
   of this map (§7) — the update itself is part of ticket 12's landing,
   not this ticket.

## 7. Open for the owner's acceptance

- The §1 digits decision: merged stacked digits (recommended; the Windows
  reference's digit legends made clickable — visible, one click, one row
  saved) versus the literal digit row (five rows, zero saving — §2.3).
- The §3.2 `esc`-off-symbols and `↑`-off-symbols trades. **Dependency:**
  `ua`'s fit is exact (12/12); vetoing either costs a pair slot and puts
  `ua` at 13/12, which would need the §3.6 overflow page for the owner's
  own layout.
- The two narrowings that fund the layout: `Del` 1.5 → 1.0 on symbols
  row 2 and `⌫` 1.5 → 1.0 on letters row 1 (alternatively: keep `⌫` 1.5
  and accept coinciding gap lines between rows 1 and 2).
- The merged-cap affordance (hairline divider, 40/60 split) and Fn
  auto-revert: spec'd here, judged in ticket 12's owner pointer-feel pass.
- Whether `fr`/`gb`/`de`-class layouts get §3.6's conditional overflow
  page in this release. Per-group row counts are not available (§2.3), so
  the alternative is a per-KEYMAP choice: keep the five-row arrangement as
  those layouts' maintainer default — two maintained arrangements, with
  the height gain withheld from their users. The owner's release is
  `us,ua`, where the question does not arise.
- **Demonstration gap, recorded:** the prototype run is `us`-group only.
  The `ua` claims are verified at the keymap level (the compiled
  inventory: `х ї ґ` on AD11/AD12/BKSL, the apostrophe on TLDE, the twelve
  pair positions), but this host could not capture live `ua` symbols-page
  screenshots nor inject the pointer for a typed midline-split demo (no
  pointer-injection tool available; the nested compositor wedged on the
  demo passes). Ticket 12's acceptance covers both, live, in the VM.
