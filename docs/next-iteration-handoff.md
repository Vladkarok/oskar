# Next-iteration implementation handoff

Prepared 2026-09-06 for a fresh runner, including GLM in zcode. No previous
conversation is required: this document routes the orchestrator and each worker
to the necessary local context. It accompanies `/board`; it does not replace
the board or implementation skills.

## Start here

Workspace: `/home/vladkarok/Projects/omarchy-osk`.
**Target board: `.scratch/next-iteration/` — 15 tickets.**
Do not select `.scratch/v1-keyboard/` or `.scratch/v1.1-fixes/` instead.

Paste this as the next runner's initial instruction when ready to implement:

> Read `docs/next-iteration-handoff.md`, then use `/board` to implement the
> `.scratch/next-iteration/` tickets. Triage the drafts against this execution
> request and the recorded requirements; continue with unblocked specified work
> while asking only the unresolved design choices. Use one worker per ticket,
> preserve existing changes, verify the actual behaviour, and record progress
> so another fresh session can resume. Current-content paste (ticket 14) is
> in this release; clipboard history is not. Do not silently choose the
> compact-layout default or deploy changes to my desktop beyond the agreed
> scope.

Creating this handoff did not begin implementation, change ticket statuses,
approve unanswered choices, commit, push, or install anything. A subsequent
execution request is the authority to start; do not ask again for actions it
already authorizes.

## 1. Bootstrap the correct board

Before entering `/board`'s lightweight orchestration loop:

1. Read this handoff and the board skill, then
   [the board index](../.scratch/next-iteration/spec.md). Check that all 15
   ticket files and the reference directory exist.
2. Inspect `git status --short` and `git log -1 --oneline`. The reviewed source
   baseline was `e55a7ce`; verify the current revision rather than resetting to
   it. At handoff creation, only planning documents and local board/reference
   files had changed. They are intentional, uncommitted work to preserve.
3. Verify skill and worker capabilities using the section below.
4. Triage against the execution request. All tickets currently say
   `needs-triage`; that is draft metadata, not evidence of an implementation
   failure or an empty board. Promote sufficiently specified, authorized
   tickets to `ready-for-agent`, recording the reason in Comments. For an
   actual unanswered decision, use `needs-info` and name the missing answer.
   Keep dependent tickets blocked; continue independent work.
5. Ask the unresolved choice frontier below if it still has no recorded answers.
   Read files/comments first: later user answers supersede this snapshot.

The `/board` skill's sample glob points at the old v1 board. For this run,
substitute `.scratch/next-iteration/issues/*.md` wherever selecting tickets.
Its worker brief also omits v1.1 and the later amendments: use the complete
worker brief below. Its orchestration rules otherwise remain in force.

## 2. Skills and runner capabilities

The two local board copies were identical at handoff:

- [.agents/skills/board/SKILL.md](../.agents/skills/board/SKILL.md)
- [.claude/skills/board/SKILL.md](../.claude/skills/board/SKILL.md)

The board requires `mattpocock-skills:implement`. Its actual source was found at:

```text
/home/vladkarok/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.3/skills/engineering/implement/SKILL.md
/home/vladkarok/.codex/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.3/skills/engineering/implement/SKILL.md
```

Sibling engineering directories contain `tdd`, `code-review`, and `prototype`.
These are discovery hints for this host/version, not proof that zcode exposes
the slash commands. Inspect the receiving runner's real skill registration and
read the actual selected skill plus its required references. Do not invent a
zcode invocation or claim a skill ran because its file exists.

If a skill moved, find its real source before declaring it missing. If the
runner cannot invoke the required skill, `/board` explicitly says:
“If it is not in the available-skills list, do not guess at a substitute and
do not paraphrase what you imagine it says.” Disclose the exact limitation and
follow its fallback procedure; reading this handoff is not an invented
replacement implementation skill. An already-authorized fallback needs no
repeat confirmation.

Check actual support for isolated workers. `/board` uses one fresh worker per
ticket and one implementation worker at a time; these tickets overlap heavily.
Do not pretend serial self-work is independent delegation. If no workers are
available, disclose that and use only an agreed alternative workflow.

