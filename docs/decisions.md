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

**Amended 2026-09-14 (ticket 47):** the rebuild gate is TRAFFIC
LIVENESS now, not connection state alone. Measured live: after a
GRACEFUL peer stop (systemctl --user stop), Quickshell 0.3.1's
`connected` stays true on a dead transport — the clean-EOF path never
reports the close — so the old policy (rebuild only on
`connected:false`) wedged the panel permanently after any service
restart while the panel was loaded: inputReady false, every key a
silent no-op, recoverable only by a shell restart. `SocketWatch.js`
owns the decision: a hello outstanding past a 5 s fair window (a live
helper answers <1 s; a configure compiling ahead of the repair
re-hello re-stamps the window) rebuilds the socket through §10's own
Loader mechanism whatever `connected` claims. The dead end below
stands unchanged — TOGGLING `connected` recovers nothing; rebuilding
does. **Amended 2026-09-15 (ticket 54):** because the lying socket
never runs the disconnect arm, the rebuild path carries that arm's two
residual resets itself, as a ledger beside the verdict:
`SocketWatch.rebuildResets` drains `pendingTextReplies` (the
disconnect semantics — cleared, callbacks dropped) so a stale FIFO
head cannot be settled by a post-recovery `text-ok`, and zeroes
`sharedKeymapGen` so a restarted daemon repeating the stale install
generation cannot make the once-per-generation share guard skip a
re-share. Pinned in `tests/socket-watch.qml`.

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

**Retired 2026-09-20, the owner's call.** The measurement did its work:
zero was reached, verified and kept for months, and the sole copyright
stands on that completed cleanup. What killed the gate itself was its own
success pushed past sense — it flagged `interval: 5000`, a coincidental
QML boilerplate line this project's own new code wrote, and would keep
generating such noise forever: any timer constant can collide, and nobody
owes an upstream mention for that. The comparison is not the licence's
foundation — the finished reimplementation is; the script measured that
work once and left, and nothing in the tree compares against upstream any
more. This section and spec-v1 §13 keep the history.

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

Amended 2026-09-15 (ticket 56, the IME matrix's kitty cell): a pick
carries the client class it was CLICKED for, pick to chord. The class
is derived once, at the pick — the same `focusedClientClass()` the
direct route's unicode-entry decision uses — and the arrival dispatches
with the carried value; the old arrival-time re-derivation was a second
opinion that could disagree with the click's (kitty's chord landed
wine-shaped). Queue entries are `{emoji, clientClass}` pairs, so a
promotion hands over rather than re-deriving, and the focus memory
`focusedClientClass()` falls back to is fed by the compositor's own
`activewindow` event stream — trustworthy while a panel overlay holds
the keyboard and `activeToplevel` is null.

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

