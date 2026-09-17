# omarchy-osk package notes

This package installs the helper, its user unit, the runtime plugin
payload and one lifecycle command. Installation is files only — a
package hook runs as root and must not guess a user's session bus — so
activation is one explicit, idempotent user command:

```bash
omarchy-osk setup
```

## Layout

- `/usr/bin/omarchy-osk` — the lifecycle command (setup / upgrade /
  status / teardown)
- `/usr/lib/omarchy-osk/omarchy-osk-daemon` — the input helper
- `/usr/lib/systemd/user/omarchy-osk.service` — the user unit (already
  points at the packaged helper)
- `/usr/share/omarchy-osk/plugin/` — the runtime QML/JS/assets payload

## The lifecycle

- **`omarchy-osk setup`** — preflight dependencies; register exactly
  `/usr/share/omarchy-osk/plugin` under the stable plugin id
  `io.github.vladkarok.osk`; rescan; enable the plugin through the
  official Omarchy commands; daemon-reload; enable/start the user
  service. Idempotent: on an already-correct setup it converges (it may
restart a healthy helper in a live session; the end state is the same). A source
  install's `~/.config/systemd/user` unit overrides the packaged one —
  setup refuses while it stands and `setup --migrate-source` moves it
  aside (kept, renamed `*.migrated-<timestamp>`) and removes
  `~/.local/libexec/omarchy-osk-daemon`.
- **`omarchy-osk upgrade`** — after a package update: daemon-reload,
  restart the helper in a live session, restart the shell so the
  keep-loaded panel reloads its QML. Reports each phase; safe to rerun.
- **`omarchy-osk status`** — payload, registration target, plugin
  enabled state, unit enabled/active, socket presence, protocol
  compatibility. Read-only.
- **`omarchy-osk teardown`** — disable the plugin through Omarchy,
  disable/stop the unit, unlink the registration — but only a
  registration whose target is the packaged payload (a git clone or a
  developer checkout is left untouched). Config
  (`~/.config/omarchy-osk`) and state (`~/.local/state/omarchy-osk`) are
  the user's and survive everything, including removal.

## Source installs

A checkout lives on the same command: `install.sh` installs the helper,
the user unit, and links `bin/omarchy-osk` into `~/.local/bin`, where it
manages that checkout (payload = the checkout, helper = `~/.local`).
Both worlds never coexist silently — see `setup --migrate-source`.

## Dependency contract

Hard: `omarchy` (the shell this panel is built for), `hyprland`,
`quickshell`, `jq`, `wl-clipboard` (the paste chip and the
clipboard-compatibility emoji route execute `wl-copy`/`wl-paste`),
`libxkbcommon` (the helper links it), `gcc-libs`, `glibc`. Optional:
`qt6-multimedia` and `ffmpeg` together provide the key-click sound.

## Proven

The full acceptance choreography (clean install → status → setup ×2 →
protocol → upgrade → teardown ×2 → reinstall → legacy source migration →
cold boot, plus a clean-chroot build and namcap/ldd inspection) runs
green in the lab VM via `tools/package-test.sh <phase>`; the 2026-09-13
run is recorded on ticket 32.

## Publish-day checklist (owner-gated)

- [ ] RENAME FIRST (ticket 59): the tree ships as `oskar` — package,
      plugin id, service, paths, strings — before the public push.
      The GitHub repo is created/renamed to `oskar` at publish; the
      council's record and collision checks live in
      .scratch/next-iteration/evidence/naming-council/.

- [ ] README's `<REPOSITORY-URL>` placeholder in the Install section
      replaced with the public clone URL (added by the ticket-47
      review; a stranger could not acquire the tree without it).
- [ ] The AUR path promoted to primary in README's Install section.
- [ ] F7 hygiene: after `pacman -R omarchy-osk`, no unowned files may
      remain under /usr/share/omarchy-osk (the 0.1.0-2 pkgrel once
      left LanguageControl.js/HoldColumn.js behind — file-list drift
      between pkgrels; verify with `pacman -Ql` vs the tree before
      tagging — `omarchy-osk doctor` names any strays in its
      version-drift check).
- [ ] Fresh-lab-boot emoji legs re-run (ticket 44's lab anomaly: the
      churned lab's Hyprland drops post-first keymap uploads; the host
      is exonerated by live evidence).