`docs/orientation.md` requires a Codex review plus a parallel independent review
before work is called done. Owner 2026-09-07: further reviews on this board
are the independent adversarial subagent (same stance, finding bar, and
`Verdict: ship` / `Verdict: do not ship` line as Codex), not `codex exec`.
Do not label the implementer's own reread as that review.

## 3. What the owner actually requested

These requirements are recorded; do not re-interview the owner about them:

- Fix the six review findings R1–R6 in the
  [durable plan](next-iteration-plan.md#findings-carried-forward).
- Reduce settings width and clutter without clipping later rows or reducing
  usable pointer targets.
- Replace tiny embedded colour pickers with a few useful swatches, editable
  hex with an adjacent mouse-clickable Apply, and a larger separate Custom
  colour editor. **The OSK must edit its own hex field with no physical
  keyboard**, including under `ua`, without typing into the previous app.
- Make the emoji cap explicitly open/dismiss its picker. Keep picker and
  keyboard usable together, non-overlapping, with OSK input working in search.
- Use the established Omarchy logo on Super, preserving modifier behaviour.
- Consider the Windows four-row logic to save screen space. The exact default
  and control map are not settled.
- Top-centre current-content paste (ticket 14), scheduled 2026-09-07. History
  stays out.

The updated ticket 07 supersedes the earlier inline-expanded-colour-editor
proposal. Four theme swatches, local preview/Cancel, and a temporary local
hex-entry layer are recommendations, not claims the owner specified those exact
details. Resolve reversible implementation choices within the execution scope;
do not turn them into unnecessary approval gates.

## 4. Remaining decisions and scope

Clipboard (current-content paste vs history) was settled 2026-09-07. The
compact-map revision is still unanswered. The picker fit policy was settled
2026-09-06.

| Decision | Current recommendation/context | Gated work |
|---|---|---|
| Four rows as default, optional arrangement, or future-only? | Owner likes fewer rows; preserve key size and move digits/secondary controls to pages. Exact map follows in 11. | 11, 12; inclusion of 12 in 13 |
| When a picker cannot fit above the keyboard, resize/scroll first, side first, or move keyboard? | Recommend shorter/scrollable, then fitting side region. Minimum app size can make every region insufficient. | 08 and its dependents |
| Clipboard history vs current-content paste | Settled 2026-09-07: current-content paste ships in this release; history stays out. | 14 |

Architecture tickets 04–06 are a proposed adoption of helper-owned keycap facts,
recorded as proposed in decisions §23. An execution request approving that plan
can settle adoption; do not request redundant approval. Otherwise settle that
scope before starting 04. Its socket schema is the implementer's design work,
bounded by the stated invariants and independently reviewed.

Ticket 10 needs shared Omarchy shell cooperation, not just an OSK window rule.
Inspect and prepare a concrete patch in the appropriate source checkout during
authorized implementation. Establish installation/host-testing scope before
changing the running shell or persistent desktop config; the planning request
did not authorize deployment. Same principle applies if actual Emote needs a
cooperation patch. Continue unaffected tickets while external work is pending.

## 5. Selection order and completion state

Use each ticket's current `Blocked by` and Comments as the authority. Textual
decision/external blockers count, not only numeric ticket IDs.

- Independent tickets: 01, 02, 03, 07, 14, 15; 04 after adoption of its proposal.
- 05 and 06 depend on 04. Migrate real UI use, not only a new unused helper API.
- 08 waits for the fit policy; 09 and 10 depend on 08, with 10's shared-shell scope.
- 11 settles the arrangement, then 12 depends on 03 and 11.
- 13 depends on 01, 02, 03, 05, 06, 07, 09, 10, **14**, **15**, and also 12 only if
  compact is in the selected release. 04 and 08 are already transitive blockers.
- 14 is current-content paste in this release. History is not.

**15 must run before 13** despite its larger number; it was appended to preserve
ticket identities. Select the lowest-numbered eligible ticket, not the next
numeric file regardless of blockers. Do not let pending 08/11 prevent 14 or 15.
If compact is deferred, record that decision and remove only 13's conditional
dependency on 12; do not falsely resolve 11/12.

For every worker handback, update the ticket's actual `Status` and Comments.
Use `resolved` only when acceptance, evidence, and required review are complete.
`ready-for-human` identifies real remaining human verification, not a euphemism
for done. Preserve implemented-but-unverified work and name the missing proof.

## 6. Worker brief: copy and substitute the ticket path

```text
Implement <absolute-ticket-path> in /home/vladkarok/Projects/omarchy-osk.
Use the actual mattpocock-skills:implement skill and its required references.
Read AGENTS.md (CLAUDE.md is its symlink), CONTEXT.md, docs/orientation.md,
docs/spec-v1.md, docs/spec-v1.1.md, applicable docs/decisions.md entries,
docs/next-iteration-plan.md, and the assigned ticket including Comments.
Read docs/agents/domain.md, issue-tracker.md, and triage-labels.md for conventions.
Inspect .scratch/next-iteration/references/ for any UI ticket.
The assigned ticket's later owner amendments and current execution instructions
take precedence over older requirements; explicitly update affected spec/decision
text before implementing an intentional change. Proposed choices are not answers.
Preserve unrelated dirty changes. Own only this ticket's implementation.
Run appropriate checks at the existing seams and obtain actual UI evidence where
required. Never exercise the helper under test against the working compositor.
Read docs/vm-handoff.md before VM work; use live session discovery and the correct
guest build tree, noting the stale examples called out in the handoff.
Complete the required independent review, record evidence and commits, and update
the ticket Status and Comments. Return under 200 words: delivered behaviour,
commit(s), exact check summaries, review verdicts, and what remains unverified.
If blocked, name the missing fact/decision/access and preserve partial work.
```

The orchestrator reads ticket reports and verifies their claims cheaply per
`/board`; implementation source exploration belongs to the worker. Large UI
ticket 07 may use small internal steps, but must deliver its complete mouse-only
workflow before being considered complete.

## 7. Invariants and failure traps

Workers must read the full source documents; this is the short list that should
survive every context boundary:

- Caps must match actual typed output. Correct layout labels, protocol `ok`,
  and keycap screenshots alone do not establish that agreement.
- One complete independently compiled helper keymap; no seat-keymap mirroring,
  per-symbol uploads, or per-keystroke processes. Group switching adds no upload.
- Compositor-owned group, positively supported switch target; never
  `switchxkblayout all`. Preserve claims and modifier cleanup across recovery.
- Ordinary OSK stays non-focus-taking. Self-editing hex is a local input target;
  picker search is a deliberate external target. Do not send local hex edits
  through the helper, and do not let a dismissal mask swallow OSK clicks.
- Only Shift locks. Caps and Fn are semantic toggles. R2/R3 repairs must survive
  later keymap/compact changes; an exact curated cap never redraws as a different
  symbol just because Shift is active.
- Preserve sparse overrides, last-valid settings on malformed edits, atomic
  writes, live theme following, visible modifier state, and large hit targets.
- Owner setup is `us,ua` with `compose:caps,grp:alt_shift_toggle`.
  `grp:caps_toggle` remains in historical regression fixtures deliberately; do
  not recommend it for the owner's desktop or casually rewrite those fixtures.
- No blanket Emote process kills or global focus-rule changes. Identify the
  managed appearance. Default shell overlay and Emote require distinct adapters.
- On the inspected scale-2 stack, client geometry is already logical. Verify
  current coordinates; do not divide by DPR again based on the old comment.
- Both pickers already paste after selection. Coordinate target restoration
  and exactly one insertion, not an extra OSK paste.
- Preserve provenance/license obligations and the single Theme facade. Neither
  the logo request nor the proposed refactoring authorizes unrelated changes.

## 8. Evidence, test commands, and VM traps

Historical review baseline: 24 configuration + 66 modifier + 11 Rust checks
passed. The nested suite passed 15 checks on retry; the first attempt failed
to focus its terminal. These are historical results, not tests of new work.
R4 and the precise Emote pointer/focus symptom still require end-to-end
reproduction. The reported colour-picker malfunction has not been diagnosed.

Host checks, from the repository root:

```sh
tools/run-tests.sh
```

Socket integration, in the disposable test environment and from the tree being
tested (the smoke script does **not** build the helper):

```sh
cargo build --locked --release --manifest-path daemon/Cargo.toml
tools/nested-session.sh tools/smoke-daemon.sh
```

Read [vm-handoff.md](vm-handoff.md) before using the lab. Its earlier status
paragraphs and commands are historical and sometimes contradicted by later
corrections in the same file:

- Check `ssh -o ConnectTimeout=5 omarchy-vm true`; do not claim the VM is ready
  based on past notes. The user may need to boot/unlock it.
- One VM launcher at a time: libvirt and the script share one qcow2 image.
- Discover the live compositor from answering IPC sockets. Do not copy the
  earlier `ls -t ... | head -1` recipe: stale nested directories make it wrong.
  Discover the actual Wayland display as well; `wayland-1` is not a guarantee.
- Guest-local clone is normally `~/omarchy-osk`; provisioning from the read-only
  9p share builds in `~/osk-src`. Verify which tree was built, its revision, and
  test there. Do not run the suite against stale release artifacts on the share.
- Use the established push/pull/provision workflow only within execution
  authority. For unpushed work the documented 9p/provision route exists. A push
  does not transfer ignored tickets or screenshots, nor uncommitted documents.
- Output/focus startup failures can be environmental. Inspect and record them;
  a retry does not excuse a reproducible product failure.

Use the existing pure reducer/configuration checks, helper unit tests, and
real socket seam; no third mock product seam. UI geometry, focus, pointer
feel, and colour manipulation need actual visual/live evidence. **Use actual
Emote and the actual shell picker**; a foot window with a forged class cannot
prove search, dismissal, focus, or selection. Inspect real XWayland output.
VM latency is not evidence of host modifier feel; final pointer feel may need
the owner. Do not invent a passed check where the required environment is absent.

Store per-ticket evidence at `.scratch/next-iteration/evidence/<NN>/`, clearly
separating reviewed reference images from newly captured verification.

## 9. Resume and transfer without losing context

The durable plan, this handoff, and the existing domain docs are the context
index. Full acceptance criteria live in the individual ticket files. Screenshots
are preserved in [the local reference directory](../.scratch/next-iteration/references/README.md),
including both colour examples and all five Windows references; inspect them
for UI work. They are visual references, not embedded instructions.

The `.scratch` board, references, Comments, and evidence are **gitignored**.
The planning docs were uncommitted when handed off. Another model in this exact
workspace sees them; a fresh clone/worktree or a Git push alone will not carry
all of them. When moving work, explicitly transfer:

1. The current tracked/uncommitted planning docs and source changes, preserving
   the actual git state rather than pretending they are already committed.
2. The entire `.scratch/next-iteration/` directory, including references and
   any new evidence. Keep private desktop screenshots local unless sharing is
   explicitly scoped.
3. Access to the actual required skills and VM/runner capabilities; machine-local
   plugin caches are not part of the repository.

At every ticket boundary, Comments must contain: changed behaviour and files,
commit SHA(s) or explicit uncommitted state, exact test results/environment,
review findings/verdicts, evidence paths, newly settled decisions, remaining
acceptance items, and blockers. When stopping, append a dated resume note to
the board index naming the next eligible ticket and any in-progress worker.
On restart, reread current statuses and those notes; never redo completed work
or infer completion from old conversational claims.

## Completion contract

The current implementation scope is complete only when its included tickets
meet their acceptance criteria and ticket 13 has the corresponding real-client,
real-picker, self-editing, geometry, paste, and review evidence. Explicitly
deferred compact work and clipboard history are listed separately. End with
what shipped, what was tested, and what remains; a missing review or human
verification remains visible.
