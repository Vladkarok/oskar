# Input backend and distribution: upstream research

Checked 2026-09-06 against upstream source, GitHub/GitLab APIs and project
installation scripts. Research only: no application, desktop configuration,
ticket status or implementation plan was changed. Existing uncommitted changes
were preserved. Issue reports below are evidence of reported behavior, not a
substitute for reproducing every issue on the current compositor.

## Conclusions

Rust specifically is not required. The current QML interface needs an input
backend capable of the Wayland virtual-keyboard protocol. That backend can be a
separate process, a native QML module, or a feature supplied by Quickshell. Qt
supports exposing native C++ objects to QML; moving the backend there changes
its lifetime and packaging, but does not remove native code or solve compositor
layout semantics by itself. [Qt documentation](https://doc.qt.io/qt-6/qtqml-cppintegration-definetypes.html),
[Quickshell Wayland modules](https://github.com/quickshell-mirror/quickshell/blob/master/src/wayland/CMakeLists.txt).

The current process boundary is therefore a reasonable implementation choice,
not a fundamental Linux requirement. The helper's persistent complete keymap,
key ownership and disconnect cleanup are useful behavior that any replacement
must retain. Historical latency, XWayland failures and feedback-loop measurements
are recorded in [decisions.md §§1–3](decisions.md); they were not independently
remeasured in this research.

Hyprland also has compositor IPC injection, so “QML can never send input
without its own native backend” would be too absolute. However, the inspected
[`sendKeyState` / `Actions::pass` implementation in v0.56.2](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/config/shared/actions/ConfigActions.cpp#L1529)
sends client keyboard events directly and supplies group zero, rather than
following the normal compositor keybind path. It is not a drop-in replacement
for an OSK that must trigger compositor Super shortcuts and retain layout and
held-key semantics. A fuller compositor injection API is another possible
upstream approach, with its own behavioral contract to establish.

There are three separate improvement targets:

- **Quickshell:** expose a supported virtual-keyboard API to QML, including
  keymap, group, modifiers and key press/release lifetime.
- **Hyprland:** provide reliable current-keyboard/layout events and coherent
  layout state for devices intended to act as one keyboard. Prefer an explicit
  opt-in grouping policy to destroying intentional per-device configurations.
- **Our package and Omarchy plugin lifecycle:** install/update/remove the input
  backend with the visible plugin. A separate process does not require users to
  build Rust or manually manage systemd.

Nothing inspected points to a missing Linux-kernel feature as the cause of
these integration problems. The relevant state and APIs are in the compositor,
shell framework, and package/plugin integration. Kernel/uinput injection would
be another backend with its own device permissions and lifecycle, not a fix for
the existing QML or compositor interfaces.

## Current installation and removal gap

Our [install.sh](../install.sh) requires Cargo, builds the helper and installs
`~/.local/libexec/omarchy-osk-daemon` and a systemd user unit. Our
[uninstall.sh](../uninstall.sh) stops/disables and removes those artifacts; it
does not remove the Omarchy plugin itself. The inspected Omarchy plugin
add/remove path handles plugin files and shell IPC, without invoking these
scripts. Removing the plugin therefore does not currently guarantee removal of
its helper, and also removes the plugin's own uninstall script.
[Omarchy plugin documentation](https://github.com/basecamp/omarchy/blob/quattro/manual/32-shell-plugins.md).

[Omarchy PR #9557](https://github.com/basecamp/omarchy/pull/9557),
“Allow plugins to specify package dependencies (optional + required)”, was
opened September 1, 2026 and remains **open, unmerged**. Its inspected changes
cover dependency declarations and add/validation behavior; they do not provide
complete dependency removal or user-service lifecycle management. Treat it as
relevant progress, not an already available installation/uninstallation fix.

Recommendation: distribute a prebuilt Arch package, make the plugin's install,
update and removal workflow own the backend lifecycle, and verify the complete
round trip in the VM. This is a proposed distribution path; no such complete
package/integration was created by this research. Keep user colour/layout
preferences separate from disposable installed artifacts.

## Quickshell status

| Upstream item | Verified status | What it covers |
| --- | --- | --- |
| [Issue #528: No way to get keyboard layout](https://github.com/quickshell-mirror/quickshell/issues/528) | Open | Layout discovery, not synthetic key injection. |
| [PR #923](https://github.com/quickshell-mirror/quickshell/pull/923) | Open, unmerged; updated August 29, 2026 | Hyprland keyboard-layout tracking/switching. The inspected active-keyboard tracking follows the last `activelayout` event, so it must not automatically replace our physical-device selection policy. |
| [PR #195](https://github.com/quickshell-mirror/quickshell/pull/195) | Closed January 23, 2026, unmerged | Input-method work; the author points to Wayland protocol work below. It is not a shipped full virtual-keyboard API. |

The inspected Quickshell master Wayland module list has no virtual-keyboard or
input-method module. A native module could remove our socket/service boundary
if its API satisfies the keyboard's full behavior. That would be a separate
design and migration task, not a reason to delete the tested backend now.

## Hyprland status and useful prior art

| Upstream item | Verified dates/status | Relevance and limit |
| --- | --- | --- |
| [#6298: IPC: improve activelayout event](https://github.com/hyprwm/Hyprland/issues/6298) | Opened June 1, 2024; closed April 5, 2025 as not planned during migration to discussions | Ambiguous comma-separated keyboard/layout names; comments request a layout index and discuss pseudo/virtual keyboards. Closure is not evidence of a fix. |
| [#6589: hyprctl switchxkblayout followed by wtype behaves in a strange way](https://github.com/hyprwm/Hyprland/issues/6589) | Opened June 19, 2024; closed April 5, 2025 during migration to discussions | Historical virtual-keyboard/hotplug and effective-layout disagreement. No current comprehensive fix was established by this search. |
| [#8409: Main keyboard choosing the wrong one, can't set one manually](https://github.com/hyprwm/Hyprland/issues/8409) | Opened November 10, 2024; closed April 5, 2025 as not planned | Main-device selection and keyd/device switching. Related to reliable layout discovery; does not itself specify OSK grouping. |
| [#15897: send_key_state resolves keys against the main keyboard…](https://github.com/hyprwm/Hyprland/issues/15897) | Opened August 19, 2026; automatically closed nine seconds later | Minimal client-supplied keymaps can break key-name lookup. Bot asks to open a discussion; this was neither a shipped fix nor a technical rejection of the proposed behavior. |
| [PR #8276: seat: avoid sending pointless keymap and repeat_info events](https://github.com/hyprwm/Hyprland/pull/8276) | Merged October 28, 2024 | Real upstream improvement suppressing redundant events/lag. In #6589 the author explicitly says it does **not** fix that multi-keyboard/wtype case. Do not describe it as a complete OSK fix. |

[Sway's current manual](https://github.com/swaywm/sway/blob/master/sway/sway-input.5.scd)
documents default `keyboard_grouping smart`: devices with matching keymaps and
repeat information share effective layout. This demonstrates that coherent
grouped layout state is implementable at compositor level. It does not prove
all OSK/IME devices should be merged into that group.

Correction to the blanket wording in our historical upstream queue: Sway's
[xkb_switch_layout implementation](https://github.com/swaywm/sway/blob/master/sway/commands/input/xkb_switch_layout.c)
skips virtual keyboards **when their keymap is null**; it does not blanket-skip
every virtual keyboard. Any Hyprland proposal should specify device/group
membership and IME behavior explicitly.

## Why input-method support alone is insufficient

Text input and physical-key emulation overlap but have different contracts.
Text-input offers text composition/commit and field context. A complete OSK
also needs shortcuts, held modifiers, navigation and applications that do not
participate in text-input. Do not assert that all XWayland input methods are
impossible: bridges such as XIM/toolkit IME integrations are a different path.
The narrow conclusion is that replacing our backend with text commits alone
does not establish coverage of our full keyboard contract.

Current Hyprland
[InputMethodRelay.cpp](https://github.com/hyprwm/Hyprland/blob/main/src/managers/input/InputMethodRelay.cpp)
rejects a second concurrently registered input method, and its IME commit path
requires a focused TextInput. An OSK registered as another IME must therefore
address coexistence with fcitx5 rather than assume it is an independent second
keyboard. A virtual-keyboard backend and an input-method backend are not
interchangeable merely because both can enter letters.

| Wayland protocol item | Verified status | Actual scope |
| --- | --- | --- |
| [MR !405: DISCUSSION: input-method](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/merge_requests/405) | Open, unmerged; opened May 8, 2025, updated August 3, 2026 | Standardizing text-input's compositor-to-IME counterpart. The author deliberately removed keyboard-related pieces and popup support from this proposal. Not a ready replacement for virtual-keyboard input. |
| [Issue #209: keyboard layout semantics are not very defined](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/issues/209) | Open; opened August 26, 2024 | Layout semantics for accelerators, especially non-Latin layouts. Related multilingual problem, not a seat-layout synchronization proposal. |
| [Issue #296: Proposal: Per-window keyboard layout protocol for Wayland](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/issues/296) | Closed November 10, 2025; opened November 8 | Per-window behavior, unlike our owner's global-layout preference. Do not revive it as though it were an existing OSK/global-state proposal. MR !296 is an unrelated alpha-modifier proposal. |

GitLab web rendering was unavailable through the browsing tool; titles, dates,
states and descriptions above were read through the primary GitLab API for
project 2891. Issue #296 comments returned HTTP 401, so this note does not claim
to know the technical reason for closure.

## Suggested order

1. Fix the installation/removal product flow without requiring an upstream
   redesign or user-side Rust compilation.
2. Retain the existing backend while consolidating keymap interpretation there,
   as proposed in the next-iteration plan.
3. Prepare a minimal, reproducible Hyprland discussion about current-device
   events, grouped layout state and IME/virtual-device membership. Existing
   issue closure is not enough to conclude the problem is fixed.
4. Evaluate a Quickshell native input API separately, with explicit Wayland,
   XWayland, shortcuts, modifiers, reconnect and layout-sync acceptance cases.

No upstream issue/comment/PR was submitted and no tickets were added or changed.
