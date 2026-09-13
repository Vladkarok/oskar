# Agent workflow

## Models and context

The orchestrator and every subagent run on the SESSION's model — the
harness exposes no per-subagent model or effort knob. Per-subagent
model selection is not exotic: Claude Code and Codex already ship it;
ZCode does not yet (the retired `collaboration.spawn_agent` /
Astra-Sol split was a different, older mechanism). Repository text
cannot change the app's selected root model. Raising the weight of a
pass is the OWNER's move: switch the session model in the client when
a design pass or review needs more than the current model delivers.

Compensate for a light model with discipline, not hope: self-contained
briefs (repo, task, accepted behaviour, files owned, constraints,
verification, expected result — paths, not chat history), red-first
evidence with captured output, the orchestrator re-verifying every
claim (rerun the battery, read the risky diffs), and an independent
adversarial reviewer that re-derives instead of trusting. Small edits
stay local when delegation adds cost. Keep one worker and one bounded
final review; batch related small changes into that review instead of
reviewing each document separately.

One implementation worker at a time when files overlap. Use a fresh
reviewer after implementation. Keep orchestrator reads targeted:
inspect contracts and risky diffs as needed; don't repeat a worker's
entire search. Require concise reports: changed behaviour/files,
actual test results, remaining limitations, and commit IDs only if
commits were made.

## Acceptance and review

Current user decisions supersede older specs and handoffs. Record changed
scope with the affected ticket; preserve historical evidence as history.
Keep readiness for human testing separate from owner acceptance.

Before calling a product change done, obtain an independent adversarial
review with `Verdict: ship` or `Verdict: do not ship`. Give the reviewer
the problem, accepted behaviour, constraints, diff scope and test evidence.
Fix actionable findings and re-review affected paths until ship; report a
real blocker rather than looping identical reviews. A ship verdict does not
replace the owner's mouse/feel acceptance. Use in-session subagents; the
old external `codex exec` review/retry-automation requirement is retired.

## Verification and delivery

Preserve pre-existing edits; stage only deliberately selected work when
committing. Push only when the user asks. Run relevant tests through
`tools/run-tests.sh`; use existing test seams for behavioural regressions.
Delegate screenshots and actual input checks when UI behaviour needs proof.

Host test runs use the offscreen `tools/run-tests.sh` suites only (including
`--js-only`). Run `tools/nested-session.sh`, compositor integration and
window-opening test fixtures inside the VM; a nested compositor on the host
still opens a window and can steal focus. An explicit owner request is needed
for a host graphical test. Never experiment with a helper against the working
host compositor. Read `docs/vm-handoff.md` before VM operations.
Transfer a scoped working tree to the guest without requiring a push;
verify source/destination paths and preserve guest configuration.

The installed host plugin is a symlink to this repo. After authorised QML/JS
changes, `omarchy restart shell` is authorised for trying the result.
Install a changed helper only through `./install.sh`. No helper change means
no helper reinstall. Report checks actually performed and anything still
requiring the owner's judgement.

## Quota discipline

Do not repeatedly poll worker status or re-read already inspected files. Wait
for a result, do independent useful work, and keep progress messages factual.
A worker report is enough for routine checks unless evidence is contradictory.
If a reviewer hits quota, preserve its partial work and report review incomplete;
do not start retries or consume a reset without the owner's request. A user
trial can proceed with that limitation disclosed; do not call it reviewed ship.
