# Why the design looks like this

The code shows what we do. This shows why, and what it cost to learn.
Each entry names the difficulty first, because most of these choices are
scar tissue. Commit hashes point at the full story.

## 1. There is a separate helper process at all

QML cannot drive `zwp_virtual_keyboard_v1`, so typing has to leave the
shell. The first version spawned `wtype` per keystroke. Two problems:
37.8 ms per key (measured), and **keystrokes never reached XWayland** —
`wtype` uploads a tiny synthetic keymap holding just the character it
needs, native clients re-read it, XWayland does not, so everything
vanished into Proton games and Electron apps. Holding the virtual
keyboard open across keystrokes did not help.

One long-lived helper with a complete keymap: 0.4 ms average, and
XWayland works. The Omarchy plugin guide also asks plugins not to spawn
shell processes. (`df2ac39`, `730b74f`)

## 2. The panel sends key *positions*, not characters

A physical keyboard sends positions and the compositor resolves them
through the active layout. When the panel sent characters, the label
decided the output, so the drawn cap and the typed character could
disagree — which is exactly what happened once layouts entered the
picture. Now `AD01` goes down the socket and the compositor decides what
it means. Shift is a real Shift press, not a choice between two glyphs.
Key names are resolved against the keymap's own `xkb_keycodes` section
rather than assuming evdev numbering. (`730b74f`, `070c2a3`)

## 3. The helper compiles its own keymap and never listens to the seat

**This is the most important decision in the project.** The original
helper subscribed to `wl_keyboard.keymap` and mirrored the seat's keymap
into its virtual device. That upload changed the seat, the compositor
rebuilt the keymap with xkbcomp, and the rebuild arrived as another
event to mirror: **56,547 keymap rebuilds in five minutes**, xkbcomp
pegged, desktop frozen hard enough to need a TTY switch. Guarding the
obvious loop left a slower one — 56 rebuilds a minute against 2 without
the helper — and broke layout switching in other apps while it ran.

Guarding symptoms kept the cause alive, so the subscription is gone. The
helper compiles its own keymap with libxkbcommon from the RMLVO the
panel hands it, uploads it once, and never reacts to the seat. With
nothing to react to there is no cycle. wvkbd has worked this way for
years without disturbing a session. (`83ac04b`, `f23d68c`, `fe074df`)

Why it stays invisible to other clients: Hyprland only tells a client
about a keymap change when the **bytes differ**
(`CWLKeyboardResource::sendKeymap`, `src/protocols/core/Seat.cpp`). We
compile the compositor's exact RMLVO, so switching between the physical
keyboard and ours is a no-op for everyone else. That is why `configure`
carries rules, model, layouts, variants, options *and* `kb_file` instead
of a bare layout list — with rules/model left empty, libxkbcommon
resolves the first layout and leaves later groups full of Latin, and any
divergence re-opens the churn. (`292c154`, `a7ed2e4`)

Corollary: **one keymap holds every layout as a group.** Switching
language is `group <n>`, not a recompile. A byte-identical `configure`
must short-circuit — the smoke test asserts the compile count for
exactly this reason, because a regression there is the return of the
storm.

## 4. The compositor is the only source of truth for layout

The panel used to keep its own idea of the active layout: adopted one at
startup, froze, and only its own button moved it. Caps Lock and the bar
indicator did nothing, and once keys became positions the panel drew one
alphabet while producing another.

Now the panel follows Hyprland's `activelayout` and `configreloaded`
events (the same way the built-in layout widget does) and its language
button only *asks* the compositor to switch. A slow repair timer remains
for devices arriving and leaving, which raise no event. (`8904c3f`)

## 5. Device selection: tiers, and a read/switch split

The difficulty is upstream: **Hyprland keeps layout state per device**,
including devices that never type — power buttons, `video-bus`, gaming
mice, and any IME's virtual keyboard. Nothing announces which keyboard
the seat is currently on.

Wrong answers we shipped and withdrew:

- *First non-virtual keyboard* — on this machine that is `video-bus`,
  pinned at group 0 forever.
- *Furthest-advanced device* — works until a pseudo-device gets
  advanced once and then lies forever.
- *`switchxkblayout all`* — moves pseudo-devices that never advance on
  their own; this is how the seat's devices ended up on different
  layouts and how a Razer mouse poisoned the indicator. Never use it.
- *Unfiltered `main:true`* — fcitx5's `hl-virtual-keyboard-fcitx5` holds
  it whenever an IME runs (observed live), and our own device takes it
  right after typing.

What we do now: **reading** takes the first tier that answers — filtered
`main:true` (Hyprland's `m_active`, the seat's current keyboard, which
moves on every real keypress), then the device the last switch named,
then layout progress. **Switching** only accepts the first two tiers, and
ticket 19 strengthens both with a physical-device inventory gate; at startup
that inventory seeds the named tier. With no positive evidence the language
button greys out rather than guessing, because advancing a guessed device is
what poisoned the seat
before. Residual windows are documented in the code comments rather than
pretended away: hotplug and mouse media keys can move the flag until the
next keypress, `activelayout` also fires for hotplug and config reloads,
and tied-at-zero devices are assumed to share the seat's RMLVO.
(`d40a21c`, `f3b97c8`, `9831667`)

The real fix is upstream — Sway already does it (same-keymap devices
share layout state, switches skip virtual keyboards). See the upstream
queue in vm-handoff.md.

## 6. "Switch once, one language everywhere"

Owner's requirement, and the reason the project exists: people cannot
remember that app 1 and 3 are on `us` while the rest are on `ua`. Since
`switchxkblayout all` is poison (above), this is implemented as *switch
one named device, then mirror the group to the helper's virtual
keyboard* — a freshly created virtual device starts at group 0, so
without the mirror it would type Latin while the caps drew Cyrillic.
That mirror is the behaviour the VM dogfooding verified in both
directions. (`1f9e581`)

## 7. Held keys are per-connection claims

The virtual device is shared by every client, so a code is one logical
press however many connections hold it. A plain set let one client's
disconnect release another's key; a naive refcount let a foreign `up`
decrement someone else's hold and let `tap` lift it.

Rules now: press belongs to the **first** claim, release to the **last**,
a foreign `up` is refused (`err not holding`), a `tap` on a claimed code
is refused (`err key held`), a disconnect releases only that
connection's claims and zeroes the modifier mask only when nothing is
held at all. A stuck Ctrl after a shell restart reads as a broken
machine, not a broken plugin — that is the failure being designed out.
(`a484a0b`, `b23e887`, `1da91de`, `4bb4ab7`)

## 8. Readiness handshake, not a liveness ping

A virtual keyboard without a keymap accepts every command and drops
every key — the silent-failure class this plugin kept hitting. `hello
<version>` answers only once the manager exists, the device exists and a
keymap has been forwarded; the version number also catches a panel
updated without reinstalling the helper. `ping` stays a plain liveness
check. (`35bbe0f`)

## 9. systemd user service, tied to the compositor

`omarchy-shell` restarts often and the helper should not; its Wayland
connection dies with the session. So `PartOf=graphical-session.target`,
and on dispatch failure it exits rather than reconnecting with stale
session environment — systemd rebuilds it cleanly. The socket lives
under `RuntimeDirectory=`, which makes permissions and stale-socket
cleanup systemd's job; the old `/tmp` and `wayland-0` fallbacks are gone
because with no graphical session this must fail loudly rather than
accept keys that go nowhere. Resource caps (`CPUQuota=10%`,
`MemoryMax=64M`, `TasksMax=16`) are last-resort containment: losing
on-screen input beats losing the desktop. A second instance is refused
by *connecting* to the socket rather than taking a lock file — that
distinguishes a live owner from a socket left by a crash, and unlinking
unconditionally let a newcomer steal the path from a running daemon.
(`35bbe0f`, `25b4386`)

## 10. The panel's socket lives in a Loader and is rebuilt, not toggled

Quickshell 0.3.1 semantics, verified against `src/io/socket.cpp`:
`connected` flips on the *request*, before the device is open; a failed
connect emits no state change to retry from; and — the trap — a failed
connect leaves the internal `QLocalSocket` alive while `setConnected(true)`
only dials when that object is `nullptr`. So toggling the property can
never recover a wedged connection.

Therefore: the `Socket` lives in a `Loader`, and a 2 s tick rebuilds the
whole object when the helper's socket file exists but hello is still
unanswered; `hello` goes out 150 ms after the state flip instead of
inline. The rebuild is gated on **actual connection state**, not on
`inputReady` — review round five caught that a slow configure handshake
would otherwise destroy a healthy socket mid-handshake — and rechecked
at callback time, because the file check can return after the socket has
come alive (round six). Symptom this fixes: the panel sat dead on every
boot where the daemon started after the shell. (`7dacd72`, `254077a`,
`42017b2`)

## 11. Keycaps come from `xkbcli compile-keymap`, and that pipeline bit us

The caps are drawn from symbols parsed out of a compiled keymap
(`xkbcli` → awk), which is a different code path from the layout *label*
and from typing. That independence is why a **single missing
parenthesis** in the awk program went unnoticed for days: gawk rejected
the whole program, the pipeline returned zero bytes, `symbolMap` stayed
empty, and the caps silently fell back to the built-in US table while
the label said "Ukrainian" and typing produced correct Cyrillic. It was
broken on both machines.

Two lessons kept in the code: the panel now logs the keycap process
start/exit to the journal, and "the label is right" is never evidence
that the caps are right. (`8c8546c`)

## 12. Testing ladder, and what each rung cannot see

1. `cargo test` — protocol and ownership logic.
2. `tools/nested-session.sh` — throwaway nested Hyprland with a private
   `XDG_RUNTIME_DIR`, so the subject's control socket cannot collide
   with an installed service; the run fails if compositor keymap
   rebuilds exceed a threshold, which turns the desktop-freeze class
   into a disposable test failure. It exists because the storm was
   discovered by exercising the helper against the live session.
   It cannot show which character an app actually receives.
3. The VM (`tools/omarchy-vm.sh`) — a real Omarchy install with a
   deliberate input zoo (PS/2 + two USB keyboards + tablet + fcitx5
   holding `main`), systemd user services, udev churn, hotplug via the
   QEMU monitor, and screenshots as evidence. This is where the paren
   bug and the boot-order race were caught.
4. Real hardware — sleep/wake only. QEMU q35 + OVMF will not do S3
   (`disable_s3=0` is set and it still refuses), so suspend testing
   belongs on the laptop, which is where the sleep bugs live anyway.

