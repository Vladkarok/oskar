# Next iteration: reliable input and a smaller, coordinated panel

Date: 2026-09-06. Reviewed baseline: `e55a7ce`.

This is a planning document, not a claim that changes have shipped. The owner
requested the review findings, proposed design improvements, narrower settings,
and keyboard-controlled emoji pickers to be divided into tickets. The four-row
arrangement is still pending the owner's map revision. Current-content paste
(ticket 14) was scheduled into this release on 2026-09-07; history stays out.

The current baseline remains [v1.1](spec-v1.1.md), its retained
[v1 requirements](spec-v1.md), and [decisions](decisions.md). Before implementing
an intentional behaviour change, update the affected requirement and decision;
do not silently treat this proposal as an already-approved replacement spec.

## What stays

Keep the persistent Rust helper, key positions as the input protocol's unit,
one complete keymap, compositor-owned group selection, per-connection claims,
systemd supervision, the pure modifier reducer, and the single Theme facade.
Keep the existing mouse-only reachability requirement and large hit targets.

The panel retains keyboard-focus policy None during ordinary typing. A picker
search may be the deliberate input target; clicking keyboard caps must leave
that target focused. Hex editing retains its existing limited focus exception.

## Findings carried forward

Evidence levels are deliberately separate: an executable module/XKB probe is
stronger than a code-path finding, and neither substitutes for pointer/focus
verification of a real picker.

| ID | Finding and trigger | Evidence at reviewed baseline | Ticket |
|---|---|---|---|
| R1 | German with `lv3:ralt_alt,lv3:menu_switch`: curated `¼` sends Alt+4, resolving to `4` rather than the displayed symbol. Presence at level 3 is mistaken for reachability through RALT. | Offline libxkbcommon probe; `KeyboardLayout.js` token index, modifier position table, and level-to-chord mapping. | 05 |
| R2 | Curated pages for `ua`, `gb`, and `fr` omit the row with Shift and Enter when fewer than 29 curated symbols exist. Locked Shift remains held with its control hidden. | Actual compiled maps yielded 18, 26, and 23 symbols; evaluated row builder. | 03 |
| R3 | French curated `²` displays `~` under Shift, but its exact level-1 press still types `²`. | Actual cap-overlay and modifier-reducer evaluation. | 03 |
| R4 | Editing a custom `kb_file` in place and reloading leaves the helper and keycaps stale because cache identity contains its path, not its contents. | Code-path finding: helper's same-keymap shortcut precedes file read; panel compares the same configure strings. End-to-end reproduction belongs to ticket 06. | 06 |
| R5 | `{"key_radius":8,"keyRadius":-20}` bypasses validation, applies -20, and later serializes invalid canonical `key_radius`. Unknown fields collide with internal names. | Actual configuration module evaluation. | 01 |
| R6 | Closing before the cursor-setting probe completes can disable cursor hiding after close, outliving the panel. | Actual callback and restore function evaluated with recorded process calls; no live desktop mutation. | 02 |

Review verification: 24 configuration checks, 66 modifier checks, and 11 Rust
tests passed. The nested suite passed all 15 checks on retry; its first run
stopped because the test terminal did not gain focus. Full visual and XWayland
verification was not repeated. A green helper suite did not cover R1–R3's
display/input disagreement.

## Settings: narrower without clipping the controls below

The owner's screenshot accurately shows unused space to the right of the basic
controls. The current width is determined by the widest content elsewhere in
the same scroll surface: a 238-token-unit colour-editor zone and a horizontal
chooser containing every detected emoji app. Every row pays that width even
when only Mode, Size, and Sound are visible.

Owner amendment (2026-09-06): the embedded pickers are difficult to use, and
hex editing currently assumes access to a physical keyboard. Replace the
earlier proposal for an inline expanded picker with this treatment:

- Keep basic settings in a narrow, stable popover anchored under the gear.
- Show the selected emoji app in one chooser control, with alternatives revealed
  on demand rather than laid out permanently side by side.
- Present each colour as a few quick swatches, an editable hex field with an
  adjacent small Apply button, a Custom colour button, and the existing reset.
  Recommend up to four distinct swatches from the current theme's background,
  foreground, accent, and muted colour, with maintained fallbacks and duplicate
  colours removed. These are useful defaults, not a claim about measured usage.
