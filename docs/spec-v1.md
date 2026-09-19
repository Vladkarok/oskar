# v1 spec — what the keyboard does

> Historical baseline. [spec-v1.1.md](spec-v1.1.md) is the authoritative
> current delta and explicitly replaces some requirements below.

Written 2026-09-02 from the design session recorded in
[decisions.md](decisions.md) and [orientation.md](orientation.md). This
is the behaviour spec for the first complete version: what the keyboard
does, not how the QML is arranged. It is also the document the shell
layer gets reimplemented against, so it needs to stand on its own —
see [§13](#13-provenance).

Nothing here overrides [decisions.md](decisions.md). Where the two
touch, decisions.md holds the reasoning and this holds the requirement.

## 1. What it is for

A mouse-first on-screen keyboard. The shape of the use case: laptop off
to one side, mouse in hand, a film playing, and a URL or a search box
that needs a dozen characters. Reaching for the physical keyboard is the
thing being avoided, so **every action must be reachable with the mouse
alone** — no step in any flow may require a key press.

The quality bar is the Windows touch keyboard. Not its looks; its
completeness and its feel. Linux has no equivalent, which is the reason
to build one rather than configure an existing one.

The differentiator stays layout coupling: the caps show what the system
layout will actually produce, switching language once switches it
everywhere, and it works in XWayland. That is settled and unchanged.

## 2. Non-goals

Named so they stop coming up:

- **Word prediction and autocomplete.** They need to see the text field,
  which means a text-input protocol, which never reaches XWayland
  ([decisions.md, Dead ends](decisions.md#dead-ends--do-not-retry)).
- **Emoji panel.** Omarchy has a picker.
- **Numpad.**
- **Auto-open when a text field takes focus.** Same protocol problem.
- **Touch-specific interaction** — gestures, swipe, multi-finger,
  long-press. Touch-friendly *sizing* is in scope (§7); touch input
  handling is not, and cannot be tested on the hardware we have.
- **Sound themes, custom key shapes, density variants.**

## 3. Invariants

Any implementation, including a from-scratch one, has to hold these.
They are conclusions the project already paid for.

1. **The panel never takes keyboard focus.** `WlrKeyboardFocus.None`.
   The window being typed into keeps focus or the keystrokes go nowhere.
2. **Keys are positions, not characters.** The panel sends `AD01`; the
   compositor decides what it means (§2 of decisions).
3. **The helper owns one keymap holding every layout as a group.**
   Language switching is `group <n>`, never a recompile. A
   byte-identical `configure` short-circuits.
4. **The compositor is the only source of truth for the active layout.**
   The panel follows `activelayout` and `configreloaded`; its language
   button asks, it does not decide.
5. **Caps come from the compiled keymap**, never from a built-in table
   except as a last-resort fallback, and a fallback is a logged error
   rather than a silent substitution (§11 of decisions).
6. **No heartbeats, no keepalive loops, no polling the seat.** The
   existing 2 s socket-repair tick is the only timer of that kind and it
   is gated on connection state.

## 4. Key set and layers

Three layers on one page plus one alternate page.

**Main page, unshifted** — the alphanumeric block for the active group,
drawn from the keymap: number row, three letter rows, `Space`,
`Backspace`, `Enter`, `Tab`, `Esc`, the four arrows, and the modifier
row (§5). Plus the language button and the close button, which already
exist.

**Main page, shifted** — the Shift layer of the same positions. Shift is
a real Shift press, so this layer costs nothing beyond redrawing caps
from the keymap's shift level.

**Symbols page (`&123`)** — the punctuation and symbols a physical
keyboard cannot reach in one press. Reached by a dedicated key, returns
by pressing it again. Its caps come from the compiled keymap for the
active group like every other cap; there is no fixed ASCII table.

**Function layer (`Fn`)** — an immediate two-state display control in the
bottom row. Off shows the page's ordinary top row, prefixed by `Esc`; on
replaces that same row in place with `Esc`, grave, `F1`–`F12` and `Backspace`.
It emits no key or modifier, works on both pages, and keeps its state only for
the shell session. The swap never changes panel or docked exclusive-zone
height.

Arrow cluster: `←↑↓→` as a group, positioned so repeated clicks are easy
to land on — arrow keys are the ones that get clicked most in a row.

## 5. Modifiers

Roster: `Ctrl`, `Alt`, `Shift`, `Super`. Super is required — Omarchy
binds nearly everything to it, and without it the keyboard cannot
trigger anything the window manager does.

One hand on a mouse cannot hold a modifier and click a key, so
modifiers are click-latched, with three states:

| state | entered by | leaves on |
|---|---|---|
| idle | — | — |
| latched | single click | the next non-modifier key press |
| locked | double click | another click on that modifier |

Requirements:

- **Latched modifiers stack.** `Super`, `Shift` and `Alt` can all be
  latched at once, and the next key press carries all three.
  `Super+Shift+Alt+E` must be typeable.
- **A latched modifier is consumed and cleared by the next non-modifier
  press**, whether or not the compositor swallowed that press as a
  binding. The panel cannot know a bind fired; "clear on next key" is
  the only rule it can implement honestly, and it is what a physical
  keyboard does.
- **Locked modifiers persist** across any number of key presses until
  clicked again, and survive a page switch (§4) and a language switch.
- **The cap shows the state.** Idle, latched and locked must be
  distinguishable at a glance, not by two shades of the same colour.
- Clicking a modifier that is latched promotes it to locked only via the
  double-click path; a second single click returns it to idle.

## 6. Key repeat

Press sends `down`, release sends `up`, and the **compositor's** repeat
delay and rate apply in between. The panel does not run a repeat timer:
a timer cannot match the user's configured `repeat_delay` /
`repeat_rate`, and matching them is what makes it feel like a keyboard.

Stuck-key protection, in order of preference:

1. The per-connection claim rules already in the daemon
   ([decisions.md §7](decisions.md)) release everything that connection
   holds when the socket closes. This covers a crashed or restarted
   panel, which is the common case.
2. A daemon-side cap on how long a **non-modifier** key may stay held —
   15 seconds — releases it and logs. Fifteen seconds of held backspace
   is about six hundred repeats; no one does that with a mouse button,
   and a panel that is alive but wedged is the only way it happens.
3. **Modifier codes are exempt from the cap.** A locked `Ctrl` (§5) is
   deliberately held for minutes, and a cap that released it would make
   the lock indicator lie.

No heartbeat to keep held keys alive. That shape of fix is what started
the keymap storm.

## 7. Geometry and window behaviour

Two modes, switched from the panel and remembered.

**Docked** (default on first run). Anchored to the bottom edge, full
width of its output, and it **reserves space** — windows move up rather
than being covered, which is what the Windows keyboard does when docked
and the reason it is the default: it needs no positioning decision from
someone who just installed it. Closing it gives the space back and the
windows return; opening the keyboard is not a one-way change to the
workspace. Fullscreen windows ignore layer-shell
exclusive zones, so during a fullscreen film the keyboard overlays
instead. That is accepted rather than special-cased; mode switching that
depends on window state is surprising, and overlay is the right answer
for the film case anyway.

**Floating.** Reserves nothing, draggable by its bar, and remembers
position and size preset across restarts. Draggable to another monitor.

Both modes:

- Open on the monitor **the mouse is on** at the moment of opening, then
  stay there until closed or dragged. Following focus would reflow
  windows on two outputs every time the user alt-tabs; a monitor fixed
  in config is wrong the first time the laptop is undocked.
- Size presets rather than free-form resize — two or three, cycled from
  a button. Free-form resizing is a lot of state for a thing operated
  one-handed from a couch. (v1.1 §4 replaces the cycle with a direct
  M/L/XL chooser and fixes the resize anchors: bottom-centre docked,
  card centre floating.)
- Hit targets sized for touch even though touch input is out of scope
  (§2). Large targets are better with a mouse too, and this is the
  cheapest thing to get right early and the most annoying to retrofit.

## 8. Theming

The keyboard follows the active Omarchy theme — colours, fonts, corner
radius — through the shared style tokens, and it does so from the first
line of the rewrite rather than as a later pass. Following the theme is
the baseline expectation for a Quickshell plugin, and hardcoded colours
are the one thing in this spec that is genuinely expensive to undo.

A theme switch redraws the keyboard **without a restart** of the shell
or the plugin, the way the rest of Omarchy behaves. A redraw costs no
keymap compile and no reconnection.

`follow_theme: false` is the v1 escape hatch and does nothing else yet;
the independent colour schema lands in v2 when someone says which
colours they want (§12).

## 9. Invocation and focus

The bar widget toggle is the only way to open and close it in v1. It
stays open until closed — no auto-hide on an idle timer. Auto-hide is
the first thing people disable: pause the film, come back, the keyboard
is gone mid-URL.

While the panel is open, Hyprland's `cursor:hide_on_key_press` is
suspended and restored on close, because the keys it sends are real ones
and the cursor was vanishing under the pointer aiming at them. That
behaviour exists and stays.

## 10. Configuration

One file, `$XDG_CONFIG_HOME/oskar/config.json`, both the persisted
state and the documented user config. One file rather than two, because
two files that can disagree is a bug class this project has already met.

| key | values | default |
|---|---|---|
| `mode` | `docked` \| `floating` | `docked` |
| `position` | `{x, y}`, floating mode only | unset |
| `size_preset` | preset name | medium |
| `sound` | `true` \| `false` | `false` |
| `follow_theme` | `true` \| `false` | `true` |

Nothing else in v1. Sound defaults off: the stated use case is watching
a film, and the mouse already makes a click. When on, it plays the
freedesktop sound theme's event sound rather than a bundled sample —
no asset to ship, no taste to defend, and nothing spawned per keystroke.

Every key here is one to support forever once the repo is public. Adding
one later is easy; removing one is not.

## 11. Layout coupling

Unchanged from what exists and is verified, restated so the rewrite
cannot lose it:

- The caps redraw when the compositor's active layout changes, with no
  action from the user.
- The language button advances the physical device and mirrors the group
  to the helper, so both the caps and the typed characters follow.
- The button greys out when there is no device it can safely advance,
  rather than guessing (decisions §5).
- Three or more groups cycle with the same button in v1. The chooser
  popup is v2 (§12), but the three-group case must be verified working
  by cycling before publishing.

## 12. Deferred to v2

Chooser popup for three or more layouts. Independent theme colours.
Context row (`.com` and friends). Dead-key accented characters. Appearance
extras beyond theme-following.

Sitting untouched by choice, not oversight: sleep/wake on real hardware,
and the upstream Hyprland work in
[vm-handoff.md](vm-handoff.md#upstream-queue).

## 13. Provenance

The first panel sketch grew out of an upstream project; the work since
has replaced every substantive line with our own. `tools/provenance.py`
measures the tree against the upstream snapshot `e3771b6` and reads
**zero shared substantive lines** (2026-09-12), gated on exit code. For
the history of that measurement — the baseline it started from, the
forced-idiom rules it counts fairly, and the licence consequence — see
[decisions §14](decisions.md#14-the-shell-layer-gets-reimplemented-and-only-then-does-the-licence-change).
| `KeyboardLayout.js` | 115 / 279 |

`Keyboard.qml` was first recorded here by hand as 341. The measuring
script reads 345 from the same tree and reproduces the other three rows
exactly, so the hand count was the thing that was wrong; the table now
carries the script's number.

The daemon, `systemd/` and `tools/` share nothing and never did.

The goal is a better keyboard, not a different one. Writing code whose
purpose is to differ from someone else's produces worse code; the
overlap goes to zero because the design was rederived, not because
identifiers were renamed. Independently written QML will still coincide
on imports, property declarations and anchor boilerplate — the check
measures substantive lines and a small structural residue is expected.

A script in `tools/` reruns the measurement. When it reads zero, the
licence becomes a sole copyright and the derivation is recorded as
history rather than as an ongoing attribution.

**The measurement is retired (2026-09-20).** It read zero, kept zero for
months, and then started flagging coincidences — `interval: 5000`, the
kind of line any independently written QML can produce. The gate was
removed by the owner's call: the sole copyright rests on the completed
reimplementation recorded above, not on a perpetual comparison, and the
derivation stays history.

## 14. Acceptance

Each item ships with its own verification in the VM, one feature per
issue. The keyboard is checked against a real Windows touch keyboard for
feel where the two overlap.

| area | verified by |
|---|---|
| layers (§4) | every cap on every layer matches `xkbcli` output for both groups |
| modifiers (§5) | `Super+Shift+Alt+E` reaches the compositor as one chord; latched state clears on the next key; locked state survives ten presses |
| repeat (§6) | held key repeats at the configured rate, not a panel timer; the 15 s cap fires and logs; a locked modifier is untouched by it |
| docked (§7) | windows move up on open and back on close; a fullscreen window is overlaid, not resized |
| floating (§7) | position and preset survive a shell restart; drag to a second monitor works |
| theming (§8) | a theme switch redraws without a restart |
| focus (§9) | the target window keeps focus through a full sentence typed into it, XWayland included |
| layout (§11) | caps follow a physical-keyboard layout switch; language button moves the physical device; three-group config cycles correctly |
| churn | the daemon's compile count stays at two across every test above |
| provenance (§13) | was: the `tools/` script read zero; retired 2026-09-20 (§13) |

## 15. Test seams

Where §14 says *what* must be true, this says *where* it is checked.
Appended rather than slotted next to §14 so that the section numbers
other documents already cite stay put.

A good test here asserts on what crosses a boundary: the protocol lines
that leave the panel, the compositor state the helper produces, the
state a reducer returns. Never on how a component is arranged
internally, and never on the panel's own belief about anything — the
compositor is the source of truth (§3.4), so a test that asks the panel
which layout is active is testing the wrong thing.

**There are two seams and there should not be a third.**

**Seam 1 — the control socket.** `tools/smoke-daemon.sh` grows from a
smoke test into the integration suite: the real helper, the real
protocol, the real socket, inside a nested Hyprland session, asserting
against compositor-observable facts and the helper's own log. It keeps
requiring the VM. There is no host-runnable split, because the facts
worth asserting on only exist when a compositor is there to produce
them.

Because keys are positions and not characters (§3.2), most of this spec
reduces to *which protocol lines came out, in what order* — which is
exactly what this seam sees. It covers chords arriving as one press,
`down`/`up` pairing (§6), the 15 s cap and the modifier exemption,
`group <n>` switching without a recompile (§3.3), a byte-identical
`configure` short-circuiting, and the compile count holding at two.

**Seam 2 — the modifier reducer.** The §5 state machine lives in a
JavaScript module with no QML imports, tested directly as a pure
function: events in, next state and emitted protocol lines out. This is
a structural requirement on the rewrite, not only a testing one. It is
the one piece of panel logic with enough branching to earn a seam —
three states across four modifiers, stacking, consume-on-next-press, and
survival across page and language switches.

**Verified by hand in the VM, with no automated seam:** space
reservation and its release (§7), the fullscreen overlay case, floating
position persistence and drag to a second monitor, theme redraw (§8),
cursor-hide suspension (§9), and focus retention through a full sentence
including XWayland (§3.1). Layer-shell exclusive zones and theme redraws
have no cheap automated seam, and a mock would only test the mock.

The Rust unit tests in the helper stay as the in-process seam for claim
bookkeeping and protocol parsing. They are not a third seam in the sense
above — they test the helper's internals, not the product's behaviour,
and nothing in §14 is verified there alone.