Amended 2026-09-15 (ticket 57, the wall's first live run): a keymap
path that no longer EXISTS is not a keymap source, wherever it was
remembered from. The record outlived what it named when a leg's private
runtime died with its keymap while the sidecar (and the compositor's
`input:kb_file`) kept the pointer — every later panel adopted the dead
path and fed it to a configure that could never compile. The rule holds
at both readers: the recovery read refuses a dead remembered path, and
a live observation of a compositor setting that names no file empties
it — the panel configures from RMLVO and re-shares the published map.
Either way the helper's own three-way decision CLEARS the stale record
on the empty-`kb_file` configure, so the seat self-heals instead of
wedging.
  Priced with the rest (2026-09-15, ticket 57's live arm): a compositor
  kb_file that NAMES A NONEXISTENT FILE now self-heals — one warn, the
  RMLVO configure, the re-share. The price: a user's temporarily-missing
  file (a keymap on unplugged media) is FORGOTTEN after that one warn,
  not retried — the pre-57 alternative for the same world was a total
  panel wedge (every configure uncompilable), and a returning file
  re-adopts at the next observation or fresh panel. Out-of-band by the
  same rule §46 already prices its other exceptions with.

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

**Retired 2026-09-20** — see the note at the end of §14: the gate had
done its job (zero, kept for months) and was removed outright after it
began flagging coincidental boilerplate. The sole copyright stands on
the completed reimplementation; this section's title names the moment's
decision, not the tool's fate.

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

## 52. The armed emoji search borrows the keyboard — primed Exclusive, settled OnDemand

2026-09-13, ticket 42 (the owner's request: the emoji search types from
the OSK caps but not from the real keyboard, and he wants the physical
fallback). While `emojiSearchActive`, the settings overlay — never the
keyboard panel — holds layer keyboard focus, and a focusless scope on
the emoji page routes physical events through the same pure seam the
caps feed (`searchKeyAction` → `nextQuery`). Four decisions inside it:

- **Primed Exclusive, settled OnDemand — the §29 colour-field
  machinery, verbatim.** Hyprland's own source (0.56.2,
  `src/desktop/view/LayerSurface.cpp`) decides it: a mapped surface
  flipping None→OnDemand gets nothing on commit (no branch grants
  focus), so arming by page-open — pointer parked on the keyboard band,
  a None-interactivity surface — would leave the armed caret pointing
  at an app. The 75 ms Exclusive prime grabs at commit
  (`rawSurfaceFocus` in the now-exclusive branch); OnDemand then
  settles in, exactly the shipped hex pattern.
- **The settle is the clean disarm world.** Hyprland's
  `refocusLastWindow` explicitly skips OnDemand layer surfaces
  (`InputManager.cpp`: "if interactivity == ON_DEMAND, foundSurface =
  nullptr"), so clicking any client takes keyboard focus back, the
  `activewindow` watcher disarms, and the binding returns None. Full
  Exclusive (held for the arm's life) was declined: `refocusLastWindow`
  refuses outright while any Exclusive layer exists, so clicks could
  never reclaim the keyboard — the escape-mandatory world the ticket
  kept as fallback only.
- **Every disarm path releases by binding, not bookkeeping.**
  `keyboardFocus` derives from `emojiSearchActive`; the watcher, a
  delivered pick, physical or capped Escape, and page close all drop
  the flag and the surface returns to None. Hyprland answers a
  focused surface's None with unfocus + `refocusLastWindow` — the app
  gets the keys back. The pick drops its arm BEFORE the helper or the
  clipboard chord is asked for anything, so the delivery lands in the
  client focus returned to, not in our own surface. Opening a colour
  field disarms the search: §5's exception keeps its caps, one
  exception at a time.
- **The routing is one pure function, the QML only gates.**
  `EmojiGrid.searchKeyAction(event)` names "char"/"backspace"/"escape"
  or nothing (control payloads never type; Enter stays out per the
  ticket); the zero-sized FocusScope on the page checks `searchArmed`
  and forwards. A drawn field remains the single visual truth — no
  TextInput, no pre-edit.

The live measurement of which mode the compositor honours is QUEUED
(the lab VM is the ticket-35 tenant): armed typing via QMP lands in
the query, after Escape keys reach the app again, and the honoured
mode confirmed against this source reading. Until that leg runs, the
ticket stays open.

## 53. A settle guard owns the post-reconnect echo window, panel-side only

Ticket 38, after the owner's live hit (2026-09-13 18:53): the daemon
restarted under a live panel, the first configure after the reconnect
re-established the world, one language click three seconds later moved
all three keyboards to group 1 — and a devices read that returned the
reading keyboard at 0 (Hyprland re-applying keymaps around the fresh
virtual-keyboard registration; the mover is outside the panel) was
FOLLOWED, splitting the seat and dragging the persisted `remembered`
onto the churn. The fix is a pure seam, `SettleGuard.js`, consulted at
exactly one point — the reading path's follow — with the injected clock
and three inputs: the group the panel last followed, the group the
click's own hyprctl loop last commanded, and the observed reading.

- **What is guarded, and what never is.** For `WINDOW_MS` (10 s) after
  the ESTABLISHING configure — the first one following a genuinely new
  helper connection (the fresh-hello arm; the repair timer's re-hello of
  a live socket changes nothing) or a panel's birth — an uncommanded
  group flip is HELD: the panel keeps configuring the group it followed
  last, so the helper's device, the caps, the cursor and `remembered`
  (persisted from configure acks, and a held group is never sent) all
  stay on the clicked value. A flip is followed only once the SAME value
  persists a full `QUIESCE_MS` (1 s) past its last sighting — continuous
  churn re-anchors that clock and never accumulates into agreement. The
  click itself is never gated: `switchToGroup` records the command before
  its loop runs, the echo is followed immediately inside the window, and
  a command while armed re-anchors the window around the click (the race
  is the click's loop × the fresh registration). Outside the window
  every reading is followed at first sight — today's behavior exactly.
- **The establishing configure is exempt by design, and that is what
  keeps §47 whole.** The remembered-group tie-breaker answers from
  LayoutDevices as part of the FIRST reading a new world establishes; a
  fresh panel over a diverged sleeper seat follows it unconditionally,
  exactly as before the guard (the pure test pins it, and the lab's
  cold-start control ran it live: majority 0, sleeper 1, remembered 1,
  no `main` on a safe device, no named typist — the fresh panel answered
  1 with the guard silent). The residual: a genuine external switch
  inside the window is followed ~1 s late (one re-read after the
  quiesce), never dropped — the panel re-pulls once per held reading.
  The same arm cuts both ways and the review said so plainly: churn
  that PERSISTS past the quiesce is followed too, so the incident's
  own settled end-state (a split seat at rest) would re-emerge ~1.1 s
  later rather than never. That is the spec's own answer — the
  compositor's indices are the truth, and the mover is upstream of the
  panel (§5); a panel cannot tell a persistent flip from a real switch
  and must not try. Interleaved event reads can re-anchor the
  candidate and stretch the follow to window expiry at most.
- **Why a separate module and not KeyboardSession.** The session's
  ledger is reduced exclusively by helper replies on the socket; the
  settle question is about compositor readings over wall-clock time plus
  a command the panel issued through Hyprland — a different input
  stream, the same one-module-per-decision shape as LayoutDevices and
  ModifierReducer (`tests/settle-guard.qml`, 14 cases).
- **The daemon is untouched.** The guard stops the panel from echoing
  churn into the configure it sends; the seat's own churn (Hyprland
  re-applying keymaps to physical devices) is outside the panel and
  stays an upstream problem (the §5 queue). The lab leg proved the
  guarded click both ways — daemon restart, click inside the window,
  all three switch-set devices converged on the clicked group, exactly
  one `group ->` line in the helper's log (the bounce was a second one),
  `remembered` on the clicked value after the settle.

## 54. Dwell types through the cap's own click; the chrome never rests into action

2026-09-14, ticket 50 (accessibility slice one — "dwell is the first
thing onboard refugees ask for"). Hover a cap for the configured delay
and it types: press+release as ONE click, delivered through the same
`typeCap`/`triggerSpecial` + `releaseKey` paths a physical press takes,
so every chord, latch and drawn-is-typed rule is decided by the code
that already owns it. Four decisions inside it:

- **The machine is pure and the clock is injected.** `Dwell.js` owns
  enter/move/leave/tick against a caller-supplied `now`
  (`tests/dwell.qml`, the HoldColumn discipline); the QML side is one
  deadline timer per threshold crossing and the mapping of the returned
  action. Cancellation is on LEAVE, never on motion inside the cap —
  the trembling hand dwell is for must be allowed to rest — and a
  cancelled state is dead by the machine's own hand, so a stray timer
  tick after a leave types nothing. A rest types ONCE; repeat belongs
  to a key the compositor holds down (§51's rule, applied to the dwell
  side).
- **Dwell-past opens the 37 menu; dwell mode never defers.** The menu
  deadline is the delay plus HoldColumn's own hold window, read from
  the module so the two cannot drift. With dwell ON no cap defers its
  typing to mouse-release (`Dwell.holdDefers`): the dwell IS the click,
  a press types immediately, and the column menu is reached by resting
  past the type, never by holding a button. With dwell OFF the compose
  is `shouldDefer` exactly — ticket 37's behaviour is regression-pinned
  by both suites together.
- **Chrome is excluded, as a decision not an accident.** Dwell is an
  INPUT affordance. The grid's character caps (Space included), the
  sticky modifiers (a dwell on Shift latches exactly what a click
  latches) and the keysym nav caps dwell; the panel's own surfaces —
  gear, language chip, paste chip, the emoji page's cells — are not
  caps and never route through `Dwell.eligible`, and the grid's own
  command caps (close, page, emoji, fn, caps) are named excluded:
  resting the pointer while traversing the board must never close the
  panel, flip the page, open a picker or toggle a semantic layer under
  the pointer's feet, because those actions re-render or destroy the
  surface being rested on. A gated keyboard dwells nothing (§19's
  discipline, re-checked at fire), and the emoji search arm stays
  immediate-by-contract.
- **The affordance is progress, not state.** A thin underline at the
  cap's foot grows linearly to the deadline in the corner dot's own
  register (§45's quiet: textDim ink, a hint of opacity) and vanishes
  the moment the rest ends — it must never read as a second
  unavailable/dim treatment, so it never tints the cap or its glyph.

Off by default; `dwell_enabled` + `dwell_delay_ms` (400-2000, default
800) ride the §18 store with per-row reset, and the same bounds are
held at the file, the stepper and the machine's clamp. The VM leg is
owed on the ticket (QMP pointer rest → character in foot; dwell-past →
menu; leave → nothing), and the owner's feel pass stands pending as it
does for every behaviour change.

**Amended 2026-09-15 (ticket 50, slice two): the menu's own entries
dwell too.** The residual the review weighed and deferred is closed: a
pure-dwell user who OPENED the column menu by resting past the type no
longer owes one click to PICK — resting on an ENTRY for the delay
picks it through `pickHoldEntry`, the entry's own click semantics
(readiness gate, click sound, exact-level chord all the pick's). Three
edges, pinned in `tests/dwell.qml`: eligibility is its OWN rule
(`Dwell.entryEligible`) because an entry is not a cap — no position,
no key, no chrome exclusion — and it restates the pick's own gate
rather than trusting the fold that usually stands behind it; an entry
rest has NO second threshold (`Dwell.enterEntry` enters the shared
machine column-less — the pick is the destination, there is no menu
behind the menu); and the hover shield's contract survives whole
(0105888) — the padding and the gaps between entries never carry an
entry, so a rest there is still a pure swallow and only the entry hit
areas gained dwell. The same quiet underline the caps draw rides the
entry's foot; moving between entries re-targets (the enter
supersedes, the gap crossing arms nothing); a leave cancels; a
physical press supersedes the rest; the CLICK path is byte-for-byte
unchanged — a click still picks instantly. Shipped pending the owner's
feel pass with dwell generally, and the VM leg rides the timer-wiring
ticket the first leg filed.

## 55. Every chrome word is table data; the layout picks the language

2026-09-14, ticket 52 (council gap #4 — "the multilingual niche is our
audience and the UI is English-only"). The panel's whole surface spoke
one language except for one word: the emoji search placeholder (§36's
neighbour, ticket 36) already drew Пошук/Поиск/Search by the ACTIVE
LAYOUT's code. That mechanism, not Qt's translation stack, is what the
UI now rides.

- **One id-keyed table, pure JS.** `UiStrings.js` holds every
  user-facing word behind an id — tooltips, accessible names, settings
  labels, section headers, hints, status lines, the emoji page's
  chrome — in EN/RU/UK, and `tr(id, lang[, args])` is the only lookup.
  The QML files hold no English of their own beyond the disclosed
  residues (the review round caught ten leaked words — the dep
  banner's four and the colour editor's six slider labels — and
  they joined the table); substitution is Qt's
  `%1` idiom for the few composited strings ("Switch to %1", colour
  row accessibles). Keymap-derived text — cap glyphs, layout titles,
  the catalogue's emoji names, Config.js's parse diagnostics — is
  DATA, not chrome, and never passes through the table; the settings
  error line translates the SENTENCE around a diagnostic that stays
  English by contract (it names a file and a key; near-technical
  register, pinned by the config suite).

- **The language is the active layout, with an override on top.**
  `languageFor(layoutCode, override)`: `ui_language` in the §18 store
  (`auto` default, en/ru/uk pin; validated to the four words, junk
  preserved by §5 semantics) resolves over the mapping the placeholder
  shipped — ua speaks Ukrainian, ru Russian, every other code English,
  never a guess. The panel resolves once (`uiLang`) and every call
  site reads it, so a pinned choice moves the placeholder with the
  rest. The chooser's pinned choices are ENDONYMS (English, Русский,
  Українська) — a chooser's entries name themselves in their own
  language whatever the card is speaking — so only "Auto" translates.

- **The table fails loudly, and the suite hears it.** An unknown id or
  an empty translation THROWS from `tr`, and `tests/ui-strings.qml`
  pins both directions: the table is complete data (every id present
  in exactly en/ru/uk, none empty — 91 ids at landing) and every
  `UiStrings.tr("…")` literal in the runtime QML resolves, read by
  the suite itself through XMLHttpRequest (`QML_XHR_ALLOW_FILE_READ=1`
  in the runner — the one consumer of that escape hatch). A typo'd id
  dies in the offscreen suite, not as a blank at first hover. Both
  gates were mutation-tested: a broken call site and an emptied
  translation each fail the suite by name.

- **Cyrillic fits because it was measured, not assumed.** The mono
  face (JetBrainsMono Nerd Font, the shell's `monospace`) covers
  Cyrillic at both sizes we draw (fontBody 12, fontBodySmall 11 —
  `fc-list :charset=0430` and offscreen `Text.implicitWidth` probes).
  The fixed-width controls were re-audited against their translated
  labels: mode segments widened 150→160 ("Закреплена" measures 72px),
  the language control is 300 (the 72px "Українська" needs 72.5px
  segments and the row must stay inside the CARD in every language
  (the review's probe: the language row's 330px exceeds the ~321-
  328px control zone with an override pinned — a wording this
  section had as 'inside the control zone', corrected)), and the emoji picking pair shortened to infinitives
  ("Оставить"/"Закрыть") because "Оставлять открытой" cannot fit a
  70px segment. Free text wraps or elides as it always did, and the
  label column re-measures per language because its probe draws the
  translated labels.

Not translated, recorded as deliberate: the bar widget's tooltip
(BarWidget.qml lives in the shell process, knows no layout, and
plumbing the override there is file-reading machinery this ticket does
not buy), SettingsConfirmChip's never-shown default accessName (every
instantiation overrides it), M/L/XL and RGB/HSV (notations, not words),
and brand names (Omarchy, Windows, macOS). The VM leg is owed nothing
— strings render offscreen-checkable — but the owner's eye on a live
ru/uk shell stands as the acceptance it always is.

## 56. The mode chip returns to the header

2026-09-15, the owner's call — reversing his own 2026-09-08 one (which
itself followed his 2026-09-05 "no size button"): after real use he
switches docked/floating more than expected, and opening Settings each
time is friction. The header now reads gear, language, [notice], paste,
MODE, close: a text chip in the language chip's idiom showing the
CURRENT mode (Docked/Floating, localized — a label that states where
you are, not a mystery icon), one click toggling through the same
setMode the Settings row uses (config-health guard and the
floating-position restore included). The Settings row stays for
discoverability; the notice group's right boundary moved to the chip
(noticeEdge's fallback, ticket 57's anchor discipline preserved).

## 57. The panel knows its pointer: an input profile, and touch types on release

2026-09-17, ticket 58 (the owner's "я б сделал до выхода тоже": the
touch half of audit backlog item 4, brought ahead of publish). The
mouse and touch use-cases genuinely differ, so the panel grows an
INPUT PROFILE — auto (default) / mouse / touch — and everything the
profile switches is DATA in one pure module, InputProfile.js
(tests/input-profile.qml, 24 cases, red-first: the module was written
against a failing suite). Five decisions inside it:

- **The observation is the synthesized mouse event's `source`, and it
  is sticky.** Qt synthesizes the mouse events a MouseArea sees from
  touch (and tablet) input; `mouse.source !== Qt.MouseEventNotSynthetized`
  is the one thing that tells a finger from a button, and every
  interactive surface reports its presses' source to the panel's one
  writer (caps first — the press that teaches auto already types on
  release — then the header chips, the emoji page's cells and field).
  ONCE SEEN, panel lifetime: no decay, because a touchscreen laptop's
  stray mouse click must not flap the profile back mid-session, and a
  deliberate flip the other way is the explicit setting's job. A
  restart forgets; the next touch re-teaches. Pens get the touch
  affordances too — a hover-less pointer is the same world. Explicit
  mouse/touch overrides win over the observation; junk degrades to
  auto's semantics at the seam (the file's validation is the
  ui_language precedent: exactly three words).
- **Touch types on RELEASE, and a slide-off cancels — 37's machinery
  generalized, not duplicated.** In touch EVERY character cap defers
  (`InputProfile.touchDefers`: no column requirement, exact &123 caps
  included; `key` caps and Space keep press semantics because
  hold-to-repeat is their idiom), press sends nothing, and the release
  walks 37's own beginCapHold/endCapHold pair — one typing pipeline,
  the defer decision the only thing that changed (capDefersHold now
  asks the seam; in mouse the answer is Dwell.holdDefers verbatim,
  byte-today and regression-pinned by both suites). The 320 ms
  threshold rides the same timer: a columnless hold stays pending past
  it and the release then types. The slide-off check is the one new
  line in endCapHold: in touch, a lift outside the hit area cancels
  (never types); the mouse profile passes undefined and keeps today's
  type-wherever-the-button-comes-up semantics exactly.
- **Hover affordances die with the hover, as decisions.** Dwell never
  arms in touch (`dwellArms` composes the setting AND the profile — a
  leftover dwell_enabled override strands nothing); hover highlight is
  inert by absence (touch synthesizes no hover, the binding needed no
  change). Tooltips, decided per control: the header's GLYPH chrome
  (gear, close, paste) shows its tooltip on touch-and-hold —
  help-then-action as one gesture, the release still clicks — and the
  TEXT chrome (the mode chip) hides it, because its label already
  states what it is; everything else hover-only (the emoji cells'
  names) is hidden on touch by absence. The table owns the two named
  classes; the module header pins the rest.
- **Chrome targets grow invisibly, gap-capped.** The touch floor is
  44px (the number the platform guidelines converge on); the chips are
  28-30px drawn and NEVER redrawn — the MouseAreas grow by negative
  margins, vertically the full need bounded by the room each control
  owns (the drag bar's band above, the bar's edge below), horizontally
  capped at the MIDPOINT of the gap to the neighbour (the capHit
  discipline, so two grown areas tile instead of fighting). Mouse
  grows nothing anywhere: the table's mouse minimum is 0, byte-today.
- **preventStealing is the pinned guarantee, not a present fix.**
  Nothing on today's grid steals a sliding finger (no Flickable
  parents the caps), so the touch profile's flag is a no-op made
  load-bearing the day the grid grows a scrollable surface — and it is
  deliberately NOT set on the surfaces where a slide IS the gesture
  (the emoji grid, the settings scroll): those keep stealing, which is
  finger scrolling.

The daemon, the protocol and the keymap pipeline are untouched — a
press is a press. The settings row (INPUT section, Pointer profile)
is localized EN/RU/UK with the widest segment label ("Сенсор", 43px at
fontBody) pinned offscreen to fit its 47px slice.

The VM leg (lab ticket 58, 2026-09-17): QEMU 11.1.1 CAN emulate
multitouch for this lab — `virtio-multitouch-pci` (bound
`display=<vga-id>`, present at boot: the lab's pcie.0 refuses
hotplug, so a temporary wrapper booted the same disk with the device
added; NO domain XML was touched) presents a real protocol-B evdev
touchscreen, and QMP `input-send-event` mtt begin/data/end + btn
touch drives it — with two lab traps now on record: the kernel input
core DROPS duplicate ABS_MT values (scripted taps must jitter, a real
finger always does), and device-addressed events need the console
binding. Proven live, in order: kernel evdev (tracking ids, BTN_TOUCH,
0..32767), libinput (TOUCH_DOWN/FRAME/UP), and Hyprland forwarding
wl_touch to a client surface with exact coordinates (WAYLAND_DEBUG
capture). NOT proven live: the panel reacting inside the guest — the
guest's Qt never turned the delivered wl_touch into app events in any
process (bare qml window or quickshell), and Hyprland's wl_touch
delivery was not reproducible under changed focus in that build (its
own movecursor dispatcher also errors — an unstable snapshot, not a
stable oracle). The burden fell where the ticket said it would: the
seam's 24 cases plus the HOST proof that Qt 6.11.2 — the guest's exact
version — synthesizes MouseArea presses from touch with
`source == Qt.MouseEventSynthesizedByQt` (qmltestrunner, mouse
baseline + touch case), which is the exact fact the observation keys
on. The owner's finger on real hardware remains the acceptance it
always is; a lab re-run owes the wl_touch-into-Qt hop a second look on
a stable Hyprland build.

## 58. The name settles pre-publish: oskar, wordmark OSKar

2026-09-17, ticket 59 (owner's decision 2026-09-15 after a three-model
naming council — Codex conceded to Opus's final, the orchestrator's
third voice concurred; `oskar` over omarchy-osk / vkarok / karok /
klava. Collision checks live: AUR zero, crates.io free, GitHub nothing
significant in-domain). A partial rename is worse than none, so the
sweep is total:

- **Two layers, one name.** The MACHINE layer is lowercase `oskar`
  everywhere — AUR package, binary, unit, socket dir, repo paths; that
  is policy, not taste. The HUMAN layer (README H1, docs headers,
  package description, the shell's plugin display name) writes the
  wordmark **OSKar**: the OSK skeleton stays visible and the
  Oscar-the-statue reading dies. README carries the pronunciation line
  ("OS-car"; RU/UA read Оскар unambiguously) and the icebreaker: "OSKar
  is not Oscar — no statuettes; it's the OSK, ar."
- **The OSK_ env-gates stay.** `OSK_PANEL_CANARY_LIVE` and the whole
  OSK_ family are generic on-screen-keyboard vocabulary with fresh,
  settled tool conventions — renaming them is churn without value. The
  OMARCHY_OSK_* family, however, was the old NAME in env-var clothing:
  the doctor seams became `OSKAR_DOCTOR_*`, the daemon's timing seams
  `OSKAR_HOLD_CAP_MS` / `OSKAR_TEXT_SETTLE_MS`.
- **Installed machines walk, they do not start over.** The package
  declares `replaces=(omarchy-osk)` (and conflicts): `pacman -Syu` and
  the AUR helpers' sync installs carry the old package away by
  replacement; a plain `pacman -U` REFUSES while the old package stands
  (proven live in the lab), so its documented path is
  `sudo pacman -Rns omarchy-osk` first; `oskar setup`/`upgrade` detect
  any remaining old-name world — old unit (stopped, disabled, moved
  aside `*.migrated-<ts>`), old registration (unlinked if a symlink,
  moved aside if a directory), old PATH shadow, old helper — and MOVE
  `~/.config/omarchy-osk` → `~/.config/oskar`,
  `~/.local/state/omarchy-osk` → `~/.local/state/oskar`, so the
  keyboard keeps its settings through rename day. `oskar teardown`
  deactivates an old world too; `oskar doctor` fails on old-world
  leftovers. Everything idempotent: a clean machine finds nothing and
  the migration says nothing.
- **The log prefix grew a syllable:** `[osk]` → `[oskar]`, with every
  tool regex that matches it (doctor's keycap-fallback sweep was already
  prefix-agnostic). Bare `osk` test-harness vocabulary (osk-nest dirs,
  osk-typed.txt, the 9p tag `osk-src`) is generic infrastructure
  naming, not the product name, and stays.

## 59. A diverged seat is resolved by who moved, not by a vote

The seat's groups live per device, and only the interface that carries the
keys ever moves: a physical Alt+Shift toggles the typing twin alone (§34's
measurement), and the compositor can flip one with no toggle in the
keystroke at all — caught live by the split-watcher on 2026-09-18 20:07: a
plain Shift press, no Alt anywhere, no actor in the journal, with
`us,ua` + `grp:alt_shift_toggle` and nothing else in the options. The
panel's own vkb held `main` (fresh registration), so the reading was the
named anchor — the typing twin, live on group 1 against two sleeping
siblings on 0.

Ticket 64's arm answered that seat with consensus + remembered: two devices
that never receive keys outvoting the keyboard under the owner's hands.
Every indicator said English while the fingers typed Ukrainian, and nothing
resynced until the next Alt+Shift — which "fixed" it only by flipping the
typist back onto the sleepers' group. The owner refused that cure on the
spot: patching the symptom.

**The mover breaks the tie.** `LayoutDevices.select` now takes the keyboard
the most recent `activelayout` event named — motion evidence, recorded by
the raw-event handler before the refresh it triggers, and never fed to the
anchor (the anchor stays learned from the seat's own flag; an event-fed
anchor is the panel reading its own echo, §34). When the mover IS the
anchor, the anchor's own live index answers and the sleeping twins get no
vote against it. When it is not — no mover yet, a sleeper that moved, an
anchor that may itself name a sleeper (ticket 64) — consensus + remembered
stand exactly as before: a device that cannot type must not drag the panel.

The compositor-side flip itself is upstream territory and is not addressed
here. What changed is that the panel follows it honestly: indicators, caps
and the vkb all go where the fingers went, and one Alt+Shift brings
everything back instead of being the only thing telling the truth.

## 60. A language is named in its own language

base.lst describes every layout in English — "Ukrainian", "English (US)",
"Italian" — and the panel used to print those strings straight onto the
header chip and the chooser rows. The owner's 2026-09-19 call: the name of
a language belongs to the language itself — English, Українська, Русский,
Italiano.

**One table, one resolver, two call sites.** The endonyms live in
`LanguageControl.js`, keyed by xkb layout code, curated (~45 codes — the
realistic seats; `tw` and `be` are deliberately absent rather than named
one side of their own question). `displayName(code, fallbackTitle)`
resolves endonym → base.lst title → uppercased code, and both render
sites — the chip's `activeLayoutName` and `menuEntries` — go through it,
so an exotic layout is never blank and the two never disagree. `us` and
`gb` stay distinct ("English" / "English (UK)") for seats carrying both.
Non-Latin scripts render through Qt's font fallback; the fallback chain
means a missing glyph can never take the name away entirely.

## 61. The 2026-09-19 audit: availability is part of the same-user boundary

An external review of `31b1b46` found five issues; four were ours, one was
already resolved by the release-metadata commit that followed it. All four
share one shape — well-tested components failing at the HANDOFF between
them — and all four are fixed with their failure mode locked in tests:

- **Malformed input never reaches xkbcommon.** An interior NUL in any RMLVO
  field (or a custom keymap's text) hit xkbcommon's CString conversion,
  which panics — under the shared lock. The poisoned mutex left the helper
  alive but dead to every later `lock().unwrap()`, and systemd never
  ordered the restart. Both doors refuse it now: `parse` drops a configure
  carrying a NUL, `compile_keymap` refuses any unclean field, and the
  refusal is exactly a failing compile.
- **Custom keymaps are read once, bounded.** The mark and the compile each
  read the whole `kb_file` unbounded under the lock — a huge file spent
  memory, a FIFO blocked the keyboard for everyone. `read_kb_file_bounded`
  requires a regular file ≤ 2 MiB, takes the limit plus one byte, and its
  one read feeds both the mark and the compile.
- **Deadlines fire on traffic.** The handshake window and the hold cap
  were enforced only when a read timed out; a client streaming frames
  never paused long enough, and replies had no write bound at all. Both
  deadlines are now evaluated every iteration regardless of traffic, and
  every reply is bounded — a timed-out write drops the connection instead
  of parking the thread.
- **Clipboard cancellation kills the group.** The R2 memory-bound
  pipelines run as `setsid bash -c "wl-paste | head -c N"`, making the
  direct child a session leader; cancellation kills the whole process
  group. The old `signal(9)` reached only the shell and left the pipeline
  orphaned with stdout open, one stalled reader per attempt.

Finding 5 (the v0.1.2 package checksum) was the release-metadata flow
working as designed — `sha256sums=('SKIP')` in-tree, the real tarball hash
in the release notes — and `tools/check-release.sh` now gates the whole
contract mechanically: pkgver == manifest version == pushed tag, release
notes carrying the real hash, `.SRCINFO` fresh. The audit's structural
advice (integration-boundary suites, splitting the 11.5k-line trio,
shortening orientation) is recorded as follow-up, deliberately behind
these reliability fixes.

## 62. The review's second round: the descriptor is the truth

Two P2 refinements of §61's own fixes, both real:

- **Open, then validate.** `read_kb_file_bounded` stated the path and then
  opened it — two resolutions, and a FIFO swapped in between parked the
  thread under the shared lock. The open now comes first and NONBLOCKING
  (a FIFO opens instantly), and the fstat that gates size and regular-file
  shape runs on the DESCRIPTOR: what is read is exactly what was checked,
  and no by-name check can be raced.
- **Deadlines between commands.** The window and the hold cap were checked
  between reads, not between the commands one buffered chunk can carry —
  a burst paced past five seconds could still land its late `hello`.
  Both deadlines are now evaluated inside the dispatch loop as well, and
  a reply's write bound is the REMAINING window while the handshake is
  open (`reply_bound`): a parked write can no longer carry a late hello
  home.

## 63. The review's third round: completion means the counterpart answered

Six findings, all fixed; the theme is that a handoff is not done until the
other side of it has answered:

- **A chord completes on the helper's ack, not on the panel's write.** The
  next queued emoji's publication used to race a destination that had not
  received the paste yet — both records said success while a delayed
  consumer could paste the second payload twice. The chord's success now
  settles on the helper's acknowledgement of its final line (one slot,
  guard-timered; socket death and rebuild settle it as a cancellation).
  Residual, stated plainly: the ack says the events reached the
  compositor, not that the client processed them — a protocol-level
  paste-confirmed reply is the only stronger answer, and it does not
  exist yet.
- **A stalled verify drops instead of wedging.** The emoji verify read had
  a byte cap but no deadline: an owner that never finishes stalled the
  transaction while picks accumulated. A 3 s watchdog group-kills the
  read and drops the pick (the five-mismatch shape), and the queue behind
  a running pick is capped at three — the fourth is refused at the door.
- **A custom keymap's groups are the file's.** The configure's group
  ceiling used the layouts string; a one-layout string over a two-group
  custom map refused a legal group. The ceiling now comes from the
  compiled keymap itself (`num_layouts`), asked directly.
- **The frame cap is per line, not per batch.** Coalesced complete
  commands in one chunk were refused as "too long"; the cap is measured
  on the tail without its newline — the one line still growing.
- **`\x00`, never `\0` before a digit.** The test literal `"pc10\05"`
  parsed as octal `\x05`, not a NUL — exactly the ambiguity the CI lint
  names. All test NULs are explicit hex now.
- **The AUR recipe is generated, not hand-copied.**
  `tools/make-aur-recipe.sh` emits the AUR PKGBUILD with the real tag
  checksum substituted for the in-tree SKIP — release notes document,
  makepkg enforces. The README's clone placeholder is the real URL.

## 64. The review's fourth round: correlate, don't approximate

Round three's fixes were half-right; round four named the halves:

- **The chord waits for ITS OWN last ack.** A single awaiting slot settled
  on the first `ok` of the burst — the Ctrl press's, before the paste key
  itself. `ChordAcks.js` now keeps the ledger the ordering actually gives:
  plain commands (`down|up|mods|group`) sent minus `ok`s received, counted
  at the one send choke point; the chord settles when the ledger drains to
  zero while it waits, so an interleaved click delays the drain (safe)
  and nothing settles early. A dying connection settles the wait as a
  cancellation and zeroes the ledger — oks owed by a dead socket never
  come. The residual stands as stated in §63: the ack says the compositor
  has the events, not that the client read the clipboard; a
  paste-confirmed protocol reply is the only stronger answer.
- **Cancellation kills the read, not just the machine.** `cancelEmojiPublish`
  now stops both verify timers and group-kills a stalled pipeline — a
  cancelled transaction's watchdog, correctly seeing no live machine, used
  to leave the process running.
- **One snapshot validates and installs.** The group ceiling and the
  install each read the `kb_file`; a swap between the reads validated one
  file and installed another. `install_config` takes the caller's bytes —
  the same bounded snapshot that answered the ceiling question.
- **A complete line is capped before it is parsed.** The per-line cap
  moved after dispatch measured only the newline-less tail, so a finished
  5 000-byte line walked through untouched. The dispatch loop now refuses
  any complete line over the cap, leaving the reply-and-close to the tail
  check.

## 65. The review's fifth round: the package is part of the feature

Two blockers, both mine:

- **A runtime module the package did not carry.** ChordAcks.js shipped in
  the checkout but not in `PLUGIN_RUNTIME` — the packaging check failed,
  and a package built past it would not load the keyboard at all. The
  Makefile list is amended; the stage target verified carrying the file.
- **An err'd command used to occupy the correlation slot forever.** The
  ledger drained only on `ok`; a `group`/`down` answered with an err left
  the entry stuck past the guard timeout, and every later chord "failed"
  while the pastes themselves worked. ChordAcks is a command QUEUE now:
  every sent command occupies a slot, every reply line — ok, err, fact,
  generation — pops the oldest (the helper answers strictly in order),
  and the chord's verdict rides on the pop of its own final line:
  success only when that reply is a bare `ok`. A reply on an empty queue
  answers one of the few bypassed reconnect writes, sent only when the
  queue is known empty.

## 66. The review's sixth round: stale markers and bypassed sends

Two correlation defects, both reproduced by the reviewer on the module
itself:

- **A timed-out chord's marker outlived its wait.** `chordSettled` cleared
  the callback but kept the queue's `chordFinal` mark, so the late replies
  of the DEAD chord popped a marked slot and settled whatever chord waited
  NEXT — declared complete with two of its own commands still unacked.
  Arming and settling both strip every existing marker now: one chord
  waits at a time, so any earlier mark is stale by definition.
- **The hello, the reconnect `mods 0` and `keyboards` bypassed the choke
  point.** Their replies still popped queue slots, so a re-handshake with
  commands unanswered misattributed the pop. Every command on the
  connection — hello included — now goes through `sendCommandUnchecked`
  and occupies its slot like everything else.

## 67. The review's seventh round: whose pasting is it

Four findings, all confirmed against the tree:

- **A cancelled chord's verdict cannot complete the next pick.** The
  transaction machine answered "pasting" without saying WHOSE — a
  cancelled A's delayed reply recorded a live B as successful
  mid-dispatch (the reviewer reproduced it on the modules). The verdict
  now carries the seq it was armed for, captured at dispatch, and a seq
  that is not the machine's own lands stale; cancellation also clears
  the armed chord wait outright.
- **The packaging gate never rode behind the QML type check again.** CI
  installed no Quickshell, so qml-check.sh exited 0 early — skipping the
  handler check AND the package file-set check that lived behind it,
  which is exactly how round five's ChordAcks PLUGIN_RUNTIME miss sailed
  through green. The file-set check is its own script (needs only git
  and the Makefile), CI installs quickshell from extra, and the handler
  check's skip is loud and labelled.
- **Handshake is a gate, not a suggestion.** Commands used to execute
  before any `hello` and after a version refusal; now nothing but a
  matching hello runs pre-handshake — one `err hello first` per line,
  the slot's window still absolute.
- **The sound lookup splits XDG paths on ':' properly** (read -ra), not
  by ':'→' ' substitution that broke any entry containing a space.

Released as v0.2.1 with the rounds five–six hardening that had landed
after v0.2.0.

## 68. The review's eighth round: the fixes' own clients

Three gaps in the round-seven fixes, all real:

- **Doctor negotiates.** The hello gate broke oskar doctor's query
  clients: fresh connections sending `caps`/`keyboards` bare got
  `err hello first` and doctor read it as a broken keymap, recommending a
  shell restart on a healthy machine. Every query now hellos on its own
  connection and reads the second reply line.
- **The chord's success is the region's, not the last line's.** A keymap
  without Insert ERRed both Insert commands while the final Shift
  release answered ok — and the chord recorded success for a paste that
  delivered nothing. `chordStart` marks the region at dispatch entry and
  any non-ok popped inside it poisons the verdict; pre-chord traffic
  does not count, an interleaved err does (conservative by choice).
- **The gates enumerate the filesystem.** Both checks walked
  `git ls-files`; a release archive carries no .git, the enumeration
  came back empty, and both blessed whatever they were handed — the
  reviewer slipped invalid QML and a gutted PLUGIN_RUNTIME past them.
  find-based enumeration now, and an empty enumeration is a failure,
  never a pass. Verified in a fresh v0.2.1 archive: clean passes,
  sabotage fails both.

## 69. The review's ninth round: overlaps, not machines

The reviewer named the recurring weakness — the suites exercise each
state machine alone, and the defects live where two operations overlap.
Three overlaps, all reproduced by controlled event ordering:

- **A share run records only the generation IT launched.** A newer
  keymap arriving mid-run used to overwrite the running process's
  target; the old run's success then marked the NEW generation shared
  and the required clear-and-set rerun never happened — the compositor
  compiling yesterday's bytes while the keyboard typed today's.
  `launched` is immutable per run; `wished` moves; the guard reruns for
  anything newer.
- **A second paste click refuses instead of resetting.** chordStart ran
  at dispatch entry without asking whether a chord was already in
  flight — clicking the paste chip mid-chord wiped the running chord's
  error tracking and could turn its failure into success. pasteCurrent
  refuses clean while another chord paces or awaits its verdict, and
  nothing of the first's tracking is touched.
- **Cancellation aborts the pacer.** A mode flip cleared the
  transaction and the chord wait but left the Wine/Proton tick timer
  running — the next tick sent the V press onto a Ctrl the cancelled
  chord still held. cancelEmojiPublish aborts the paced paste (whose
  own path compensates the sent prefix and releases the world) before
  clearing the wait.

All three are wiring-level — the host suites cannot reach them; the VM
integration suite (delayed replies, cancel-then-retry, disconnects)
stays the recorded answer to the named weakness.

## 70. The integration seam runs again, and it grew the overlap contract

The VM integration suite had not run since nested-session.sh's workdir
pattern changed (the smoke guard still matched the old osk-nest.<pid>
name and refused every launch); the guard now matches the session's
actual mktemp shape. In the lab, against the REAL helper under a nested
Hyprland, 39 tests pass — 34 existing and five new ones pinning the
review rounds' overlap contract on the live socket:

- nothing executes before a completed matching hello, and a refused
  version never opens the door (round seven);
- coalesced commands in one write are each answered, in order, an err
  spending exactly its own slot — the FIFO the panel's correlation
  queue is built on (rounds three and five);
- a complete 5 KiB line and a newline-free 5 KiB tail are both refused
  and the connection closed (rounds three and four);
- the pre-handshake window is absolute under continuous traffic: a
  hello-less connection streaming frames is dropped at the window, not
  when the traffic pauses (round two);
- a stalled reader is dropped by the write bound within its deadline
  and the helper keeps serving the next client (rounds one and two).

The harness learned `negotiate=False` (raw clients, for the gate tests),
`read_line` (drain without send), and a close that tolerates a dead
socket. This is the machinery the reviewers kept asking for; the seams
now have a wall of their own.

## 71. The review's tenth round: the wish is consumed; the plan begins

Three findings; the first is the opening cut of the approved seams plan:

- **ShareQueue.js.** Round nine captured the generation per run but let
  the success handler return with `wished` unconsumed — the newest map
  sat unshared, nothing running, nothing retrying (the reviewer's
  reproduction). The share scheduler is now the pure module the plan
  called for: ack launches for a generation (at-or-below-shared and
  stale acks are no work at all — its own suite caught the module
  relaunching an already-shared gen on a stale ack), a newer
  generation mid-run only updates the wish, success shares what the
  run launched AND schedules the pending wish immediately, failure
  keeps the run for the caller's retry, the five-attempt give-up
  releases the slot (a fresh map may succeed where the old one could
  not), and the displaced path voids only the shared record. Six
  overlap tests; the panel keeps only the Process plumbing.
- **`oskar status` survives a dead transport.** The probe's nonzero
  (stale socket, timeout) killed the report under `set -e` before any
  output; the failure now reads as the "not answering" line it always
  meant to be.
- **Private means 700/600, enforced.** The panel's config/state
  directories were mkdir'd 755 and their JSON written 644 — the
  documented private posture existed only in prose. `install -d -m 700`
  plus a post-save `chmod 600`, umask-independent, healing existing
  installs on their first save (the owner's were healed by hand).

## 72. PasteFlow: the paste lifecycle is a module, and the agent audit earned its keep

The plan's second cut (after ShareQueue): the paste orchestration —
busy-gate, region boundary, ordered cancellation — left the QML glue
and became PasteFlow.js, a four-phase lifecycle (idle → dispatching →
paced/awaiting → idle) whose cancel answers an ordered program the glue
executes. Rounds seven through nine's semantics are its transitions;
five host tests hold the overlaps.

The owner asked for a second, independent pass before shipping, and it
found a blocker both of the author's own reviews missed: the paste chip
calls with no callback, and the direct path entered `awaiting`
unconditionally while `settleChordThroughHelper(null)` returns early —
nothing armed, no guard timer, no exit. One paste-chip click into any
non-wine window would have bricked every later paste for the session.
The paced path had guarded `done && success` all along; the direct path
now does the same — a callback-less paste is fire-and-forget, the gate
reopening when the writes return. Two smaller tightenings from the same
audit: the tick's empty-lines arm routes through the one exit, and the
cancel's defensive dispatching answer no longer disturbs a live region
ledger.

The audit's own lesson, recorded with the author's: the suite tests the
module, not the composition — the blocker lived exactly in that gap,
and a second reader reading the composition cold is what caught it.

## 73. Round eleven: two cold auditors, the daemon's long-held lock

The owner's cold-audit pass — two agents, panel and daemon — returned a
SAFE-to-ship panel with four small finds and a NOT-safe daemon with two
blockers, both the same disease the rounds kept circling: work done under
the shared lock that should never have held it.

- **The panel finds, fixed:** killed clipboard probes applied their stale
  bytes under the new sequence (the chip showed A while the clipboard
  held B) — every kill-restart process now carries the local read's
  retiring discipline; the emoji verify's late stream could verify the
  wrong pick (same fix); a relayout nudge arriving mid-chain was dropped
  instead of queued (ticket 30's symptom lived in that window); and the
  private 600/600 landed after the fact — saves now go through one
  umask-077 temp+rename, private at creation, no window.
- **Blocker: the keycode span.** A 60-byte keymap declaring a keycode
  near u32::MAX made the keycap walk iterate ~9 s of CPU under the lock
  per configure — the panel could not even reconnect (its hello blocked
  past the handshake window). Both compile doors refuse keymaps beyond
  4096 now (stock evdev tops at 709), which is what bounds the span
  walk; a text-level named-keys walk was tried and reverted —
  include-based keymaps carry no declarations to parse.
- **Blocker: pacing under the lock.** A delivery's sleeps held the lock
  ~2 s per command; a pipelining connection kept it held indefinitely
  and every keystroke lagged behind it. Deliveries now run lock-free
  between beats with a `delivery_active` flag; every other command,
  plus the stuck-key cap and disconnect releases, waits the delivery out
  (bounded), and hello was never blocked to begin with.
- **Riding the same pass:** transient keymap uploads pay a looser
  20-per-10s budget; identical reconfigures skip the ceiling compile
  (the installed map's own count is the ceiling that fits it) and
  compile ATTEMPTS pay the churn budget, failed parses included; a
  failed restore retries once and then invalidates the install's
  generation so the panel re-syncs; a departing connection only zeroes
  the modifier mask if it actually lifted something; empty lines answer
  `err empty` (the one-reply invariant has no silent case); a refused
  post-handshake hello never de-negotiates; the key-drain stamps like
  every other release; and a failed client spawn drops the client
  instead of exit(70) past every release path.

The lab suite grew with it: 40 tests, the new one holding the
empty-line answer. The harness's own newline append collided with the
new honest reply — the batch test taught the harness not to manufacture
empty lines it did not mean to send.
