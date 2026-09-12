# Next-iteration tickets — current guide, 2026-09-08

The local board is `.scratch/next-iteration/issues/`. Historical checklists
can lag the latest Comments and owner decisions. This guide explains scope;
the ticket and current session handoff carry acceptance and evidence.

| # | Meaning | Current position |
|---|---|---|
| 01 | Validate settings and save/reload without corrupting accepted values | Resolved |
| 02 | Restore normal cursor hiding after closing the keyboard | Resolved |
| 03 | Make symbol legends agree with emitted symbols; retain essential controls | Resolved; later symbol design supersedes old packing |
| 04 | Draw main keycaps from the same helper keymap used for typing | Resolved; owner accepted 2026-09-08 |
| 05 | Derive verified modifier chords for special symbols, including remapped AltGr | Blocked by 04; not scheduled |
| 06 | Refresh caps and typing together after editing a custom keymap file | Blocked by 04; not scheduled |
| 07 | Usable settings and colour editing with the OSK | Superseded by live-host settings work |
| 08 | Position external pickers clear of the keyboard | Resolved |
| 09 | Open/close Emote, type in its search, return selection to the target | Implemented; human acceptance/remaining picker checks |
| 10 | Make the Omarchy emoji overlay cooperate with OSK focus and placement | Implemented local shell patch; remaining acceptance checks |
| 11 | Settle the five-row control map | Resolved; newer owner symbol decisions supersede packing |
| 12 | Implement the symbol page arrangement | Current direct-symbol redesign replaces old pair-cap packing |
| 13 | Test the whole iteration together on real clients and pickers | Last, not scheduled |
| 14 | Paste current clipboard through the header control | Implemented; terminal AB04/agterm fix owner-confirmed, current diff needs review |
| 15 | Use the Omarchy logo on Super without changing its behaviour | Implemented; visual acceptance remains |

## Accepting 04

The technical record in ticket 04 includes native and XWayland received-text
checks, generation/recovery checks, and a ship review after fixes. What remains
is the owner's experience of the main ABC page on the host:

1. In a terminal and a normal app text field, click several US letters and
   punctuation; confirm the text matches the key legends.
2. Change US to UA with the physical shortcut. Confirm the panel follows and
   clicking Ukrainian letters types what is shown (for example і, ї, є, ґ).
3. Change language through the panel. Confirm physical typing follows it.
4. Try Shift once, Shift lock/unlock and Caps Lock; check displayed case and
   typed case agree. Close/reopen the panel and confirm typing still works.

Report an app, layout and specific key if anything disagrees. If all feels
right, say “04 принимаю”; the agent records acceptance. This does not approve
`&123` packing, remapped AltGr support (05), custom-file refresh (06), or
start those tickets automatically.
