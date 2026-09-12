# Patches

Local patches the OSK carries against installed Omarchy packages until they
are upstreamed. Local-first directive: the fix lands here first, the
external repo follows.

## omarchy-shell-style-live-rounding.patch

**What it does.** Adds one event-driven trigger to the shared shell style
singleton (`Commons/Style.qml`, a QtObject singleton): a `Connections` on
Quickshell's `Hyprland` object watching socket2 for `configreloaded`, the
same idiom the shell's own keyboard-layout bar widget uses. On every applied
Hyprland config reload — sourced-file changes, `hyprctl reload`, omarchy's
own toggles — Style re-runs its existing `hyprctl -j getoption` pair after
the 200 ms settle beat (`scheduleRefresh`), so `Style.cornerRadius` (and
`gapsOut`) update live in a running shell. No polling; Quickshell 0.3.1
never re-reads QML on its own, so without this the shell samples rounding
once at startup and ignores config reloads.

Every Style consumer follows automatically. The OSK reads the token only
through its Theme facade, whose radius overrides (ticket 10) keep winning:
the binding is `override ?? Style.cornerRadius`, proven under a live
refresh in ticket 11's evidence.

**Applies to.** `omarchy-dev 4.0.0.r2015.g4930677-1`, file
`/usr/share/omarchy/shell/Commons/Style.qml` (verified by dry-run; applied
on this machine 2026-09-05). Neighbouring omarchy-dev revisions that keep
this file byte-identical will also take the patch; `patch` refuses
otherwise, which is the intended safety.

**Apply.**

```
cd /usr/share/omarchy/shell
sudo patch -p1 < /path/to/omarchy-osk/patches/omarchy-shell-style-live-rounding.patch
```

(the patch path is repo-absolute — the shell directory you `cd` into holds
no `patches/`, and a relative path there reads as a missing file). The change
takes effect at the next shell restart — Quickshell 0.3.1 does not hot
reload, and restarting the shell is deliberately not scripted here.

**Restore.**

```
sudo pacman -S omarchy-dev          # package reinstall restores pristine
# or, without reinstalling:
cd /usr/share/omarchy/shell && sudo patch -R -p1 < .../omarchy-shell-style-live-rounding.patch
```

**Upstream.** Post-board follow-up: propose the same hunk (import
`Quickshell.Hyprland`, one `property Connections hyprlandEvents`
calling `scheduleRefresh()` on `configreloaded`) in the omarchy shell
repository; once landed upstream this file and the pacman reinstall note
here become obsolete.

## omarchy-shell-emoji-osk.patch

**What it does.** Opt-in OSK cooperation for the shell emoji overlay
(`omarchy.emojis`). Ordinary standalone invocation (`omarchy-menu-emoji`,
Super+Period, bar) is unchanged: fullscreen Exclusive, centred card,
backdrop dismiss. An `{"osk":true, output, workArea, band}` summon payload
fits the inner card with vendored `PickerFit.planPlacement`, subtracts the
OSK band from the overlay input region, and primes Exclusive then OnDemand
so picker search receives virtual-keyboard input while OSK clicks land.
`shell isOpen` exposes the overlay's real open state. The overlay still
inserts through `omarchy-menu-emoji-insert`; the OSK does not paste again.

**Applies to.** `omarchy-dev 4.0.0.r2035.gf4a462e-1` (git `f4a462e`), files
`/usr/share/omarchy/shell/plugins/emojis/Emojis.qml`,
`/usr/share/omarchy/shell/shell.qml`, plus new
`/usr/share/omarchy/shell/plugins/emojis/PickerFit.js`. Neighbouring
revisions that keep those two files byte-identical will also take the
patch; `patch` refuses otherwise.

**Deployment scope.** Applied on the owner's desktop 2026-09-07 at their
request. Restart the shell after applying (`omarchy restart shell`).
`omarchy update` / `pacman -S omarchy-dev` restores stock files; re-apply
the patch afterwards if OSK overlay cooperation is still wanted.

**Apply.**

```
cd /usr/share/omarchy
sudo patch -p1 < /path/to/omarchy-osk/patches/omarchy-shell-emoji-osk.patch
```

**Restore.**

```
sudo pacman -S omarchy-dev
# or:
cd /usr/share/omarchy && sudo patch -R -p1 < .../omarchy-shell-emoji-osk.patch
```

### Why event-driven

Decisions §19/§20 forbid polling. Hyprland announces every applied config
on socket2; `configreloaded` is the exact signal for "re-read derived
tokens". Measured on Hyprland 0.56.2: `hyprctl reload` emits
`configreloaded`; runtime `hyprctl eval hl.config(...)` applies a value
silently (no socket2 event at all, and `hyprctl keyword` is refused outright
by the Lua parser), so no event-driven reader can follow bare eval changes
— that gap belongs to Hyprland, not to the shell.