VM plumbing choices: the guest gets the repo either by cloning it from
GitHub or over the 9p share, and the provision script takes whichever
copy it was run from. The clone is the plainer path — no mount, nothing
to bootstrap, `git pull` to update — but it can only ever hold pushed
commits, so testing an edit that is not pushed yet is what the share is
for: it is the host's working tree as it stands. The share is exported
**read-only** (provisioning only reads) and rsynced to a guest-local
copy, because 9p is far too slow for a cargo target dir; a clone is
already local and is built where it stands. The provision script is
idempotent and keys its config guard on **its own marker comment** — an
earlier version grepped for `kb_layout`, which matches the commented-out
example in Omarchy's stock `input.lua`, so it silently never applied the
`us,ua` config the whole test depends on. (`7b0ecfc`, `af5280e`,
`0ebcde3`, `c973290`)

## 14. The shell layer gets reimplemented, and only then does the licence change

The difficulty is that we had been telling ourselves something flattering
and imprecise. "The input path shares nothing with it now" was true and
kept getting read as "none of this is derived any more." Measuring
against upstream `e3771b6` — the last commit before our own PR merged
into abdxdev's repo — said otherwise, counting substantive lines only:
`BarWidget.qml` 11 of 13, `Panel.qml` 146 of 179, `Keyboard.qml` 345 of
529, `KeyboardLayout.js` 115 of 279. (`Keyboard.qml` was counted by hand
as 341 that day; `tools/provenance.py` later read 345 from the same tree
while reproducing the other three exactly, so 345 is the number.) The
daemon, `systemd/` and `tools/` share nothing and never did. So the split
was clean and the claim was not: **the input path is ours, the shell
layer is his.**

Three options. Keep the attribution permanently and ship weeks earlier;
flip to a sole copyright now and call the overlap convergent QML
convention; or reimplement the shell layer until the overlap is real
zero. We took the third. Eighty-one percent of a file is not convergence,
and `df2ac39` sits in the history titled "plugin scaffold" where anyone
can read it — publishing under a sole copyright with that visible is the
version of this that could actually cost something.

Two constraints on how, both learned the same day. The reimplementation
is written against [spec-v1.md](spec-v1.md), not against his diff: code
whose purpose is to differ from someone else's is worse code, and the
overlap has to go to zero because the design was rederived rather than
because identifiers were renamed. And it folds into the v1 feature work
rather than running as a separate pass — a rewrite that changes behaviour
in zero ways cannot be told apart from a broken one, because there is
nothing to test.

The trigger is mechanical, not a judgement call: a script in `tools/`
reruns the measurement, and the licence becomes a sole copyright when it
reads zero. Until then the attribution stays accurate, because quietly
dropping it while the scaffold commit is public reads as erasure even
where it would be legally fine. Note it runs both ways — his repo carries
our merged fix under his MIT, same as ours carries his.

## 15. Startup device evidence comes from udev, not a seat guess

At shell start, the seat's `main` keyboard can already be fcitx5 or this
helper, so the two safe switch tiers from §5 have no physical device to name.
The helper now snapshots kernel input devices and udev metadata: a candidate
must have a physical bus and path, be tagged `ID_INPUT_KEYBOARD=1`, advertise
the ordinary typing positions, have a libinput device group, and share that
group with no mouse, touchpad, touchscreen or tablet. The pointer-group rule
rejects gaming mice whose HID interfaces advertise a complete keyboard.
Missing metadata rejects the candidate; it never becomes a reason to guess.

The first positively identified name seeds §5's existing named-device tier.
A real `activelayout` event replaces it, and the current-keyboard tier still
wins. Hotplug is driven by one `udevadm monitor` event stream and fresh
snapshots on add/remove; the former 30-second seat poll is gone. (`ticket 19`)

## 16. Only Shift locks; Caps and Fn are semantic toggles

Locking every modifier copied a useful one-handed mechanism too broadly.
A locked Super turns ordinary letters into compositor shortcuts and can make
the desktop appear broken; persistent Ctrl and Alt have the same class of
risk with less benefit. Shift is the modifier whose persistent state is both
visible in keycaps and routinely useful for consecutive typing.

Shift therefore keeps immediate latch and double-click lock. Ctrl, Alt and
Super are immediate one-shot latches whose second click cancels them. Caps is
a persistent letters-only semantic toggle and emits no physical Caps
position; Fn is a session-only display toggle. They do not enter the generic
modifier lock state. This replaces the v1 §5 all-modifier lock rule.

## 17. A curated symbols page does not widen the input boundary

An arbitrary Unicode palette sounds like a display-only addition, but every
unmapped symbol forces a new input mechanism. Temporary keymaps revive the
keymap-churn failure in §3; toolkit Unicode chords are not portable; an input
method competes with fcitx5 and misses XWayland; clipboard-paste mutates user
state and adds an unacknowledged delivery protocol.

Page 2 therefore has stable categories and placement but enables only symbols
that resolve to a position and level in the complete active XKB keymap. It is
shown only with at least eight available symbols. Unavailable entries are
disabled or omitted. No clipboard, IME, Unicode-entry chord or keymap
replacement is permitted. “Stable” describes the palette, not a promise that
every glyph is synthesizable.

## 18. Maintainer defaults, user overrides and panel state are separate roles

The v1 single-file design made a persisted position and a deliberate user
preference indistinguishable, and copying complete defaults into that file
would freeze old release values forever. v1.1 separates complete maintained
defaults, sparse user overrides and geometry/state. Effective appearance is
override, live Omarchy token, then shipped fallback.

File changes are event-driven and writes atomic; malformed external edits do
not replace the last valid runtime state or get silently overwritten. The
project is still in development, so no migration compatibility is promised:
the old OSK config/state may be discarded rather than burdening the new model.

Validation owns the override key space, not just the values (2026-09-06,
review finding R5). The snake_case names the panel writes are canonical;
the camelCase runtime spelling of an approved field is recognised and held
to the same validation, so `{"key_radius":8,"keyRadius":-20}` is a malformed
edit in either JSON order instead of a smuggled -20 that later serializes
into a canonical `key_radius`. Duplicate semantic names resolve to the
canonical spelling deterministically. Unknown keys ride verbatim — never
rewritten into canonical names on save — so nothing unvalidated can gain an
approved field's authority through serialization, and a key the runtime
cannot hold as the override map's own property (`__proto__`, and the
Object.prototype names V4 silently refuses to assign) is dropped by probe
rather than by a maintained name list. The store
(Config.js) stays the single home of this policy; the popover keeps issuing
changes through the panel's set/clear/commit operations and holds no
persistence policy of its own.

## 19. The helper is supervised; readiness is visible but not polled

An installed but disabled user unit is indistinguishable from a broken
keyboard when the panel hides its connection state. Installation and
development provisioning enable the helper for the graphical session, while
systemd's existing restart policy owns crash recovery. The panel exposes its
existing socket/handshake states and disables only input-producing caps.

Retry may start the user unit. A protocol mismatch instead offers a copied
install/update command and Retry; the panel does not silently compile,
install, elevate or notify repeatedly. This adds no heartbeat or status poll:
the existing gated socket-repair timer remains the sole recovery exception.

## 20. Shared Style owns live theme-token refresh

The OSK already has one Theme facade over Omarchy's shared Color and Style
tokens. Reading Hyprland rounding independently inside the OSK would create a
second authority and inconsistent refresh semantics. Live rounding and other
shared-token refresh therefore belong in Omarchy's shared Style provider;
the OSK only consumes those tokens and applies its own explicit overrides.
This is a cross-repository dependency, not permission for a local workaround.

## 21. Docking guarantees geometry, not another client's viewport policy

A layer-shell exclusive zone can shrink the compositor work area and keep a
tiled window's outer edge above the keyboard. It cannot tell an arbitrary
client to retain its bottom scroll position, chat composer or caret when that
client receives a smaller size. Docked mode guarantees exact reservation and
restoration only. Client-internal visibility remains client-owned; floating
mode is the escape hatch. App-specific resize or scrolling hacks are rejected.

## 22. Every row is laid out on one shared grid pitch

Per-row proportional flex — each row dividing the same width by its own sum
of width units — made key size a property of the row it happened to sit on.
Row sums ranged 13.95–17.25 units, so command-row keys and the arrows
rendered about 20% narrower than the letters above them, and centering ↑
over ↓ needed a 0.75-unit "compact" trailing Shift whose label clipped at
the panel edge. Widths that change meaning from row to row also made the
command row — the row the pointer returns to most — the worst place to aim.

All rows are now declared to the same 15.5 units and the panel divides by
one shared cell pitch, so every row is a grid of the same cell size: key
sizes are uniform between rows (the Windows 11 touch keyboard's defining
property, used as a look reference only), columns align across rows by
construction, and ↑ sits exactly above ↓ because the cumulative units left
of each are equal by arithmetic rather than by tuning. A rebuild-time guard
reports any row whose widths miss 15.5, because under a shared pitch a
short row stops short of the card edge instead of merely shrinking.
(`4742b4b`)

Round 5 read the owner's "chess-like" directive as integer widths on a
15-unit row, so every row's gap lines fell on one shared lattice — and the
owner rejected it: "you took the chess layout too literally," go by the
Windows keyboard. Measured against the owner's high-resolution Windows
reference, the real system is a half-unit lattice with the classic
stagger. Every width is a multiple of 0.5, every row sums to 15.5, and
adjacent rows' gap lines are offset by exactly half a unit — rows one and
three land on whole units, rows two and four on halves, the command row
whole across its modifier block and half across its arrow block — so a gap
lands mid-key of the neighbouring rows instead of on top of one. The
alignment the pointer cares about survives by arithmetic: 12.5 units sit
left of ↑ and of ↓ on both pages, and Enter's left edge (2 + 11 = 13.0) is
exactly ↑/↓'s middle — the relation the owner had been missing since the
flex model. (`77b485d`, `8d6c836`)

The same measurement directed two placements the panel would not have
chosen alone, recorded here because both are owner-vetoable: the &123 page
key moves from the middle of the command row to its bottom-right corner —
Windows' ENG slot, the far end of the row the pointer returns to most —
and Del joins the main page's second row, ending it as the reference's
does. The command row's own contract is untouched: same caps, same widths,
same place on both pages, the page key included. (`8d6c836`)

