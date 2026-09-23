# oskar

A mouse-driven on-screen keyboard for Omarchy, where what is drawn on the
keys is what the system will actually type. Most of the vocabulary below
exists because two concepts that sound alike turned out to be different,
and confusing them cost us a bug.

## Language

### Layouts and languages

**Layout**:
One xkb layout by name, such as `us` or `ua`. Part of the RMLVO that
identifies a keymap.
_Avoid_: language, alphabet, locale

**Group**:
The index of a layout inside a single compiled keymap. Switching language
means moving to a different group, never compiling a new keymap.
_Avoid_: layout index, language slot, active layout

**RMLVO**:
The rules, model, layout, variant and options tuple that identifies a
keymap. Two keymaps compiled from the same RMLVO are byte-identical,
which is what makes our virtual keyboard invisible to other clients.
_Avoid_: layout config, xkb config

**Keymap**:
The compiled xkb keymap holding every layout as a group, extended by the
helper's reserved symbol block. One identity is installed per `configure`;
a group switch installs nothing. (§91 deleted the transient text
delivery with its swap; a pick never touches the keymap.)
_Avoid_: layout file, keyboard map, the one keymap

**Churn**:
Repeated keymap recompilation by the compositor. Bounded per cause, not by
one session-wide number: each configure-identity change costs its counted
compiles, and a group switch costs none (picks compile nothing — §91). The
nested harness derives its ceiling from the identities the suite installs,
never from the last observed count.
_Avoid_: rebuild loop, thrashing, the storm

### Devices

**Seat**:
The Wayland seat: the collection of input devices the compositor treats
as one user. Layout state is held per device rather than per seat, which
is the upstream problem this project works around.

**Current keyboard**:
The keyboard the seat is presently on, which moves on every real key
press. The only device whose group we trust when reading, and one of two
we will accept when switching.
_Avoid_: main device, active keyboard, primary keyboard

**Pseudo-device**:
An input device that reports as a keyboard but never types — a power
button, `video-bus`, a gaming mouse, an IME's virtual keyboard. Advancing
one poisons the seat's layout state.
_Avoid_: fake keyboard, virtual device (which means ours)

**Helper**:
The long-lived process that owns the virtual keyboard and does the
typing. Lives in `daemon/` for historical reasons.
_Avoid_: daemon, server, backend

**Claim**:
One connection's hold on one key code. A code is a single logical press
however many connections claim it; the press belongs to the first claim
and the release to the last.
_Avoid_: lock, refcount, hold

### The keyboard surface

**Panel**:
The on-screen keyboard window itself.
_Avoid_: window, overlay, widget (which is the bar toggle)

**Keycap**:
The glyph drawn on one key, derived from the compiled keymap for the
active group. Distinct from the label, and correct labels have twice been
mistaken for evidence of correct keycaps.
_Avoid_: key text, glyph, character

**Label**:
The layout's human name shown in the UI, such as "Ukrainian". Says
nothing about whether the keycaps are right.
_Avoid_: layout name, indicator

**Key position**:
An xkb key name such as `AD01`, resolved through the keymap's own
keycodes. What the panel sends; the compositor decides what it means.
_Avoid_: keycode, scancode, character

**Layer**:
The shift level of the main page — unshifted or shifted. Reached by a
real Shift press.
_Avoid_: level, shift state

**Page**:
The main page, the symbols page or the curated page (page 2). Switched by
a key, not by a modifier.
_Avoid_: screen, view, mode (which means geometry)

**Latched**:
A modifier clicked once, held for exactly one following key press, then
cleared. Latched modifiers stack.
_Avoid_: sticky, one-shot, armed

**Locked**:
A modifier double-clicked, held until clicked again.
_Avoid_: toggled, pinned, held

**Semantic toggle**:
A panel control whose on/off state changes what the panel presents or how a
later key is interpreted, but is not itself a held keyboard modifier. Caps
and Fn are semantic toggles.
_Avoid_: locked modifier, sticky key

**Mode**:
The panel's geometry: docked, which reserves screen space at the bottom
edge, or floating, which reserves none and remembers where it was put.
_Avoid_: layout (which means xkb), position, style

**Current-content paste**:
The header control that pastes whatever is already on CLIPBOARD into the
intended client. Distinct from using the clipboard as a typing method.
_Avoid_: clipboard history, clipboard synthesis, paste-as-input

### Emoji page

**Emoji page**:
The panel's own overlay page of emoji tiles, opened from the `☺` cap and
driven by the keyboard's own keys. It replaced the external-picker
cooperation (tickets 09/10, decisions §24 — history); the configured
external app remains launchable from a page chip, with no cooperation
from us.
_Avoid_: picker session, picker window, the picker

**Pick**:
One emoji choice on the emoji page, delivered to the previously focused
client by the clipboard transaction (§91: the one channel — publish the
exact sequence, verify, paste), at the documented cost of replacing the
clipboard.

**Skin tone**:
The emoji page's selected tone, persisted as state (`emoji_skin_tone`),
not a user override. Tone-capable families occupy one tile; delivery
resolves to an existing exact catalogue sequence.
_Avoid_: tone override, tone setting

**Clipboard transaction**:
The one delivery channel (§91 — decisions §39/§40's typed routes are
historical): the pick publishes its exact sequence to the clipboard,
verifies the read, and sends the client's paste chord. The helper's
acknowledgement proves the chord reached the compositor, not that the
destination consumed the paste (decisions §107's stated residual).
_Avoid_: clipboard synthesis, per-keystroke spawn, delivery mode

### Settings

**Maintainer default**:
A complete product setting supplied by the project and allowed to change in
a later release.
_Avoid_: user default, local setting

**User override**:
An explicit user choice that takes precedence over a maintainer default. An
absent override means “follow the maintained value,” not “use a copied old
default.”
_Avoid_: preference snapshot, custom default

**State**:
Remembered panel placement or transient UI continuity that is not a user
preference and does not override a maintainer default.
_Avoid_: config, setting, mode
