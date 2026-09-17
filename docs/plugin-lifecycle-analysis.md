# Third-party Omarchy plugin lifecycle

Research baseline: 2026-09-09. The installed `omarchy-dev`
`4.0.0.r2092.g5ead870-1` sources checked here are byte-identical, for every
plugin-management file cited below, to official Omarchy commit
[`5ead870507df`](https://github.com/basecamp/omarchy/tree/5ead870507dfb68db696b3ddb948cc3d178e8d62).
This report distinguishes the published contract, observed behavior of that
implementation, and recommendations for `oskar`.

## Official contract

### Location, identity, and manifest

A third-party plugin is a Git repository with `manifest.json` at its root.
`omarchy plugin add <git-url>` stages, validates, then moves it to
`~/.config/omarchy/plugins/<manifest-id>/`; a hand-installed plugin uses the
same final directory. It is user-owned source, not a package-owned file under
`/usr/share/omarchy`. See the official
[shell guide](https://github.com/basecamp/omarchy/blob/5ead870507dfb68db696b3ddb948cc3d178e8d62/shell/README.md#installing-a-third-party-plugin)
and installed source `/usr/share/omarchy/bin/omarchy-plugin-add`.

The enforced schema is version 1. Required fields are `schemaVersion`, `id`,
`name`, `version`, non-empty `kinds`, and object `entryPoints`. A third-party
ID must match `[A-Za-z0-9][A-Za-z0-9._-]*`, contain no `..`, and not use the
reserved `omarchy.*` namespace. Every entry point must be a non-empty,
existing, relative file path with no `..` or newline. Each recognized kind
requires its named entry point: `bar:bar`, `bar-widget:barWidget`, `menu:menu`,
`overlay:overlay`, `panel:panel`, and `service:service`. Symlinks anywhere in
the plugin tree, except Git internals, are rejected. `barWidget.defaultSection`
may be `left`, `center`, or `right`. The executable contract is
[`omarchy-plugin-validate`](https://github.com/basecamp/omarchy/blob/5ead870507dfb68db696b3ddb948cc3d178e8d62/bin/omarchy-plugin-validate);
authors should run `omarchy plugin validate .` before publishing.

Omarchy, not Quickshell, defines this manifest. Quickshell supplies the QML
runtime; the official Omarchy guide defines supported kinds, entry-point host
injection, and capability-scoped third-party facades. There is no second
Quickshell package metadata file to install. See
[`shell/README.md`, “Plugin manifest”](https://github.com/basecamp/omarchy/blob/5ead870507dfb68db696b3ddb948cc3d178e8d62/shell/README.md#plugin-manifest).

The current `oskar` [`manifest.json`](../manifest.json) satisfies the
field-level rules: ID `io.github.vladkarok.oskar`, schema 1, `panel` and
`bar-widget` kinds, both entry points, and a valid right-side default.
However, the repository as a whole currently fails `omarchy plugin validate
.` because tracked `CLAUDE.md` is a symlink to `AGENTS.md`; a release installed
with `omarchy plugin add` will therefore be rejected until the symlink is
replaced by a regular file or excluded from the published plugin tree.
(`.agents/skills/board` is another working-tree symlink and would also fail if
included in a distributed tree.) `keepLoaded: true` is supported, but means
changes to a kept service instance require a full shell restart; it does not
install or supervise an external helper.

### Add and enable

Canonical installation is:

```bash
omarchy plugin add https://github.com/Vladkarok/oskar.git
# review the unsandboxed QML, then:
omarchy plugin enable io.github.vladkarok.oskar --section right
```

Interactive `add` warns that QML executes unsandboxed in the long-lived shell,
asks for confirmation, and leaves the plugin disabled for review unless the
user chooses enable. For automation, arguments plus `--yes` are required;
`--enable --yes` explicitly opts into loading it. The add command validates in
a hidden staging directory, rejects duplicate IDs and existing targets, moves
the completed checkout into place, rescans, then optionally enables. It never
runs plugin code, repository install hooks, or `sudo`. See the
[official install/security rules](https://github.com/basecamp/omarchy/blob/5ead870507dfb68db696b3ddb948cc3d178e8d62/shell/README.md#installing-a-third-party-plugin)
and
[`omarchy-plugin-add`](https://github.com/basecamp/omarchy/blob/5ead870507dfb68db696b3ddb948cc3d178e8d62/bin/omarchy-plugin-add).

Enablement is persisted by the shell in `~/.config/omarchy/shell.json`. A
bar-widget is inserted into `bar.layout.<section>`; other non-bar kinds go in
`plugins[]`; a full bar becomes `bar.id`. A multi-kind plugin containing a bar
widget, as OSK does, is enabled through its bar entry. Placement defaults to
`barWidget.defaultSection`, then center. `omarchy bar move` changes placement.
The shell owns atomic writes to this file. These storage rules are documented
in the
[official persisted-state contract](https://github.com/basecamp/omarchy/blob/5ead870507dfb68db696b3ddb948cc3d178e8d62/shell/README.md#persisted-state)
and implemented in `/usr/share/omarchy/shell/services/PluginRegistry.qml` and
`/usr/share/omarchy/shell/shell.qml`.

### Reload and restart

`omarchy-shell shell rescanPlugins` re-walks plugin directories. The shell also
watches `~/.config/omarchy/plugins/` and schedules plugin reload when files
change. Add/update/remove explicitly rescan. `shell.json` is watched and shell
IPC mutations apply immediately. The documented force operation is rescan;
the stronger fallback is `omarchy restart shell`. `omarchy refresh shell` is
not an update/reload command: it replaces user shell configuration from
defaults and is inappropriate here. See the
[official IPC contract](https://github.com/basecamp/omarchy/blob/5ead870507dfb68db696b3ddb948cc3d178e8d62/shell/README.md#ipc-contract),
`/usr/share/omarchy/shell/services/PluginRegistry.qml:663`, and
`/usr/share/omarchy/bin/omarchy-restart-shell`.

### Update

`omarchy plugin update <id>` manages only Git checkouts installed in the user
plugin directory. It fetches `origin HEAD`; an equal commit is a successful
no-op. Otherwise it shows a diff and confirms (unless `--yes`), performs an
FF-only merge, validates the result, resets to `ORIG_HEAD` if validation
fails, and rescans after any successful update. With no ID it processes every
Git-managed plugin. It does not update hand-copied/symlinked plugins,
dependencies, helper binaries, systemd units, or user data. See
[`omarchy-plugin-update`](https://github.com/basecamp/omarchy/blob/5ead870507dfb68db696b3ddb948cc3d178e8d62/bin/omarchy-plugin-update).

The managed-checkout assumption matters: add is intentionally not idempotent
(an existing ID says to use update), update is idempotent at the current
commit, and divergent/local changes may prevent the fast-forward. The
validation rollback uses `git reset --hard ORIG_HEAD`; users who want to edit,
pin, or branch the checkout are outside the simple managed path and must use
ordinary Git deliberately.

### Disable and remove

`omarchy plugin disable <id>` removes the third-party ID from `shell.json`.
For a bar widget this removes its complete inline layout entry, including
per-widget settings. Disable is therefore not a settings-preserving pause.

`omarchy plugin remove <id>` queries the running shell, disables the plugin if
enabled (thereby cleaning its persisted reference and unloading it), then:

- unlinks a symlink without touching its target;
- permanently deletes a Git checkout, on the premise that it remains upstream;
- moves a non-Git directory to a hidden timestamped backup beside the plugins;
- rescans the running shell.

An active clone of a built-in is replaced by its source plugin. The command
does not execute `uninstall.sh`, remove dependencies, services, helper files,
state, cache, or configuration outside the plugin directory. It also requires
a reachable running shell for its initial state query; it is not a headless
filesystem cleanup tool. See
[`omarchy-plugin-remove`](https://github.com/basecamp/omarchy/blob/5ead870507dfb68db696b3ddb948cc3d178e8d62/bin/omarchy-plugin-remove)
and
[`PluginRegistry.setEnabled`](https://github.com/basecamp/omarchy/blob/5ead870507dfb68db696b3ddb948cc3d178e8d62/shell/services/PluginRegistry.qml#L474-L567).

There is no transaction spanning `shell.json`, the checkout, or external
artifacts. The shell write itself is atomic, and update rolls back an invalid
Git revision, but remove has no `shell.json` backup/rollback. If a later
filesystem removal/rescan fails, the earlier disable is not automatically
undone.

### Dependencies and package-manager boundary

The official boundary is explicit: the plugin installer only clones,
validates, rescans, and toggles shell state; it never runs hooks or elevates.
Runtime prerequisites must be documented and installed separately. Repository
packages use `omarchy pkg add <packages...>` (idempotent `pacman -S --needed`);
AUR packages use `omarchy pkg aur add <packages...>`. These are package-manager
operations and must not be silently reversed when one plugin is removed,
because packages such as Rust can be shared. Installed implementations:
`/usr/share/omarchy/bin/omarchy-pkg-add` and
`/usr/share/omarchy/bin/omarchy-pkg-aur-add`.

Omarchy has no plugin command for external helper installation, systemd unit
installation, post-update migration, or pre-remove cleanup. A plugin requiring
those facilities needs a separate, explicit lifecycle owned by the plugin or,
preferably for system-distributed artifacts, an Arch package.

## Observed OSK lifecycle and gaps

The current [`install.sh`](../install.sh) is a separate user-level helper
installer. It requires Cargo, builds locked release sources, overwrites
`~/.local/libexec/oskar-daemon` and
`~/.config/systemd/user/oskar.service`, reloads the user manager, enables
the service, and restarts it only when `graphical-session.target` is active.
Re-running it is operationally idempotent and intentionally synchronizes the
QML/helper protocol. It does not install the plugin or enable its bar entry.

The current [`uninstall.sh`](../uninstall.sh) disables/stops the user unit and
removes those two helper artifacts. It intentionally leaves the plugin,
`shell.json`, and OSK user data alone. Conversely, `omarchy plugin remove`
deletes the Git checkout containing `uninstall.sh` but leaves the installed
helper/unit behind. Therefore the two commands are complementary and order is
currently significant.

OSK settings and UI state live outside the checkout under
`${XDG_CONFIG_HOME:-~/.config}/oskar/config.json` and
`${XDG_STATE_HOME:-~/.local/state}/oskar/state.json`
([`Panel.qml`](../Panel.qml)). They correctly survive both helper and plugin
removal. The `shell.json` bar entry does not survive disable/remove, so its
placement or inline fields would need an explicit backup if restoration is a
product requirement.

`omarchy plugin update` updates OSK QML and the repository copy of the Rust
source/unit but cannot build or reinstall the already-running helper. The
current protocol mismatch UI makes that split fail closed, and the user must
rerun the checkout's `install.sh`. This is safe but not an atomic or automatic
upgrade.

## Recommendations for OSK

1. Keep the canonical QML lifecycle entirely on official commands: `plugin
   add`, code review, `plugin enable`, `plugin update`, and `plugin remove`.
   Do not edit `shell.json` directly from OSK install scripts and do not copy
   QML into `/usr/share/omarchy`.
2. Document the helper as a distinct explicit prerequisite. Near term, after
   `plugin add` run
   `~/.config/omarchy/plugins/io.github.vladkarok.oskar/install.sh`; after every
   `plugin update` rerun it before Retry. Preserve the current protocol gate.
3. Prefer a separately versioned Arch/AUR helper package for release. It should
   own the daemon and unit in package locations, use package upgrade/removal
   semantics, and leave QML/user settings to Omarchy. Installing/removing that
   package remains an explicit user action; the plugin CLI must not call it.
4. If retaining the source installer, strengthen idempotence around the helper
   only: finish build/preflight before replacing installed artifacts, use
   atomic replacement, reload the user manager, enable once, and restart only
   in a usable graphical session. Do not remove shared build/runtime packages
   during uninstall.
5. Publish complete removal order while `uninstall.sh` lives only in the Git
   checkout:

   ```bash
   ~/.config/omarchy/plugins/io.github.vladkarok.oskar/uninstall.sh
   omarchy plugin remove io.github.vladkarok.oskar
   ```

   The first command removes only OSK-owned helper artifacts; the second owns
   `shell.json` cleanup, unload, and checkout removal. State/config remain by
   default. Offer a separate, explicit purge command only if users ask to
   delete those files.
6. Do not promise cross-boundary rollback. Make each phase retryable and report
   its completed state. Before destructive removal, optionally preserve a copy
   of the OSK `shell.json` entry if restoring placement/settings is desired;
   never restore an enabled entry after the checkout is gone.
7. Validate the manifest in CI and before releases. Keep the manifest ID stable:
   it is simultaneously the install directory, shell configuration identity,
   IPC identity, and update/remove handle. Make the distributable repository
   symlink-free first; current `omarchy plugin validate .` fails on
   `CLAUDE.md -> AGENTS.md`.

In short, official Omarchy owns discovery, validation, shell configuration,
QML reload, and checkout management. OSK must own its helper/service and user
data explicitly, without implying that `omarchy plugin` manages either.