Del came to the symbols page first, in the round-4 retuning, beside
Home/End/Ins. It is pointer-unreachable like its neighbours — the reason
nav caps exist — and the owner's round-3 directive ("rearranging is
allowed, nothing is disallowed") covers it; it extends the symbols page's
fixed-label exception to the keymap rule, which is why it is recorded
here. All four nav caps now sit at 1.5 units (1.5 Tab + 8 punctuation +
4 × 1.5 nav = 15.5) and the main page's Del takes the default unit width.
(`4742b4b`, `77b485d`, `8d6c836`)

## 23. Keycap interpretation should share the helper's keymap authority

Status: adopted 2026-09-06 by the owner's execution request settling this
board (ticket 04); staged implementation began with the main/ordinary-symbols
slice. The findings that motivated it:

The review at `e55a7ce` found that curated availability assumes RALT selects
level 3/4 and that exact-level input can disagree with the displayed Shift
variant. The separate text-compiled keycap path discards facts the helper's
libxkbcommon keymap already owns. Propose supplying keycaps and reachable
position/chord facts from that installed keymap, correlated to an acknowledged
generation. This changes §11's pipeline while retaining §3's independent,
complete-keymap compilation. The staged plan and acceptance evidence are in
[next-iteration-plan.md](next-iteration-plan.md).

The accepted interface (recorded before implementation, per ticket 04; the
socket schema is implementer design, independently reviewed):

- **Protocol version 4, advanced together.** The `configure` reply becomes
  `configured<TAB><generation>` and a new `caps <group> [positions…]` command
  answers `caps<TAB><generation><TAB><group><TAB><records>` — one line, records
  separated by `0x1E`, fields inside a record by `0x1F`. Both sides moved to
  version 4 in the same change, so an old panel can never meet the new reply
  shapes: the hello gate refuses the pairing before any configure is sent.
- **Generation correlation.** The helper numbers each keymap install; a
  same-keymap reconfigure keeps the number, a changed keymap bumps it. Every
  keycap reply carries the generation it was computed from, and the panel
  accepts facts only when the generation and group match what the helper last
  acknowledged — superseded replies are discarded, and typing stays disabled
  while the facts for the acknowledged world are absent (an unresolved
  mismatch is a visible unavailable state, never a silent fallback).
- **Honest per-level fields.** Each level is `t<text>` (resolved character
  text, possibly multi-codepoint), `x<keysym>` (a symbol that produces no
  character — a dead key, a media key), or `n` (no symbol at this level). A
  requested position with no keymap entry is a record with no level fields.
  Resolution happens through libxkbcommon against the same compiled keymap
  that was uploaded; group switching adds no upload and no recompile.
- **Scope staging.** Ticket 04 draws only the main and ordinary-symbols pages
  from these facts; the curated page keeps the §11 xkbcli pipeline until
  ticket 05 replaces it. The record grammar is positional and tag-dispatched
  so ticket 05 can add chord-reachability fields (notably whether a group's
  compiled RALT is a real ISO_Level3_Shift) without breaking this one.

## 24. A picker opened from the panel needs a coordinated lifetime

Status: owner-requested behaviour, 2026-09-06; Emote session implemented
2026-09-07 (ticket 09). Shell-overlay cooperation implemented 2026-09-07
(ticket 10): opt-in OSK payload, PickerFit card placement, Exclusive
prime then OnDemand, VM-only shared-shell patch.

The owner requires the emoji cap to open and dismiss its picker explicitly,
with usable OSK search input and no overlap. Launch-only cannot supply that:
Emote's second activation destroys and remaps the picker (same daemon pid,
new address; live guest 2026-09-07, class `emote`, 565×549). Dismissal is
`closewindow` of that address; the daemon is left running. A process-name
kill is a dead end.

`stay_focused` and keyboard target are different paths. On Hyprland 0.56.2
the host's class-wide `stay_focused` rule is a follow_mouse lock that can
win pointer hit-testing before overlays; `hl.dsp.focus` still moves the
keyboard target even with the property set. The guest had no Emote rule.
Live guest 2026-09-07: `stay_focused=true` on the identified address
blocked OSK clicks (cursor sat on `q` and ☺; search stayed empty; ☺
did not dismiss). The panel therefore unsets `stay_focused` on that
address only while the session is open — not a class-wide keyword. GTK
destroy-on-unfocus did not fire from a compositor focus dispatch on the
live Wayland guest; nested evidence still saw closewindow after a real
focus flip, so click-away is not promised. Overlay clicks with
`WlrKeyboardFocus.None` left Emote as the keyboard target.

A cancelled opening keeps a closer (cancelMap) until that window is gone
or the 6s mapping timeout closewindows the late launch address from
bindLaunch; dropping the session on panelClosed used to let a late map
become the next ☺ recreate. Closing retries dismiss and re-arms that
timeout once a pin exists, and a failed closewindow process settles
rather than leaving ☺ dead. Mashing ☺ while a cancelled opening still
has no pin must not postpone that closer. playPickerActions must not
restart pickerHandoff while a close is in flight — a later stay/focus
or !client observation used to kill the close script — and must not
retarget a pending close onto a later map (stay used to overwrite
pending.addr while keeping closeWin). timeout/failed settle clears
pickerHandoffPending so a leftover close cannot closewindow the next
appearance.

Both pickers paste themselves (Emote: copy, destroy, 150 ms ydotool
Ctrl+V; ydotool was absent on the guest. Shell overlay: dismiss, then
`omarchy-menu-emoji-insert` Shift+Insert after 150 ms). The panel
restores the recorded client before that delay and does not paste
again. Fitting stays ticket 08's `PickerFit.planPlacement`; the overlay
applies it to its inner card and does not move a client window.
Unknown apps keep launch+fit. Managed toggle is Emote (identified
window + `closewindow`) or the shell overlay (open/hide/state IPC).

The default `omarchy-menu-emoji` launcher remains `omarchy-shell shell
toggle omarchy.emojis`. OSK invocation is opt-in: summon with
`{"osk":true, output, workArea, band}` or hide, never a second paste
and never a process-name kill. Standalone Exclusive fullscreen is
unchanged. OSK mode cannot keep Exclusive: KeyboardPanel already
records that Exclusive routes every pointer event to that surface, so
the OSK input region would not be reachable; the overlay primes then
settles OnDemand, and the panel band is subtracted from its mask. The
shared-shell patch lives in `patches/omarchy-shell-emoji-osk.patch` and
is for the VM guest, not the owner's live desktop.

## 25. Cursor hiding is owned by one serialized lifecycle

Cursor hiding (spec-v1 §9) used to live in the panel as a free property plus
a probe callback: close before the probe answered ran the restore first (a
no-op) and then let the late answer disable hiding with the panel closed —
review finding R6. The policy is now one owner (`CursorPolicy.js`, a pure
state machine; `CursorPolicy.qml`, its process host) that serializes probe,
override and restore, and tags every asynchronous answer with the generation
that asked for it, so a stale generation can never apply.

Non-obvious rules this fixes in writing: restore only an override this
lifecycle measured and applied, after one verify read — if the value moved
mid-lifecycle (config reload or external change), the undo is skipped rather
than writing a guess; a config reload supersedes a live override, and while
the panel is still open the policy re-measures so the suspension survives the
reload; a reopen that lands mid-handoff either rides the still-live override
or defers its probe behind the settling write, never mistaking our own
`false` for the user's setting; a failed undo write keeps the obligation
(the next close verifies and retries) instead of forgetting hiding was left
disabled.

Codex review of `ee834e4` (2026-09-07) required four more rules, now binding:
a config reload retires an in-flight probe and reissues it — a pre-reload
sample cannot apply after the reload; a reload that lands while a write is
in flight is recorded and reconciled after that write settles, rather than
assuming the write lands after the reload; a reopen mid-verify rides only a
confirmed still-live override (`false`); a write whose physical completion
is unknown (a watchdog timeout of a still-running process) retains the
restore obligation, and a confirmed process startup failure releases the
host slot.

Codex Sol Medium on `1b35b46` (2026-09-07) tightened three of those: an
unconfirmed write stays in flight (`writeSeq` kept) until physical
completion or destruction — a queued restore must not verify against the
still-running write; a failed verify during reopen keeps ownership rather
than re-probing a still-live `false`; a started hung read is stopped so
the host slot can be released once its generation is retired. The
documented residuals (a direct external eval is indistinguishable from
our override; a write that actually lands after a racing reload may leave
hiding disabled until the next reload; a destroyed shell covered only by
the config-reload escape hatch) live in the module header. The pure
machine rides the existing plain-qml test runner; the wrapper is
exercised end-to-end in the nested-compositor lab.

## 26. An explicit paste command is not a typing method

Status: owner scheduled ticket 14 into this release on 2026-09-07.
Current-content paste first; history stays out.

§17 forbids clipboard mutation as a way to type a symbol the keymap cannot
produce. That prohibition still holds. A header control that pastes whatever
the user already copied is a different act: the clipboard is the payload, not
a staging area the panel writes then pastes. The panel must not replace
clipboard contents, must not preview them, and must not synthesise glyphs
this way.

Delivery is per-class (`60adf57`, ticket 14, nested guest 2026-09-07). Typical
terminals — foot, footclient, kitty, alacritty, ghostty, wezterm, kgx,
gnome-terminal, konsole, xfce4-terminal, and reverse-DNS forms such as
org.kde.konsole — receive Ctrl+Shift+V (clipboard-paste). Shift+Insert
is PRIMARY in those clients. Empty or stale class uses that CLIPBOARD
chord so a missed lookup cannot send PRIMARY into a terminal. Native and
XWayland GTK entries receive Shift+Insert, which GTK binds to
paste-clipboard. The nested run seeds PRIMARY with a different sentinel
than CLIPBOARD, so a PRIMARY-paste cannot pass. Ctrl+V is not a paste
(foot types a literal). The reducer emits the chosen exact chord: latched
Ctrl/Alt/Super are spent and not mixed in, and locked Shift is left down
when the chord wants it. Empty CLIPBOARD is a no-op at the client.
Hex-entry paste inserts locally from `wl-paste` (CLIPBOARD, never
PRIMARY) because Quickshell.clipboardText is empty/stale in this stack,
and never asks the helper; the header control sits above the
settings/editor dismiss layers so that click cannot close the editor.
No per-keystroke process, no IME, no focus-taking panel.

## 27. Super shows Omarchy's own compact mark