- Clicking a swatch applies immediately. Swatches follow live theme tokens;
  choosing one stores that resolved colour as an explicit override. A later
  theme change must not silently rewrite that chosen override.
- Editing hex creates a local draft. Apply commits valid text; invalid text
  stays editable with an inline error and writes nothing. Enter is optional.
  Cancel/dismiss abandons the uncommitted draft without rolling back previously
  applied settings. Apply must consume the draft before focus-loss dismissal.
- The OSK itself must enter and correct the entire hex value, including `#`,
  digits and A–F, with caret/backspace/selection and mouse-only commit. Route
  editing locally to the selected field rather than emitting virtual keystrokes
  into the previously focused application. Keep OSK controls pointer-accessible;
  a temporary hex-entry layer/keypad may ensure all hex characters remain
  available even when the system group is Ukrainian. It must not replace the
  system/helper keymap or alter the selected system group. Preserve and restore
  the ordinary page and modifier state without leaking a chord on exit.
- Custom colour opens one larger, separate editor surface for the selected
  setting, inspired by the second screenshot: a generous colour plane, clear
  hue/brightness controls, and a visible old/new preview. Use large pointer
  targets and a synchronized editable hex field. Recommend local preview with
  explicit Apply and Cancel, matching the hex-draft behaviour above. Fit the
  editor and usable OSK input controls on the output; opening it must not enlarge
  the keyboard or its docked reservation. A modal input grab that prevents
  using the OSK would repeat the reported defect.
- Derive width from the actual compact controls and themed text, clamped to the
  card/output. Scrolling changes height only; it must not widen the popover as
  different rows come into view. Preserve control sizes and readable labels.

Verification must include all settings, not only the first three rows, with all
picker candidates available, long app names, reset controls, error text, and
changed theme font/scale. Narrowing the entire rectangle while leaving its
existing colour editor unchanged would merely hide the overflow.

The reported incomplete picker behaviour still needs a concrete reproduction;
the screenshot establishes crowded controls, not its mathematical cause.
Verify hue/SV or equivalent control round trips, especially choosing colours
after black/white/grey, drag capture, and marker/preview/hex agreement. Preserve
the existing supported hex/alpha grammar; the reference is not a request for
RGB/HSL mode menus, saved custom palettes, colour history, or new opacity UI.

This amendment intentionally replaces v1.1 §5's always-visible embedded colour
editors and immediate writes while dragging/typing. Other settings and swatch
clicks remain immediate. Record that targeted spec delta before implementation.

## Super uses the Omarchy logo

The owner requests Omarchy's logo instead of the current Super key label/icon.
Reuse the established Omarchy logo asset or icon mechanism, rather than drawing
an approximation or depending on an unverified font glyph. Preserve the Super
accessible name/tooltip, latch indication, hit area, key position, and emitted
modifier semantics. Apply it on every page/arrangement carrying that key, with
readable themed idle/hover/pressed/latched states at M/L/XL. This is ticket 15,
independent of the compact-arrangement decision.

## Emoji pickers: one keyboard-owned interaction

The requested contract is stronger than v1.1 §1's detached launch and one-time
courtesy move. A second press must explicitly dismiss the picker opened from
the keyboard; that behaviour must not depend on an incidental click-away rule.
The keyboard and picker remain usable together, with no overlap.

### Session contract

The emoji cap controls one picker session: closed, opening, open, or closing.
These are observed lifecycle states, not a blind boolean flipped on each click.

- Closed → press opens the configured picker and records which appearance is
  associated with this panel. Open → press dismisses that appearance.
- A second press during startup cancels the requested appearance; late window
  mapping cannot resurrect it. Rapid presses must not create duplicate pickers.
- External dismissal, selection, process failure, and output removal settle the
  visible state. Changing picker app or closing the panel ends its session.
- Picker search takes deliberate input focus. OSK presses type into search
  without taking focus themselves, and the emoji toggle remains clickable.
- Dismissing returns to the original target when it still exists and when the
  user has not intentionally focused a different application. Verify selection
  delivery against the picker's real behaviour; never paste into its own search.
- Scope close, placement, and temporary focus policy to the identified
  appearance. Never kill all processes with the app name, change unrelated
  picker windows, or install blanket desktop rules.

