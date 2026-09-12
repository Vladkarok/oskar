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
then layout progress. **Switching** only accepts the first two tiers;
with no positive evidence the language button greys out rather than
guessing, because advancing a guessed device is what poisoned the seat
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
`BarWidget.qml` 11 of 13, `Panel.qml` 146 of 179, `Keyboard.qml` 341 of
529, `KeyboardLayout.js` 115 of 279. The daemon, `systemd/` and `tools/`
share nothing and never did. So the split was clean and the claim was
not: **the input path is ours, the shell layer is his.**

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
- Running the helper against the session you are working in.
- Rewriting the shell layer as a standalone pass with no behaviour change
  to test against, or renaming identifiers to lower the overlap count
  instead of rederiving the design (§14).