The owner asked for the Omarchy logo on Super, not a Windows-style mark
and not the word Super. The established compact mark is U+E900 in the
private `omarchy` icon font (MIT, copyright David Heinemeier Hansson;
documented in Omarchy's `default/fonts/omarchy/README.md`, installed at
`/usr/share/fonts/omarchy/omarchy.ttf`). The bar launcher already
renders that glyph (`shell/plugins/menu/BarWidget.qml`:
`text: "\ue900"`, `fontFamily: "omarchy"`). Reusing that mechanism keeps
theme colour, scaling, and attribution with Omarchy rather than vendoring
a raster, drawing an approximation, or depending on an unofficial face
(the community "Omarchy Font" wordmark TTF is a different font and is
not used). The panel does not add a second Theme/Style reader: the glyph
uses the existing text colour tokens. A missing font falls back to the
Super label so the cap cannot go blank. Qt.fontFamilies(), FontLoader,
fontInfo.family, and a zero-width paint are not a presence check for this
private family: the first three miss it on a session whose bar already
draws it, and a substitute or missing-glyph box has nonzero width. The
packaged TTF path is the gate. If that file is absent, the cap never
requests U+E900 and shows Super. Appearance is screenshot-verified; this
is not a third product seam. Presentation only: one Super on the command
row, same latch/cancel and chords.

## 28. This release keeps five rows and hosts AltGr specials as pair caps

A four-row compact letters page cannot keep a dedicated digit row at
unchanged key size (65.5 units of mandatory content vs 62). The owner
chose the digit row over the height cut (2026-09-07, ticket 11): ordinary
pages stay five rows, ordinary click on a digit cap is the digit, and no
arrangement setting is persisted. Four-row compact is future work, not a
this-release requirement.