This does not promise global click-away dismissal for every third-party app.
Explicit cap toggle, selection, and Escape are the required dismissal routes.
Click-away can remain picker-native where it works. Unknown custom apps retain
launch support; managed toggle/placement is offered only with positive identity
and supported behaviour, otherwise an honest limitation is shown.

### Geometry contract

Use one measured logical coordinate space for the output, panel rectangle, and
picker rectangle. Current code divides `hyprctl clients` geometry by the output
scale; the installed scale-2 session already reports that client geometry in
logical coordinates. This invalidates overlap detection and target placement.

Recommend placing the picker above the keyboard on the same output with a small
gap and an anchor related to the emoji cap. Clamp horizontally. When space is
insufficient, recommend a shorter scrollable picker, then a fitting side region.
The owner is being asked to choose that fallback policy. Moving alone cannot
guarantee non-overlap if the picker is taller than the space above the panel.

Recompute on actual geometry changes: panel drag, dock/float, preset, output or
scale change, and picker resize. Use existing event streams and bounded startup
settling. Verify the resulting rectangles and dispatch success; successful
process exit alone is not proof that the picker moved. If the app's minimum
size leaves no fitting region, expose that constraint instead of declaring an
overlapping placement successful.

### Two integrations, with different ownership

The Omarchy default is a shell overlay, not an ordinary client window. Its
fullscreen dismissal surface and keyboard-focus policy need cooperation from
the shell to keep the OSK clickable and let its search receive OSK input.
Ordinary client move rules cannot solve that integration.

Emote is a separate app. Its installed launcher destroys/recreates its picker
on a second invocation; it does not toggle it closed.
Identify the actual window, inspect its single-instance and dismissal behaviour,
and apply only the runtime policy needed for the keyboard-opened appearance.
The reported search/click blockage still needs reproduction with actual Emote;
its precise focus cause is not established by a screenshot or a stand-in foot
window. Treat the existing `stay_focused` rule as an investigation input, not
permission to disable that rule globally.

Installed-source inspection gives a specific focus explanation to verify:
Hyprland's `stay_focused` input path selects the focused window before normal
overlay hit-testing, while Emote destroys its picker on focus loss. Simply
removing that rule could trade blocked keyboard clicks for premature dismissal.
The fix needs to preserve search keyboard focus while letting pointer events
reach the OSK. The default launcher already calls the shell's actual toggle;
the missing part is getting the second click to the OSK and coordinating state.

Both installed pickers perform their own delayed paste after selection. Omarchy
dismisses and invokes an insert helper with temporary clipboard ownership and
Shift+Insert; Emote copies and schedules Ctrl+V. Neither captures an original
target address. Preserve exactly one delivery path and verify focus restoration
before that paste; adding a second OSK paste would duplicate the emoji. These
are existing external-picker behaviours, not permission to introduce clipboard
mutation into curated-symbol input.

Shared-shell work is a cross-repository implementation dependency. This plan
records it; the current session modifies only planning documents. A local patch
may be prepared during implementation, with explicit installation scope then.

## Windows references: adopt the interaction, verify the details

The five supplied Windows screenshots show:

- Four key rows plus a thin header; the letters page has no separate digit row.
- Secondary number legends on the letter row; the screenshot alone does not
  establish the gesture used to activate them.
- A digits/symbols page and a second symbol page, navigated in place. Digits
  remain directly clickable on the first symbols page.
- Fewer navigation keys on the letters page, with fuller navigation on symbols.
- A top-centre clipboard icon in several views.
- Context-dependent `/`, `@`, and `.com` controls in URL/email examples.

This is a good direction for the stated couch/mouse use case: save one key-row
height while retaining large keys. It trades an extra page click for digits and
some commands. Prefer that deliberate tradeoff to shrinking every hit target.

### Proposed compact arrangement

The owner is choosing between a four-row default, an optional compact
arrangement, or future-only exploration. Record that choice before ticket 11
settles the exact key map; do not invent a persisted setting before it is needed.

Recommend three content rows plus one command row on each ordinary page, with
digits on `&123`. Keep direct access to page navigation, language, Shift,
Backspace, Enter, and Space. Keep Ctrl/Alt/Super chords, Caps, Fn, Escape, Tab,
AltGr, Delete, all arrows, and function keys mouse-reachable through explicitly
documented pages/controls. One screen cannot silently lose those capabilities.

