# Disclosure map

README.md's "Security posture" and "What OSKar changes on your system", sentence by sentence, against the lines that make each true. `tools/disclosure-map-check.sh` (run by `tools/run-tests.sh`) checks that every file:line here still exists.

| # | README sentence | Evidence |
|---|---|---|
| 1 | Security posture: what OSKar keeps lives in the runtime, config and state directories, plus the three installed files and the install record. | `daemon/src/seat.rs:25`, `Panel.qml:1456`, `install.sh:24`, `install.sh:25`, `install.sh:26`, `bin/oskar:53` |
| 2 | Security posture: a directory OSKar creates is 0700, its files 0600, an existing directory keeps its mode, parents get your umask. | `PrivateSaves.qml:75`, `PrivateSaves.qml:208`, `PrivateSaves.qml:218`, `daemon/src/seat.rs:231` |
| 3 | Security posture: the daemon runs as you; the control socket is connectable only by processes running as you. | `daemon/src/seat.rs:244`, `systemd/oskar.service:37`, `systemd/oskar.service:45` |
| 4 | Installed files: a source install writes the unit, the helper and the command, and lists them in the install record. | `install.sh:25`, `install.sh:24`, `install.sh:26`, `bin/oskar:53` |
| 5 | Installed files: it replaces or removes only files the record lists unchanged. | `install.sh:14` |
| 6 | Installed files: `oskar setup` links the plugin, enables it with `omarchy plugin enable`, and enables oskar.service. | `bin/oskar:492`, `bin/oskar:502`, `bin/oskar:530` |
| 7 | Installed files: the pacman package installs under /usr only. | `PKGBUILD:66`, `Makefile:10` |
| 8 | Settings and state: what config.json and state.json hold. | `Config.js:493`, `Config.js:866` |
| 9 | Settings and state: state.json is written after an emoji pick, when the panel or the emoji page moves, and on a group acknowledgement or a newly named keyboard. | `Panel.qml:391`, `Panel.qml:1201`, `Panel.qml:1290`, `Panel.qml:2712`, `Panel.qml:2716` |
| 10 | Settings and state: directory and file modes; existing directories keep theirs. | `PrivateSaves.qml:75`, `PrivateSaves.qml:218` |
| 11 | Settings and state: a file that does not parse is never overwritten. | `PrivateSaves.qml:78`, `PrivateSaves.qml:95`, `Panel.qml:1357` |
| 12 | Settings and state: a symlinked file is written through; its target becomes a new 0600 file. | `PrivateSaves.qml:208`, `PrivateSaves.qml:218` |
| 13 | Settings and state: unknown keys are kept up to 64 KiB; more is unparseable. | `Config.js:386`, `Config.js:389`, `Config.js:349` |
| 14 | Runtime files: the socket, keymap.xkb, user-keymap-source and keyclick.wav in $XDG_RUNTIME_DIR/oskar/. | `daemon/src/seat.rs:262`, `daemon/src/seat.rs:27`, `daemon/src/seat.rs:43`, `Panel.qml:1911` |
| 15 | Runtime files: the directory goes away when your last session ends. | `systemd/oskar.service:38` |
| 16 | What the panel reads: the type list and size on every change while open; the chip shows kind and count only. | `Panel.qml:1610`, `Config.js:727`, `ClipboardPaste.js:456`, `ClipboardPaste.js:488` |
| 17 | What the panel reads: the text only while you point at or hold the chip, shown in its tooltip, dropped when you move away. | `Panel.qml:2942`, `Panel.qml:2925`, `Panel.qml:2957`, `ClipboardPaste.js:519` |
| 18 | What the panel reads: at the moment you paste into OSKar's own fields. | `Panel.qml:717` |
| 19 | What the panel reads: during a pick, once before publishing, up to five verify reads, and one check read on failure. | `EmojiDelivery.qml:278`, `ClipboardPaste.js:327`, `EmojiDelivery.qml:442` |
| 20 | What the panel reads: the snapshot is held only until the pick settles; the other pick reads are compared and not kept. | `ClipboardPaste.js:162`, `EmojiDelivery.qml:128`, `EmojiDelivery.qml:423`, `EmojiDelivery.qml:260` |
| 21 | What the panel reads: every read checks the type list before and after and discards the text on the mark; the chip says Hidden content and still pastes. | `ClipboardPaste.js:244`, `Config.js:751`, `ClipboardPaste.js:490` |
| 22 | What the panel reads: only x-kde-passwordManagerHint is recognised; a secret replaced between the two checks could be read (limit). | `Config.js:719`, `ClipboardPaste.js:244` |
| 23 | The clipboard: the emoji replaces the clipboard; a delivered pick leaves it. | `EmojiDelivery.qml:306`, `ClipboardPaste.js:356` |
| 24 | The clipboard: a failed pick restores only after a read shows the clipboard still holds the pick; a copy made meanwhile stays. | `ClipboardPaste.js:174`, `ClipboardPaste.js:182`, `ClipboardPaste.js:304`, `ClipboardPaste.js:366` |
| 25 | The clipboard: a copy made between that read and the put-back is replaced (limit). | `EmojiDelivery.qml:452` |
| 26 | The clipboard: images, non-text and secret content are not put back. | `ClipboardPaste.js:216`, `ClipboardPaste.js:227` |
| 27 | The clipboard: the emoji page says a pick replaces the clipboard. | `EmojiPage.qml:798` |
| 28 | The clipboard: what OSKar puts there outlives a shell restart or a plugin disable. | `EmojiDelivery.qml:95`, `tools/integration/panel_canary.py:836` |
| 29 | The clipboard: the Copy button of the not-installed and needs-updating notices writes the install command; that copy belongs to the shell. | `Panel.qml:601`, `Panel.qml:2282` |
| 30 | input:kb_file: the share starts as soon as the helper answers, whether or not the panel is open. | `HelperReplies.js:591`, `Keyboard.qml:601` |
| 31 | input:kb_file: the published keymap is yours plus the reserved block on levels five to eight of the listed positions, under the stated refusals. | `daemon/src/keymap.rs:344`, `daemon/src/keymap.rs:358`, `daemon/src/keymap.rs:367`, `daemon/src/keymap.rs:535`, `daemon/src/keymap.rs:503`, `daemon/src/keymap.rs:676` |
| 32 | input:kb_file: your own kb_file is recorded verbatim, even when missing. | `daemon/src/seat.rs:164`, `Keyboard.qml:950` |
| 33 | input:kb_file: your value is put back when the helper stops and when the shell exits cleanly. | `daemon/src/main.rs:258`, `daemon/src/seat.rs:742`, `Keyboard.qml:791` |
| 34 | input:kb_file: a config reload resets it and the panel shares again. | `Keyboard.qml:967` |
| 35 | input:kb_file: a relative kb_file is not taken over; the panel says layout sync failed; typing works. | `daemon/src/seat.rs:659`, `Keyboard.qml:661` |
| 36 | general:gaps_out: docked only, on appear and on close, back about 60 ms later, every write read back. | `Panel.qml:1090`, `Panel.qml:1077`, `Panel.qml:1513`, `Panel.qml:1042`, `GapsNudge.js:114` |
| 37 | general:gaps_out: uses hyprctl keyword; a no-op under Lua configs; an unknown form is left alone; a failed write-back is named. | `Panel.qml:1054`, `GapsNudge.js:67`, `GapsNudge.js:137` |
| 38 | cursor:hide_on_key_press: off while open, back on close; a reload restores it. | `Panel.qml:985`, `CursorPolicy.js:159`, `CursorPolicy.js:328` |
| 39 | Layouts: the language button moves the identified physical keyboards that share the reading keyboard's layout list. | `LayoutDevices.js:50`, `Keyboard.qml:1040` |
| 40 | Buttons: Install package runs omarchy pkg add hyprland in a terminal; Retry starts the service through oskar start. | `Panel.qml:2037`, `Panel.qml:593`, `bin/oskar:1277` |
| 41 | Crash: no startup restore; the compositor stays on the published keymap until a reload or logout, or a later helper's clean stop. | `daemon/src/main.rs:129`, `daemon/src/main.rs:258` |
| 42 | Crash: a killed shell leaves cursor hiding off until a reload; a key held when the helper is killed stays pressed. | `CursorPolicy.js:362`, `daemon/src/apply.rs:136` |