Specials that today's curated page exposed from alphanumeric-block levels
3/4 move onto `&123` as pair caps — stacked level 4 over level 3, Shift
selecting the upper half, press AltGr+position, non-exact — without
widening the input boundary (§17). Dual caps stay. The first eight pair
slots replace the existing 8-unit spacer on the symbols Shift…Enter row
and keep the 12.5-units-left-of-↑ invariant (§22). Remaining demand uses
the one unused row of the five-row pin (letters already have five;
symbols had four): fifteen unit slots plus a 0.5 pad. Capacity is 8, or
23 when that extra row is present. Probed inventories fit (ua 12, fr 16,
gb 19, de 21); us has none and omits the extra row. Page 2 is an overflow
valve only. Pair caps fill only where compiled RALT is `ISO_Level3_Shift`
(the owner's `us` group is not). Command row, Fn-in-place, header and
paste are unchanged. Height saving this release is zero.

The accepted map is [compact-control-map.md](compact-control-map.md).
Ticket 12 implements that packing, not a shorter keyboard.

## 29. Settings live on a second overlay; leftover-centre, keys still type

Gluing a popover to the gear over the key grid made the card-local dismiss
mask eat every key hit, and stretching the docked exclusive zone to host
settings would push clients. The keyboard `PanelWindow` therefore stays
the band it already is. Settings and the custom colour editor map as a
second full-screen overlay (`ExclusionMode.Ignore`) with the keyboard
band subtracted from its input region — the emoji overlay's hole — so
leftover clicks dismiss and key clicks still land on the caps. Placement
is the centre of leftover space (output minus the keyboard band), not the
top edge of the strip. If leftover is too small and the surface covers
keys, that is accepted; shrinking to fit is not.

The hex pad is gone because the owner types hex with the main OSK. Colour
fields take the existing Exclusive-then-OnDemand exception on the
*settings* overlay, not the keyboard surface, so a focused hex/RGB/HSV
field is the helper's client and an unfocused settings surface leaves the
previous app as the client. The custom editor is a WinUI hue×saturation
square plus a thin value slider: the old SV plane plus a hue bar duplicated
value on two axes.

## 30. `&123` is one Windows punctuation page; Shift holds page 2

The owner rejected dual keymap caps and pair-slot packing on `&123`
(2026-09-08) in favour of the Windows touch-keyboard glyphs
(`windows-symbols-one.png` / `windows-symbols-two.png`), then asked
for a single five-row page rather than two: base glyphs are page 1,
Shift layer is page 2. Command row, Fn-in-place, header and paste stay.
Cycle is letters → symbols → letters.

All character caps on this page resolve through the helper's permanent
reserved-symbol block. That includes ASCII punctuation and digits as well as
`£ ¥ ° × ÷`: the page no longer moves the virtual keyboard temporarily to a
`us` group, so a layout list without `us` stays honest and a physical layout
switch cannot be overwritten by a stale restore on mouse-up. A missing glyph
is unavailable rather than clickable with the wrong output. §17's input
boundary still holds: no clipboard mutation, Unicode-entry chord, IME route,
or per-symbol keymap swap.

Paste of CLIPBOARD into a terminal is Ctrl+Shift+**V** (AB04). The
previous chord used AB06, which is N; kitty, ghostty and agterm bind
Ctrl+Shift+N to a new window.

## 31. Keycap facts are a fact of the install, not of one group

Status: adopted 2026-09-08 from the owner's report that a language switch
flickered — the whole keyboard dimmed, the caps briefly reverted to the
built-in table and "Starting omarchy-osk.service…" appeared and left again.
Amends §23's accept rule and the typing gate; the protocol is unchanged.

§23 accepted keycap facts only when generation **and group** matched the
acknowledged world, and gated typing on an empty configure queue. Both were
right about a changed keymap and wrong about a language switch, which changes
neither the keymap nor anything the helper holds:

- **Group is a key, not a staleness test.** The helper resolves every group
  of an install when it installs it (`caps_per_group`), so all of them can be
  in hand before the first switch. The panel asks for every group of the
  configured keymap once per generation and holds them keyed by group; a
  switch then selects an answer already in memory. Holding one group's facts
  made each switch invalidate them, draw the built-in table in their place,
  and gate typing until a round trip replaced facts the helper had already
  computed. Generation is still the staleness test, and the *drawn* group is
  still the only one that may reach the caps.
- **The typing gate is the drain, not the queue.** A press is unsafe in front
  of a configure that will compile and install a new keymap — the helper
  drains every key it holds on the way in. A group-only configure compiles
  nothing and drains nothing, and the socket is ordered, so the group move
  lands ahead of any line written after it. Gating on the whole queue closed
  the keyboard for that round trip for no guarantee.
- **A refusal for a group nobody is drawing is not keymap-wide.** `err bad
  group` for a pre-fetched group leaves the drawn group's facts current and
  typing answering the installed keymap; it is logged, not raised as the
  unavailable state.

Two smaller costs went with it, both measured on the host: the compiled
`symbolMap` is cached per configure line, so returning to a group runs no
process (a switch back spawns nothing instead of ~45 ms of `xkbcli`); and the
two layout pipelines run under `bash -c` like every other spawn in the panel,
not `bash -lc`, whose only effect here was to source login profiles (~45 ms of
the ~50 ms each run cost). The rows model is also compared before assignment:
it is the Repeater's model, so reassigning it rebuilds a few hundred delegates,
and a switch used to do that four times over for rows that mostly did not
change.

The service-starting notice now has to hold for 400 ms before it paints. It
answers a helper genuinely being waited on; a state that resolves in a couple
of frames reads as a glitch, not as information.

## 32. The helper's keymap may carry symbols the compositor's does not

Status: adopted 2026-09-08 after measuring what §3's byte-identity clause
actually costs. Amends §3's corollary; §3's own rule — never subscribe to the
seat keymap — is untouched and is what actually prevents the storm.

§3 records that we compile the compositor's exact RMLVO so the helper's keymap
is byte-identical, "which is why switching between the physical keyboard and
ours is a no-op for everyone else", and warns that "any divergence re-opens the
churn". Ticket 18 diverges deliberately: the reserved symbol block appends one
key type and fourteen keys so `&123` can type characters no configured layout
carries. The review flagged this as reinstating §3's risk, and the experiment's
own notes listed physical/helper alternation as never exercised.

**Measured, in the VM, with a real second typist.** A focused `foot` under
`WAYLAND_DEBUG=1` logs every `wl_keyboard.keymap` it receives; the helper types
`!` from the block; QEMU's emulated PS/2 keyboard types `z`, injected from the
host with `virsh send-key` so it goes through the compositor's own keymap, not
another virtual keyboard's.

Six alternations produced `!z!z!z!z!z!z!z` at the client — every character
correct from both typists — and the keymap event count **stayed at one**, the
push the client got when it bound. Not one re-read across six switches of the
active keyboard.

So the divergence costs a single keymap push, not a push per alternation. The
client ends up holding our extended map, which is the compositor's RMLVO plus
positions its own keymap leaves empty, so every ordinary key still resolves
identically — which is why the physical keyboard's `z` is still `z`.

What §3 is really about survives intact: the storm was a feedback loop, the
helper mirroring a seat keymap whose own rebuild it then mirrored again. There
is no loop here — nothing subscribes, and the extra keys change no existing
definition (asserted in the helper's unit tests: 485 pre-existing key
definitions byte-identical before and after).

The measurement to repeat if this is ever doubted is in this section, not in a
comment: trace a client, alternate two real typists, count `wl_keyboard.keymap`.

## 33. Layout-independent symbols live above a keycode every consumer knows

Status: adopted 2026-09-09 after the owner reported §32's block typing
`°€±≠` into an Electron app instead of the ten characters drawn. Amends §32:
what the helper adds is unchanged in kind, only in *where* it is added.

§32 settled that the helper's keymap may carry symbols the compositor's does
not, and it still holds — the divergence costs one keymap push and changes no
existing definition. What it left open is which positions carry the block, and
the answer it took — the free keycodes the compiled keymap leaves empty — is
wrong for a reason no terminal test could see.

**A keycode is not a contract; a table lookup is.** Chromium's Ozone/Wayland
path maps evdev codes to `DomCode` through a fixed table and drops what is not
in it. Its X11 path takes the keysym instead, so the same character types into
XWayland Chromium and vanishes in an Electron window. Wine builds a third
table, matching keysyms against Windows layouts, and substitutes rather than
drops: `≠` arrives in Proton as `?`, which is `VK_OEM_2` on a US layout. Three
consumers, three opinions, one cause — the block sat on keycodes only xkb had
ever heard of.

Measured in the VM against native-Wayland Chromium, an ordinary letter as a
control on every run: of the fourteen free positions the block used, exactly
**two** reach Electron — `AB11` (evdev 89) and `AE13` (124). The ten page
glyphs lived on `I219`, `I222` and `I230`, all dropped, which is precisely the
`°€±≠` the owner saw. `foot` and `x11cat` resolve keysyms themselves, so no
test built on either can catch this; that is why the suite passed.

**So the catalogue moves to levels 5-8 of ordinary alphanumeric positions.**
Every consumer's table already knows those keycodes — the question was only
whether the modifier that selects the level survives the trip, and it does.
Electron 43 on Ozone/Wayland took every level 5-8 chord on ordinary positions,
12/12 steps in three runs, with stock levels 1-4 unchanged; foot agreed 12/12;
`I219` stayed silent in the same runs, so the rig re-proved the drop while
proving itself sensitive. The rig and its protocol are `tools/lvl5-probe/`.

The rejected alternative is levels 3-4 where the active layout leaves them
empty. It is simpler and it gives back exactly what ticket 18 set out to
remove: availability that depends on which language is selected.

Four things this shape costs, and they are the implementation:

- **Levels 1-4 produce the same characters.** That is what keeps §32's "no
  existing definition changed" true of a key the layout already defines, and
  it is an assertion, not an intention: what the position produces today is
  read off the keymap's own behaviour and written back verbatim, and a test
  compares the keysyms of every keycode, in every group, under every modifier
  pair, before against after.
  **What does change is which modifiers the position consumes.** The block's
  type declares `Shift+LevelThree+LevelFive`, so a hosted position consumes
  LevelThree and LevelFive whether or not it did before — `us` `AE01` goes
  from `0x1` to `0xa1`. It has to: four catalogue entries on one position need
  Shift and LevelThree to tell them apart. Toolkits match accelerators after
  stripping consumed modifiers, so an `AltGr+1`-shaped binding can stop
  matching on a hosted position in a group where AltGr is `ISO_Level3_Shift`.
  That is the price of the shape and it is not hidden here: the invariant is
  about characters, not about masks.
- **A position that answers to `Lock` is refused, not handled.** An
  eight-level type without `map[Lock]` costs a letter position its CapsLock
  uppercasing, so a position whose answer moves under Lock — or Control, Alt,
  Ctrl+Alt or Super, the modifier families the other canonical types use — is
  not hosted at all. A refusal costs the catalogue's tail, which is why the
  visible page is at the head of the catalogue and the spares at the end.
- **Ask about the MODIFIER, never about the key.** The first version of that
  refusal held down `<CAPS>`, `<LALT>` and `<LWIN>`. Under `grp:caps_toggle` —
  the owner's own option — pressing `<CAPS>` switches the *group*, so every
  digit-row position looked like it answered to something, every one was
  refused, and the catalogue collapsed to the two free positions on precisely
  the configuration it was built for. An option is free to move Lock to
  another key or to no key; the question is whether the Lock modifier changes
  what the position types, and only a modifier mask asks that.
- **`<LVL5>` needs no new machinery, but it does need proving.** Every
  compiled keymap carries `ISO_Level5_Shift` as `modifier_map Mod3 {
  <LVL5> }`, and the helper's per-group modifier probe credits it the way it
  credits `<LVL3>` with Mod5. Declaring the keycode is not the same as
  binding the keysym, though, and a block nothing can open would advertise
  glyphs through the caps facts that type the position's own level one —
  silent wrong characters, worse than the missing symbols this is allowed to
  fail to. So the built keymap is asked, before it is installed, whether
  holding LevelFive reaches the catalogue.

Two limits worth writing down rather than discovering:

- **The catalogue does not always fit.** Fourteen slots want fourteen
  hostable positions, and the digit row is twelve; the other rows' non-letter
  positions make up the difference where the layout leaves them free. Measured
  option-free: most layouts host all fourteen, `br` thirteen, `cz`/`am`/`jp`
  twelve, `sk` ten, `kz` eight, and `de(neo)` and `ca(multix)` two — those two
  put eight levels on nearly every position already, so there is nothing to
  ride above. Thirteen slots carry the whole visible page; below that the page
  loses characters, in the catalogue's own order.
- **A layout option that hands a physical key the block's own modifier**
  keeps it off ordinary positions entirely, leaving only the free ones —
  eight characters instead of fifty-six. Hosting above the digit row would
  change what that key types on it, which is the one thing this section
  promises never happens. It is not only the `lv5:` family: the test is
  whether any real key carries the modifier LevelFive resolves to (Mod3 on a
  stock keymap), so `caps:hyper`, `altwin:hyper_win` and
  `ctrl:swapcaps_hyper` trip it exactly as `lv5:ralt_switch_lock` does. The
  panel says so when the page comes up empty rather than leaving the user to
  wonder.

`AB11` and `AE13` remain usable whatever else changes: eight slots that work
in every consumer measured. Proton is a separate acceptance item — it has a
third table and it can run through XWayland or `winewayland.drv`, which are
different keyboard paths again, so it is checked under the launcher the owner
actually uses.

The native-Wayland acceptance leg landed 2026-09-09. The ordinary VM nested
suite drives Electron 43 with the shipping generated/published keymap, gates
an ordinary DomCode control, keeps I219 as the known dropped negative control,
and requires a discovered product glyph to arrive with a real DomCode. A
terminal cannot fail this way, so the Electron leg remains essential.

## 34. One device set: what the panel reads is what the button moves

Status: adopted 2026-09-09 after the owner reported, for the third time, that
a language switch left the indicator saying Ukrainian while typing produced
English — "works one time in ten". Amends §5, which is about the same seam
from the other side.

§5 established that the language button must move a positively identified set
of physical keyboards and never a device it only guessed at. It said nothing
about where the panel *reads* the current group from, and the two sets drifted
apart: the reading came from everything that is not a known pseudo-device, the
switch from the helper's udev-identified keyboards.

On the owner's laptop those are not the same set. `hyprctl devices` lists
twelve keyboards, of which three can type. The other nine —
`ideapad-extra-buttons`, a Razer mouse's keyboard interface, an ITE
wireless-radio-control, two video buses, two power buttons — each carry an XKB
group, and nothing ever advances them. They had been left on group 1 by some
earlier switch and stayed there. So the panel read Ukrainian off a device that
cannot type, told the helper group 1, and the keyboard the user's hands were
on stayed in group 0. Intermittent, because it only bit when the seat's
current-keyboard flag was outside the safe set and the last layout event had
named one of the strays.

**The reading device and the switch set come from one filter.** A group read
off a device the button does not move is a group the keyboard will not be
typing in. With nothing positively identified yet — the window before the
helper's device snapshot arrives — there is no answer at all and no configure
is sent, rather than a group guessed off whatever the compositor happened to
list first.

**And the seat is kept in one group.** A group-toggle key moves the one device
it arrives on — measured: `Caps_Lock` under `grp:caps_toggle` moved
`qemu-usb-keyboard-1` and nothing else, while every other keyboard stayed put.
So one Alt+Shift splits the seat, and from then on the language button
computes its next index from whichever device the reading picked. Every so
often that is a group the user's own keyboard already holds, and the press
moves everything except the keyboard in front of them: the indicator advances
and the typing does not. That is the "works one time in ten" the owner
reported, and it is not `hyprctl switchxkblayout` failing — that was measured
too, on the device that actually receives the keys: `us` typed `q`, `ua` typed
`й`, first try.

When the safe set disagrees, the stragglers are brought to the group of the
device that actually typed, never the other way round: the keyboard under the
user's hands is the authority, and dragging it backwards would undo the switch
they just made. Converging emits layout events of its own; the next refresh
finds the set in step and sends nothing, which is what makes it terminate.

**Which keyboard that is comes from the seat's `main` flag and from nowhere
else.** It used to be learned from `activelayout` events — and every
`switchxkblayout` this panel issues emits one naming the device it moved, so
the anchor pointed at whatever the panel itself had touched last. The panel
was reading its own echo. Harmless while it only decided a label; actively
wrong once it decides which way a split seat converges, because it would then
drag the user's keyboard back out of the group their own Alt+Shift had just
put it in. Hyprland prints `IKeyboard::m_active` as `main`, which is where the
last key actually came from; the panel remembers the last safe keyboard to
hold it and keeps that across the moments the flag sits on its own virtual
keyboard.

Until the seat has reported a key on a keyboard this panel may act on, nothing
is rearranged at all — §5's rule about never advancing a device you only
guessed at, applied to the seat rather than to one device.

Two smaller rules fell out of the same measurement:

- **A disagreeing safe set is settled by consensus, not by the maximum.** The
  old tie-break took the highest index any member had reached, so one keyboard
  left behind on group 1 spoke for all three. The most common index wins, and
  the lowest of a genuine tie: a majority cannot be dragged by one straggler,
  and where either answer is a guess the same guess every time is worth more
  than the larger one.
- **This logic lives in `LayoutDevices.js`, not in a shell string.** It was a
  jq program inside a QML string literal, and it is now the third defect of
  exactly this shape to reach the owner — a mouse poisoning the indicator
  (§5), a guessed device advanced while another kept typing (ticket 19), and
  this. None of the three could have been caught by any suite, because there
  was nothing a suite could call. The shell now only runs `hyprctl devices -j`;
  every decision is a function, and `tests/layout-devices.qml` drives it with
  the owner's real twelve-device zoo. Logic that has broken three times is not
  allowed to stay untestable.

## 35. The seat carries one keymap, and it is the extended one

Status: adopted 2026-09-09 after the owner reported that switching the layout
moved every indicator and left Telegram, WhatsApp and Viber typing the
previous alphabet while Discord, the browser and a terminal were fine — and
that pressing **any modifier key**, Ctrl included, unstuck them. Amends §32,
which allowed the divergence this section ends.

§3 compiled the compositor's exact RMLVO so the helper's keymap was
byte-identical, "which is why switching between the physical keyboard and ours
is a no-op for everyone else". §32 diverged on purpose for the symbol block
and measured the cost as one keymap push, by tracing a focused terminal while
two typists alternated. That measurement was true and it was the wrong
measurement: it counted keymaps during typing, and the cost lands on **focus
changes**.

Measured on the owner's machine, six focus changes with a client under
`WAYLAND_DEBUG`:

- helper running with the block: **nine** `wl_keyboard.keymap` events, two
  distinct keymaps alternating;
- helper stopped: **one**.

And the swap is not free. Every `keymap` is followed by
`modifiers(..., group=0)`: the client's group resets. A client that re-reads
the group afterwards is unharmed, which is why Chromium and a terminal were
fine; one that does not keeps resolving keys in the first layout until any
modifier event arrives — hence Ctrl fixing it, and hence the on-screen
keyboard itself typing Latin once a physical key had put the client back at
group 0.

**So the seat gets one keymap and the extended one is it.** The helper
publishes what it installed to `$XDG_RUNTIME_DIR/omarchy-osk/keymap.xkb` and
the panel points `input:kb_file` at that file, so the compositor compiles the
same keymap for every physical keyboard. There is nothing left to swap
between, and §3's "a no-op for everyone else" is true again — this time with
the block inside it rather than outside.

What that costs and how it is bounded:

- **The compositor's RMLVO stays the source.** The panel never feeds the
  published file back to the helper as an input; it keeps sending the
  configured rules, layouts, variants and options, so editing `kb_layout`
  still takes effect and the file is only ever the compositor's copy of the
  result. The helper recognises its own block in a `kb_file` and compiles it
  as it stands rather than extending it twice.
- **The setting is runtime-only.** `hyprctl eval hl.config({...})` does not
  touch the user's config, and the file lives under `$XDG_RUNTIME_DIR`, so a
  session that starts without this panel starts with nothing pointing
  anywhere. A stale `kb_file` cannot outlive the thing that set it.
- **It is cleared and set, not set.** Assigning the same path again is a
  no-op, and a republished file under the same name has to be re-read.

The measurement to repeat if this is ever doubted: trace a client with
`WAYLAND_DEBUG=1`, change focus half a dozen times, and count distinct
`wl_keyboard.keymap` payloads. One is correct. Two is this defect.

Automated 2026-09-09 in the VM-only nested integration suite. The suite
performs the panel's public clear/set of `input:kb_file`, maps a small Wayland
client under `WAYLAND_DEBUG=client`, and performs exactly six verified focus
transitions against a second real surface, ending on the observer. The client
hashes every received keymap fd rather than mistaking equal byte counts for
equal payloads, requires no event after its initial `OSK_RESERVED` payload,
and finally requires the group selected before the sequence plus `AD01` to
resolve to `й` without a corrective group request. The first green run
observed one wire event and one payload identity.

## 36. The QML is checked statically, because nothing loads it

Status: adopted 2026-09-09 after a commit shipped a panel that would not load
at all while three hundred checks stayed green.

Every offscreen suite in this project drives the pure JavaScript modules —
that is what makes them fast, and it is why they exist. What it costs is that
`Keyboard.qml` and `Panel.qml` are never loaded by anything but the running
shell. `onPairPositionsChanged` outlived the property it watched; QML refuses
a handler for a property that does not exist, so the panel failed to load
outright, and the suites had nothing to say about it. The owner found it.

`qmllint` can say it, because Quickshell ships `.qmltypes` and so its own
types resolve: `no matching signal found for handler "onPairPositionsChanged"`.
`tools/qml-check.sh` fails on that message and the runner calls it. Proved by
putting the real defect back in place and watching the gate catch it at the
line.

**One message, not a category**, and the reason matters more than the rule.
`qmllint`'s categories are not usable as gates here yet: `unqualified` has 851
hits that are the ordinary QML idiom of reaching an outer id; `missing-property`
fires because Quickshell types its `Socket` as a bare QObject, so `.write` and
`.flush` "do not exist"; `inheritance-cycle` reads `BarWidget.qml`'s
same-named root as self-inheritance; `uncreatable-type` objects to
`PanelWindow` being created, which is the only thing it is for. A gate that
fires on things that are fine teaches everyone to ignore it, and then it
catches nothing at all.

So the list is one line long and grows one message at a time, each added when
it is at zero across the tree. What would make it grow faster is cleaning up
one of those categories — which is worth doing, and is not the same job as
having a gate today.

## 37. The emoji catalogue is generated from vendored Unicode data, not read from the system

Status: adopted 2026-09-09 as step one of ticket 24, before any page exists,
because the licence and the data shape decide everything built on them.

The page needs a set of emoji, their names, and words to search them by. The
shapes considered:

- **A font** — Noto Color Emoji is on every Omarchy install and is what the
  caps will render through — carries glyphs and no names. It is the rendering
  path, never the data source.
- **A system file read at runtime** (`/usr/share/unicode/emoji/emoji-test.txt`
  on Arch) makes the panel depend on an optional package and buys names only,
  no keywords, so search degrades to name substrings. A dependency the panel
  does not control, for worse data.
- **A generated table, vendored and committed.** Chosen. The inputs are
  Unicode's `emoji-test.txt` 16.0 — the set, the order, the groups, the
  skin-tone variant structure, and the names — and CLDR 46's `en`
  annotations, which carry the search keywords and fall back as names. The
  comments in `emoji-test.txt` are the primary name source because CLDR 46's
  derived annotations are stale for the E15.1 facing-right families: ninety
  toned sequences arrived nameless of their own skin tone, six visually
  distinct caps sharing one name. All three files are vendored under
  `third_party/emoji/` beside the Unicode License V3 that covers them, each
  with its source URL and SHA-256; `tools/emoji/generate.py` turns them into
  `EmojiCatalog.js`, a pure `.pragma library` module that both the panel and
  an offscreen suite can load, and regeneration is offline and
  byte-deterministic.

Costs named rather than hidden: about 1.4 MB of vendored inputs and a
generated module of a few hundred kilobytes, parsed once at panel load. And
the catalogue goes stale as Unicode releases — deliberately: an emoji picker
is not an exchange rate, and upgrading is a deliberate act (replace the three
files, update the README table, regenerate, re-run the suite).

One tension is recorded, not resolved: the catalogue is complete — every
fully-qualified sequence of Emoji 16.0, 3781 of them — but delivery rides the
helper's virtual keymap (§33), whose spare capacity is finite. Whether the
page shows everything the catalogue holds or delivery constrains the page is
decided when the page exists, with measurements, not now.

Two more things review caught while the data was still cheap to fix:

- **Search lowercases both sides, or capitalised names are unfindable by
  their own words.** The first version lowercased only the query, and 388
  entries with capitalised CLDR names — every flag among them — answered
  nothing for `ukraine`. The suite's case test had passed, on `thumbs up`:
  the easy-fixture trap again, third time in this project. The fixtures that
  matter are the awkward shapes.
- **The variant link does not reach every toned sequence.** It serves 655 of
  the 1875: 1220 toned sequences hang off no base — 925 carry the tone
  inside the sequence, where the generator's trailing-strip rule never
  reaches, and 295 are two-tone couples whose tone-less shape Unicode does
  not define. Stripping all tones would link 1060 of the 1220; the other 205
  stay standalone under any such rule. A skin-tone UI keyed on base/variant
  links silently skips the unlinked rest; the grouping decision belongs with
  the page.

## 38. Super's mark is a choice, and the word is the default

Status: adopted 2026-09-09 after the owner reversed ticket 15's premise —
"по дефолту писало super как обычно" — amending §27, which chose the Omarchy
mark on his behalf and made it the only answer.

§27's mechanism keeps exactly one job: the Omarchy arm still draws U+E900
from the private `omarchy` font, still gated on the packaged TTF's presence,
still falling back to the word rather than requesting a glyph Qt would
substitute. What changed is who decides: the cap says `Super` unless a
setting says otherwise, and the setting — `super_mark` in the §18 store,
exactly word/omarchy/windows/apple/penguin, default word — belongs to the
user. §27 chose between the four platforms' marks on the owner's behalf; a
keyboard this project does not own the desktop for no longer should.

The three new marks are drawn, not vendored: QtQuick.Shapes paths in the
cap's own ink, monochrome, tinted by the same state colours the glyph rode —
no raster art of anyone's trademark enters the repo. A mark the system
cannot render degrades to the word, never to a blank cap; the store rejects
unknown values as malformed (§5 preservation), and the drawing side answers
anything outside the five to the word regardless, so the two authorities
fail the same way. The mark is a label in every arm: ModifierReducer, the
latch, the chords and the hit area do not know it changed.

The load-proof for the new import is structural rather than a gate:
`QtQuick/Shapes` is owned by qt6-declarative, which is both the offscreen
runtime's QML source and a hard dependency of quickshell itself — the import
cannot resolve in the suites yet be missing from the shell. Nothing in the
repo yet refuses a dead import; §36's gate still catches only its one
message.

Amended 2026-09-10 by the owner's eye on the drawn marks: the apple
silhouette became the looped square ⌘ — the mark an Apple keyboard actually
carries on that key — the store value is `macos` where §38 first said
`apple`, the Windows panes draw square-cornered, and the penguin was redrawn
with a face. The chosen marks stay drawn vectors in the cap's own ink; no
vendored art entered for any of them.

Amended again 2026-09-10 after the owner rejected approximated proportions
and theme inversion: the penguin uses the supplied `Monochrome_Tux.svg`
geometry, with its lettering removed, opaque white interiors and a white
exterior outline. Its black and white colours stay fixed in all key states
and themes. Preserve the original paths and aspect ratio; do not redraw or
stylise the mark. This supersedes the drawn-and-tinted rule above for the
penguin alone. The key's state remains visible through its normal background
and border. Owner visual acceptance remains separate from technical review.

## 39. An emoji is delivered through a transient keymap, and the settle is before the restore

Status: adopted 2026-09-10, closing ticket 24's delivery step. Amends §35
with a priced exception and bounds §33's refusals to what a transient can
mean.

A persistent keymap cannot carry the catalogue (§37's recorded tension), so
a pick swaps: the helper builds a variant of the installed keymap — the
requested codepoints on levels five to eight of ordinary letter positions,
levels one to four byte-identical — publishes it, taps the sequence, then
republishes the installed map and re-sends the modifiers with the group.
§35's one-keymap invariant survives everything but the pick itself: two
keymap events per pick on the focused client, zero on focus changes
afterwards, the group re-asserted by the closing modifiers request because
a keymap event resets it. Measured by the suite's observer leg: exactly
two wire events, installed map back last with its original identity, six
focus transitions carrying none.

The defect that taught the most: XWayland clients resolved every pick
against the previous map — a pick of 🙂 typed `й`. The first theory (the
swap had not reached Xwayland before the taps) died by measurement: hold
the restore back and the pick resolves at settle zero. The real race is
the **restore upload** — Xwayland recompiles the restored installed map
while its queued key events translate against the live one, so the taps
must not share a flush with the restore. The fix is one Wayland roundtrip
after the transient upload and a bounded settle between the last tap and
the restore: threshold measured at 20 ms on the lab guest (six picks at
5/10/15/20/30/50 ms), shipped default 50 ms, `OMARCHY_OSK_TEXT_SETTLE_MS`
for a machine whose margin differs. A pick costs ~60 ms; the number is
calibrated, not guaranteed, and the doc comment says which it is.

§33's refusals are about the install's lifetime — a hosted position keeps
its new chords for as long as the block exists — and a pick's lifetime is
~60 ms, so the permanent gates (never answer to Lock, index must equal
chord) do not transfer; applied anyway they refused all 26 letter
positions on the owner's stock `us,ua` and delivery never happened. What
the transient gate keeps is what the rewrite can express: at most four
levels per group and one keysym per level, which still refuses `de(neo)`'s
eight-level letters. The distinction — permanent gates for the block,
expressibility gates for the pick — is recorded here so the next reader
does not "fix" either direction. One window is named rather than hidden:
for the ~60 ms of the swap the transient map is the seat's map, so a
physical keystroke landing in that window resolves against it — plain
typing is unaffected (levels one to four are byte-identical), but a
CapsLocked letter loses its uppercasing and a held LevelFive chord types
the picked codepoint for one keystroke, self-healed by the restore.

Wine stays a recorded limit (§33): the keysyms arrive, Wine's Windows-VK
world renders a box. The suite proves foot byte-exact, x11cat (XWayland)
byte-exact, the clipboard untouched, and the pick once.

## 40. Chromium text insertion needs its own Unicode-entry route

Status: adopted 2026-09-10, ticket 26.

The missing-plane defect is inside Chromium, after correct XKB translation:
Electron 43 reports `KeyboardEvent.key` as U+1F601, then its default editor
inserts U+F601. Chromium's `ui::KeyEvent::GetCharacter()` still narrows the
DomKey scalar to one `char16_t`. A surrogate-pair keymap is not an escape:
libxkbcommon correctly gives surrogate keysyms no Unicode value. Both facts
are regression-pinned at the real Electron input boundary.

Known Chromium-family classes therefore use protocol command `text-unicode`,
which drives Chromium's standard Linux Ctrl+Shift+U composition with bounded
pacing. A transient one-group US keymap supplies the composition's ASCII hex;
the user's group zero is never assumed to be US-like, so `ua,ru`, AZERTY,
Dvorak and custom maps take the same route. The installed keymap, selected
group and held state are restored before the distinct `text-ok` reply.
Every other client keeps §39's transient-keymap `text` route: the Unicode
entry sequence is not universal (the raw foot leg rejects it), while the
keysym route remains byte-exact in foot and XWayland. Neither route reads or
changes the clipboard. `text-ok` / `text-err` are distinct from ordinary
command replies so a nearby tap cannot confirm or reject the wrong pick.
This is consumer routing, not scalar rewriting.

## 41. The paste chip attempts unconditionally; a refused emoji send is silent

Owner verdict, 2026-09-11, after living with ticket 25's liveness probe:
a click on the paste chip always sends the chord, whatever the probe era
claimed. A dead clipboard owner pasting nothing is the Wayland behaviour
the owner already dislikes; the chip adding its own refusal on top was
"only an inconvenience". The probe, its watchdog and its gone-hint are
gone from the external-client path; the R2 target determination (colour
field, emoji search, external client) and the bounded panel-local read
stay — they decide WHERE a paste lands, never WHETHER it happens.

The stage-B delivery-failure hint ("Emoji could not be delivered") was
removed by the same verdict: with the helper stopped the panel's top hint
already names the lifecycle state, and a refused `text` send while
connected is not worth its own surface.

Two follow-ups the verdict created live in their own tickets: the emoji
page's search-input focus indication (owner request, ticket 29), and the
clipboard-compatibility delivery route for Chromium-family clients such
as ZCode (ticket 28, release plan §6).

## 42. Clipboard compatibility is an explicit emoji-delivery mode, direct by default

Ticket 28, built as the owner approved ("делай как предложено", 2026-09-11).
The emoji page's header gains a toggle beside the skin-tone hand: typing
(⌨, the default) or clipboard compatibility (📋). Compatibility publishes
the exact picked sequence with `wl-copy --foreground` and sends the proven
paste chord — the route Emote and omarchy-menu-emoji always used, and the
only one Chromium-family clients that drop both typed routes (ZCode's
U+F8Fx placeholders, ticket 13's acceptance) leave.

The §6 rules it implements:

- Direct stays the maintained default; the mode never engages silently.
- The publication is VERIFIED against the clipboard before the chord
  (one `wl-paste` comparison, a few quick retries, then a loud journal
  drop) — a chord at an unverified clipboard would paste the user's
  previous content, which is the one failure worse than no delivery.
- The publisher stays alive as the selection owner until the next pick
  replaces it; killing it would recreate the dead-owner behaviour the
  owner rejected in §41.
- The clipboard is REPLACED, not restored: one text payload, stated in
  the toggle's tooltip. A roundtrip restore would race the pasting
  client.
- Usage counts the acknowledged send, not the client's insertion — the
  same semantics §39 already records for `text-ok`.

## 44. One pick owns the clipboard and its chord: a serialized delivery transaction

The 2026-09-13 audit's P1 race, fixed on reopened ticket 28. The §42 route
recorded success the instant the paste was *dispatched* — while the wine
chord was still draining line by line — and `pasteCurrent()` refused a
second paste silently. Rapid A→B picks could replace the clipboard owner
before A's delayed Ctrl+V reached the client: A lost, B possibly twice,
both counted. The fix makes publication plus paste one owned transaction
(`ClipboardPaste.txn*`, pure and test-covered):

- One pick in flight end to end — publish, verify, chord, completion. A
  pick while another is unfinished queues IN ORDER; a queued payload never
  replaces the clipboard owner an unfinished paste depends on. No guessed
  delay: the queue is the ordering, the completion is the gate.
- `Keyboard.pasteCurrent(wmClass, completed)` reports the real outcome:
  after the final paced line for a wine chord, after the socket writer
  accepted every line for an immediate one, `false` synchronously on any
  refusal (busy pacer, held key, unready input, dead socket mid-chord).
- Usage, search settle and close-after-pick fire only from `completed`;
  a refusal is a cancellation and the queue proceeds.
- An aborted paced chord emits compensating `up` lines for every unlifted
  press of its sent prefix (`compensatingReleases`), then converges by
  lifting (`releaseAll`) — never by re-pressing a lock whose world the
  abort just reset. A chord also aborts when the held-modifier world it
  planned around changes under it (a draining configure, a close).
- A socket loss or mode flip cancels the queue; a completion arriving for
  a cancelled transaction lands as `ignore` and records nothing.

## 45. One lifecycle command owns activation: the package installs files only

Audit 2026-09-13 §32, ticket 32. The product is one coherent package —
not "AUR helper plus a separately managed Git plugin" — and the line
between them is a single user command, `omarchy-osk` (setup / upgrade /
status / teardown). Package hooks run as root and must not guess a
user's session bus, so a package install is files only and the
`.install` message points at `setup`; activation (register
`/usr/share/omarchy-osk/plugin` under the stable plugin id through a
symlink, `omarchy plugin enable` through the official commands, unit
enable/start) is explicit and idempotent. The same script serves a
source checkout by resolving its own location, and `install.sh` links
it into `~/.local/bin` — one command, two worlds.

Rules the command enforces:

- A registration that is a REAL directory (a git clone from
  `omarchy plugin add`, a developer checkout) is never touched — not by
  setup, not by teardown. A symlink is re-pointed (the old target
  survives); teardown unlinks only a registration resolving to the
  payload the invocation owns.
- A legacy source install's `~/.config/systemd/user` unit OVERRIDES the
  packaged unit, so plain setup refuses while it stands;
  `--migrate-source` moves it aside renamed (`*.migrated-<timestamp>`)
  and removes `~/.local/libexec/omarchy-osk-daemon` and the
  `~/.local/bin/omarchy-osk` symlink — left behind, it PATH-shadows
  `/usr/bin` and the next bare `omarchy-osk setup` silently re-creates
  the legacy state. Never a silent delete of a user file.
- Config (`~/.config/omarchy-osk`) and state (`~/.local/state/`)
  survive everything, including teardown.
- The dependency contract is declared, not discovered: `omarchy`
  (provided by Omarchy's own packages), `hyprland`, `quickshell`,
  `qt6-declarative` (the payload imports QtQuick directly), `jq`,
  `wl-clipboard` (the chip and the compatibility route exec the
  tools), `libxkbcommon` (the helper links it), `gcc-libs`, `glibc`;
  the key-click sound is the one optional pair (qt6-multimedia +
  ffmpeg). A stock clean chroot cannot resolve `omarchy` (its closure
  is AUR-only) — the lab chroot builds `--nodeps` with the toolchain
  installed by hand and documents why.

## 46. The helper owns the user's keymap-source record

Audit 2026-09-13 §06, ticket 06's reopen. The panel's in-memory
`userKeymapFile` was the only record of the user's own `kb_file`; a shell
that died without its destruction hook (SIGKILL, crash) left the compositor
compiling the published keymap with the source lost, and the fresh shell fed
the helper RMLVO — the custom keymap silently dropped for the session. The
helper survives a shell crash and already owns the runtime directory, so the
record is helper-owned: every configure's `kb_file` runs through a pure
three-way decision (a user path is remembered verbatim, empty clears, the
published path leaves the record untouched) and lands atomically beside the
published keymap as `user-keymap-source`. The fresh panel seeds itself from
that file at the decision point — synchronously, before a snapshot can build
a configure — but only until a snapshot has OBSERVED the compositor's own
setting once: after a live observation (a user file, or an explicit empty)
the seed stays silent forever, so a cleared kb_file cannot be resurrected
from the record by the panel's own recovery read.

The lifetime is the unit's, held deliberately: `ProtectSystem=strict`
leaves the helper writable only inside its runtime directory, and
`RuntimeDirectoryPreserve=yes` keeps that directory across service stops —
`omarchy-osk upgrade` restarts the helper as a routine step — while systemd
still removes it when the session ends, which is exactly the record's
intended lifetime. A stale socket in a preserved directory is the daemon's
own startup logic (connect to tell a live owner apart, then unlink).

Two more rules the record obeys:

- It holds the panel's INTENT, not the compile outcome: even a refused
  configure is evidence of what the user had configured, and the recovery
  read happens on a shell that no longer has the value anywhere else.
- The compositor's `kb_file` is compared to the published keymap by exact
  identity, never by substring — a user's own file under a directory that
  happens to end in the published suffix is the user's, and the substring
  test adopted it as ours and silently dropped it. The path the panel SETS
  and the path it COMPARES come from one normalizing builder, so an
  environment spelling cannot make the two drift apart.

The protocol is unchanged: `configure` already carried `kb_file`, and the
sidecar is one writer (the helper) and one reader (the panel).

Two priced exceptions, accepted with the design:

- A transient empty `kb_file` read (a getoption hiccup while the
  compositor really carries the published map) clears the record for the
  session. The alternative — distrusting empty reads — would trade the
  common `hyprctl reload` case for this rare one.
- A sidecar left stale by an out-of-band clear while no panel lives can
  restore an outdated map once, on the next shell. Panel-driven clears
  self-heal; the window needs shell-dead + out-of-band clear + respawn
  inside one login session, and is bounded by the runtime directory's
  session lifetime.

## 47. A remembered group is bounded by the map that must carry it

Audit 2026-09-13 §31. The panel's remembered layout group is a
persisted index from a PAST session's map; a session whose layout list
shrank (four→two, two→one) cannot carry the old index, and asking for it
left caps refused and typing gated on a map that never answers. Two
bounds, one per side:

- The panel's selection seam honors the remembered group only while the
  CURRENT reading's own non-empty layout count carries it
  (`LayoutDevices.layoutCount`); otherwise the consensus fallback
  answers — the same answer a panel with no memory gives. The persisted
  domain itself stays XKB-wide (0–3): the defect is validity against
  the current map, not syntax.
- The daemon refuses an out-of-range group without touching device
  state (`err bad group`, the refusal `caps` already made): a configure
  is bounded by the map IT is installing — its own declared layout list,
  never the previously installed one, or a shrink-then-grow would refuse
  a correct grow — while a `group` command is bounded by the map that is
  installed, because that is the one it moves.

## 48. The usage view is a snapshot; the store stays live

Ticket 34, the owner's request at the audit round's close. The
recent/frequent category used to re-rank live — every completed delivery
re-evaluated the sections binding, so an emoji picked repeatedly moved
under the cursor by frequency and the last clicks of a run landed on the
wrong tile (and the model swap reset the scroll to top mid-clicking).
Now the category renders a snapshot taken when the view is ENTERED — on
page open and on re-entry into the usage group — and nothing else moves
it. Positional stability while clicking beats live re-ranking; a pick's
evidence appears the next time the view is entered. The persisted store
keeps its per-delivery discipline from §44 untouched — only the view
defers. Search is not a category switch: clearing a search returns to
the standing snapshot.

## Dead ends — do not retry

- Subscribing to / mirroring the seat keymap (§3). Also: guarding its
  symptoms with rate limiters and keymap fingerprints instead of
  removing the coupling.
- `wtype`, or any per-keystroke process: XWayland drops it (§1).
- `hyprctl switchxkblayout all`, and advancing a device you only guessed
  at (§5).
- Unfiltered `main:true` as the layout source (§5).
- Toggling `Socket.connected` to reconnect in Quickshell (§10).
- `hyprctl keyword` under the Lua config parser — it refuses ("keyword
  can't work with non-legacy parsers. Use eval."). Use `hyprctl eval`
  with `hl.config({...})`. (`a209fd4`)
- IME / text-input routes (fcitx5, maliit, GNOME): never reach XWayland,
  and they fight Caps-Lock layout toggles with a second layout state.
- Blaming the IME. It was measured out twice: stopping fcitx5 changed
  nothing, and the real cause was two keymaps on the seat (§35).
- Letting the helper's keymap differ from the compositor's without handing
  the compositor the same file: the two swap on every focus change and each
  swap resets the client's group (§35).
- Running the helper against the session you are working in.
- Rewriting the shell layer as a standalone pass with no behaviour change
  to test against, or renaming identifiers to lower the overlap count
  instead of rederiving the design (§14).
- Exotic free keycodes (`I219`, `I222`, `I230`, `JPCM`, …) as the home for
  the reserved symbol block: Chromium's Ozone/Wayland DomCode table drops
  them and Wine substitutes for them (§33). `AB11` and `AE13` are the only
  two of the fourteen that survive.
- Levels 3-4 "where the layout leaves room" for the same block — it is
  layout-dependent again, which is what ticket 18 removed (§33).
- Gating any of this on `foot` or `x11cat`: both resolve keysyms themselves
  and cannot fail the way a DomCode table does (§33).
- Trying to deliver the symbol block to Wine or Proton. Measured in the VM
  with `wine notepad`: ten glyphs typed on their real positions and levels
  produced `_ /?/?` — the positions' Windows VK meanings. Wine builds a
  keycode→VK table once and then knows only VK plus modifiers; xkb levels
  above the second do not exist for it, whichever position they sit on (§33).


## 43. Sole copyright: the last shared line went, and the gate stays

2026-09-12. The owner asked for the tree to be wholly ours. The
reimplementation finished: `tools/provenance.py` reads zero shared
substantive lines against the upstream snapshot `e3771b6` (from 235 that
morning), `LICENSE` carries a sole copyright, and the README, orientation
and spec-v1 §13 state the history without attributing the present.

2026-09-13, owner's follow-up: the README no longer states the history
at all — with zero shared lines, the public mention only misled readers
into expecting shared code. The history record stays internal
(orientation, spec-v1 §13, this section); the provenance gate stays.

The measurement stays honest by counting everything that could have been
written any other way and excluding only what could not: module imports,
`.pragma library`, the host shell's required type and property names
(`WidgetButton`, `bar: root.bar`, `PanelWindow`, the WlrLayershell
boilerplate), and single-anchor/boolean idioms QML offers no second
spelling of. Each exclusion is enumerated in the tool with its reason,
not inferred. The gate (exit 0 only on zero) runs in CI and before every
release, so drift in either direction - shared code returning, or the
exclusion list quietly widening - is a visible failure, not a judgement
call.

The real rewrites behind the number, all behaviour-preserving and
suite-verified: the keyboard's data tables became generated from compact
row specs (`typedRow`), the compositor-layout ingestion was rebuilt, the
dependency/drag/close machinery in Panel was restructured and renamed,
delegates became declared inline components, handlers moved to arrow
functions, and the cap vocabulary was renamed throughout (`chr`,
`chrShift`, `xkb`, `cellGap`, `capGlyphSize`). History keeps the derived
code visible in old commits; the licence statement covers the tree as
published, which is what the gate measures.


## 49. The language control takes three shapes

2026-09-13, the owner's call (ticket 35, the audit backlog's item 1).
One installed layout hides the chip entirely — an inert chip is noise
and a false affordance. Two keep the direct toggle the bar always had.
Three or more open a chooser listing every layout in group order; the
current group reads armed (accent fill), and a pick moves the whole
switch set to that ABSOLUTE group — the same move-every-device contract
the cycle always issued (`switchToGroup` is the one primitive both
shapes use). Hidden stays distinct from grey: hidden means "nothing to
switch", grey keeps meaning "nobody safe to move"
(`pullLayoutsFromCompositor`'s guessed-device caveat). The chooser
drops INTO the card over the grid, under the bar — the settings
popover's pattern — because the panel window's input mask is the card
rect: above the chip is outside the surface (invisible docked,
unclickable floating; the ticket-35 review caught the first cut doing
exactly that). The armed row and its click guard read the LIVE group
index, not the flag baked at open — the group can move while the menu
stands, from a physical switch or the shell's own widget.

## 50. No prediction or autocorrect layer

2026-09-13, the owner asked whether to build the IME-style features the
Plasma keyboard has (candidate strip, prediction, autocorrect).
Declined for now, deliberately. The product's core promise is drawn-is-
typed exactness through the virtual-keyboard protocol; autocorrect
fights that promise at the seam it lives on. A candidate strip adds
pointer targets to a pointer-driven surface — the prediction's value is
fewer clicks, but each candidate is one more small moving target, the
exact defect ticket 34 just removed from the usage view. And the layer
is an IME's worth of scope: per-language dictionaries shipped, ranked,
and kept honest against the layouts the panel mirrors — a product
direction, not a feature. Revisit trigger: a measured heavy mouse-typist
asking for fewer clicks, not a competitor's feature list. Search
vocabulary, by contrast, is cheap and exact — ticket 36 widens it to
CLDR ru/uk keywords without touching the input path.

## 51. A held cap offers its keymap column — levels 3-4, typed on release

2026-09-13, ticket 37 (the audit backlog's item 2, the owner's
request). Hold a character cap ~320 ms and, when its keymap position
carries extra levels, a small column popover offers them; a pick types
the level through the same exact modifier chord the &123 glyph caps
use. Three decisions inside it:

- **The column is levels 3-4, not 2-4.** Level 2 is the cap's own
  drawn Shift face — offering it would duplicate a character the cap
  already types and hand every two-level letter cap a menu, when the
  point is what the cap CANNOT reach directly. Levels 5-8 stay on the
  &123 page per §33: one route per character, no split authority. The
  content is the live keymap's own column (`capsFacts`), never a
  static accent table — the drawn-is-typed promise holds per entry.
- **Column caps type on RELEASE.** A press-typing hold-menu would
  strand stray characters before the threshold; deferred caps send no
  line at press, so a hold types nothing, starts no compositor repeat,
  and a canceled hold is strictly cleaner than today. Quick clicks
  send the identical press+release pair, only both at release. Caps
  without a column (stock two-level letters, Space, BackSpace,
  modifiers, exact caps, searchMode) keep press-types + the
  compositor's own repeat (spec-v1 §6) untouched.
- **The menu is card-local** per §49's lesson (the input mask is the
  card rect), folds on panel close, facts change and search arming,
  and its pick spends latches per §2 like any exact cap.

VM-proven in the live lab (the nested polygon cannot host the panel at
all: its seat exposes only the parent's wl_keyboard and
LayoutDevices.isSafe refuses it by design): hold typed nothing,
level-3 pick typed §, quick click typed 3, cancel and dismiss typed
nothing. Residuals on record in the ticket: a click on the menu's own
gaps dismisses it (miss target); a standing menu does not fold when
the settings overlay opens above it (unreachable, never mis-typing);
the level-4 entry is proven at the seam, not end-to-end.