The design ticket must assign every current key/control a destination and
specify how Fn fits without adding height. Keep one shared pitch per
arrangement, consistent command positions across pages, equal ordinary-page
height, and the accepted docked/floating resize anchors. Measure saved logical
pixels at the same font, output scale, and preset; target one existing row pitch
of reduction rather than an unsupported fixed screen percentage.

Do not copy secondary digit legends unless a mouse-only action is specified;
showing `1` above `q` while neither click nor a discoverable action types `1`
would repeat the misleading-keycap problem. Automatic URL/email awareness is
not provided by the existing key-position protocol. Keep context controls and
their detection question as future work, rather than infer the input type from
application titles. A manual URL page is an option for that later discussion.

### Clipboard: current-content paste in this release

The owner chose current-content paste first (2026-09-06) and scheduled it
into this release (2026-09-07, ticket 14). History and automatic previews
stay out. Do not ship an inert button.

Paste leaves clipboard contents unchanged. Delivery must be proven across
native applications, terminals, and XWayland: a universal Ctrl+V assumption
does not settle terminal behaviour. An explicit user paste command is
distinct from using clipboard mutation to synthesize arbitrary curated
symbols; the latter stays outside the permitted input design (decisions
§17 and §26).

## Architecture changes with a concrete payoff

1. **Helper-owned keycap facts.** Expose keycaps and producible chords from the
   helper's already-compiled complete keymap. Use libxkbcommon to resolve
   Unicode, key types, groups, and modifier routing instead of rebuilding that
   knowledge in shell text parsing and handwritten keysym tables. Correlate
   replies to the installed keymap generation; stale replies cannot enable
   mismatched caps. Keep group switching free of keymap uploads.
2. **Local ownership of asynchronous state.** A keyboard-session module owns
   connection readiness, configuration replies, and keycap generation matching.
   A cursor-policy module owns probe/override/restore. A picker-session module
   owns the chosen appearance, geometry, focus handoff, and cancellation.
   The pure modifier reducer retains click semantics and emitted chords.
3. **Settings responsibilities.** Validated configuration, external reloads,
   atomic persistence, and preservation errors belong behind a settings-store
   interface. The popover and colour editor consume values and issue changes;
   panel geometry consumes effective settings. Extract as part of the related
   bug/UI slices so each change has behaviour to verify.

The first proposal replaces the keycap pipeline in decisions §11, while
preserving §3's independent complete-keymap compilation and prohibition on
seat-keymap mirroring. Compact rows revisit v1 §4 and decisions §22's exact
15.5-unit arrangement, while preserving its shared-pitch/stagger rationale.
Managed picker sessions replace v1.1 §1's launch-only/courtesy-placement scope.
No proposal changes the dead-end list or theme-refresh ownership.

## Ticket map

Local tickets are in `.scratch/next-iteration/issues/`, one file per ticket.
That board is gitignored; this document is the durable scope/index. All tickets
start `needs-triage` because this is the requested reviewable breakdown, not an
approved execution queue. A later planning reply can approve or amend the
breakdown before tickets become `ready-for-agent`.

| Ticket | Deliverable | Blocked by |
|---|---|---|
| 01 | Validated settings cannot be overwritten through unknown-key collisions; isolate persistence ownership | — |
| 02 | Cursor hiding is restored across close/reopen and delayed probes | — |
| 03 | Curated exact caps agree with input and retain Shift/Enter | — |
| 04 | Main-page keycaps come from the helper's acknowledged keymap | — |
| 05 | Curated availability and chords use actual keymap modifier routing | 04 |
| 06 | Custom keymap edits refresh caps and typing coherently | 04 |
| 07 | Narrow settings, theme swatches, OSK-editable hex with Apply, and a larger Custom colour editor | — |
| 08 | Picker placement uses correct coordinates and a defined fitting policy | — |
| 09 | Emote opens/closes from the emoji cap and accepts keyboard search | 08 |
| 10 | Omarchy's picker cooperates with OSK toggling, search, and geometry | 08; shared-shell implementation scope |
| 11 | Settle and demonstrate the four-row control map | Owner's arrangement choice |
| 12 | Deliver the chosen compact arrangement with preserved capabilities | 03, 11 |
| 13 | Prove the combined release with actual caps, clients, both pickers, mouse-only colour editing, and current-content paste | 01, 02, 03, 05, 06, 07, 09, 10, 14, 15; 12 if selected for this release |
| 14 | Ship top-centre current-content paste | Owner scheduled 2026-09-07; history stays out |
| 15 | Replace the Super visual with the Omarchy logo, preserving input behaviour | — |

