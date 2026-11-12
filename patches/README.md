# Patches

OSKar carries no patches against installed Omarchy packages. Both patches
it once carried are withdrawn; a machine that still has one applied gets
the stock files back with `sudo pacman -S omarchy-dev` (or
`omarchy update`). Their text is in this repo's history.

## omarchy-shell-style-live-rounding.patch — withdrawn 2026-11-12

Made `Commons/Style.qml` re-read Hyprland's rounding and gaps on
`configreloaded`. The stock file does that itself now (checked in
omarchy-dev 4.0.0.r7822), so the patch is gone.

## omarchy-shell-emoji-osk.patch — withdrawn 2026-09-09

Let the shell's emoji overlay cooperate with the keyboard. Emoji are the
panel's own page now and OSKar coordinates with no external picker
(decisions §24).
