# omarchy-osk package notes (prototype)

This package installs the helper, its user unit and the runtime plugin
payload. It deliberately performs no activation: package files are
system-owned, activation is yours.

## Layout

- `/usr/lib/omarchy-osk/omarchy-osk-daemon` — the input helper
- `/usr/lib/systemd/user/omarchy-osk.service` — the user unit (already
  points at the packaged helper; `systemctl --user daemon-reload` after
  install/upgrade)
- `/usr/share/omarchy-osk/plugin/` — the runtime QML/JS/assets payload

## Activation (once, after install)

1. Register the panel (the dev-symlink shape is NOT proven for
   `/usr/share` registration; the supported route is the official one):

   ```bash
   omarchy plugin add https://github.com/Vladkarok/omarchy-osk.git
   ```

   or, for the packaged payload, link it where the shell scans plugins
   (experimental, see release plan §7):

   ```bash
   mkdir -p ~/.config/omarchy/plugins
   ln -s /usr/share/omarchy-osk/plugin ~/.config/omarchy/plugins/io.github.vladkarok.osk
   ```

2. Enable the helper:

   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now omarchy-osk.service
   ```

## Legacy migration

A source install (`install.sh`) leaves `~/.local/libexec/omarchy-osk-daemon`
and `~/.config/systemd/user/omarchy-osk.service`. The user unit directory
OVERRIDES the packaged unit: remove both after installing this package,
or the old helper keeps running:

```bash
systemctl --user disable --now omarchy-osk.service
rm ~/.config/systemd/user/omarchy-osk.service
rm ~/.local/libexec/omarchy-osk-daemon
systemctl --user daemon-reload
systemctl --user enable --now omarchy-osk.service
```

Config and state (`~/.config/omarchy-osk`, `~/.local/state/omarchy-osk`)
are yours and survive everything.

## Removal

Disable FIRST, then remove — the enable symlink points into the
package, and `pacman -R` alone leaves it dangling (measured: the next
login then starts nothing):

```bash
systemctl --user disable --now omarchy-osk.service
sudo pacman -R omarchy-osk
```

A running helper survives removal (it stops with the session; the above
`--now` stops it immediately). Plugin registration and your
config/state are untouched.