Tickets 04–06 form a deliberately staged path: first one complete main-page
feature over the new interface, then curated reachability, then content-refresh
identity. Keep the old curated path working until 05 replaces it; remove that
superseded pipeline as part of 05. These are verifiable slices, not separate
"build backend" and "wire frontend" tasks. Ticket 03 is an independent small
fix and does not have to wait for that architectural work.

Ticket 15 was appended to preserve existing ticket identities; it can run before
13, which depends on it. The granularity and blocking edges are proposals for
owner review. Numbers
provide a useful execution order without creating false dependencies between
independent fixes. No existing ticket or parent issue is modified or closed.

## Verification and completion

Use the existing pure modifier/configuration checks, Rust unit tests, and real
control-socket integration seam. Extend the latter to compare helper-provided
keycap/chord facts with actual focused-client output. Exercise `us,ua`, `fr`,
`gb`, remapped German, repeated-layout variants, and a custom keymap edit.

Keep the current two-product-seam policy: no mock compositor or extra fake UI
suite presented as product proof. Settings geometry, pointer behaviour, picker
search/focus, overlay coexistence, and compact-layout feel require visual/live
evidence in the VM or an explicitly scoped host session. Both actual Emote and
the actual shell picker are mandatory; a renamed foot window proves neither.

Never run the helper under test against the working compositor. Verify with
the nested harness/VM, record exact revisions and remaining human judgments,
and perform the project's independent review loop before marking work resolved.
Clipboard history and automatic context controls do not gate these fixes.
Current-content paste (ticket 14) does.

## Reference evidence

Owner-provided screenshots in this conversation: settings width; default picker
covering the panel; Emote behind the floating panel. Windows files were inspected
at `/home/vladkarok/Downloads/1408_Setup_Tool_Lastwar/vm-screenshots/Pictures/Screenshots/`:

- `Screenshot 2026-09-06 160557.png`: four-row letters page.
- `Screenshot 2026-09-06 160708.png`: digits/first symbols page, clipboard icon.
- `Screenshot 2026-09-06 160726.png`: second symbols page.
- `Screenshot 2026-09-06 161342.png`: URL controls and visible browser input.
- `Screenshot 2026-09-06 161432.png`: email controls and visible sign-in field.

These are local reference paths, not bundled assets. The observations above
remain useful if the original files move. Windows screenshots establish visible
arrangement only, not unobserved gestures or delivery protocols.

Installed picker evidence, read without launching, closing, or reconfiguring apps:

- `/usr/share/omarchy/bin/omarchy-menu-emoji`: explicit shell toggle.
- `/usr/share/omarchy/shell/shell.qml`: explicit hide and open-state operations.
- `/usr/share/omarchy/shell/plugins/emojis/Emojis.qml`: fullscreen Exclusive
  surface, backdrop dismissal, centred card, and selection-to-insert handoff.
- `/usr/share/omarchy/bin/omarchy-menu-emoji-insert`: delayed Shift+Insert path.
- `/usr/lib/python3.14/site-packages/emote/__init__.py`: second activation
  destroys/recreates the picker; `picker.py`: destroys on focus loss and uses a
  delayed Ctrl+V path on Wayland after selection.
- The host Emote window rule sets `stay_focused=true`. For the installed
  Hyprland v0.56.2, [ViewQuery.cpp](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/desktop/state/ViewQuery.cpp#L231)
  identifies that window and [InputManager.cpp](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/managers/input/InputManager.cpp#L399)
  chooses its surface before ordinary overlay hit-testing. This is a
  source-backed explanation pending an actual Emote pointer reproduction.
- Read-only geometry observation: a 2560×1600 output at scale 2 reported a tiled
  client at `[2,49]` with size `[1276,749]`. Client geometry is already logical
  on this installed stack; dividing by DPR again is incorrect. Verify other
  supported versions and scales rather than generalizing an untested format.
