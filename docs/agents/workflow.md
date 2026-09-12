# Agent workflow

## Models and context

Astra (`gpt-6-astra`) coordinates design, scope, integration, and final
judgement. Delegate bounded implementation and independent reviews to Sol
(`gpt-5.6-sol`) at medium effort by default. Use high only for a concrete
problem that medium could not resolve. Small edits stay local when delegation
adds cost. Keep one worker and one bounded final review; batch related small
changes into that review instead of reviewing each document separately.

With `collaboration.spawn_agent`, explicitly set the Sol model and effort,
use `fork_turns: "none"`, and provide a self-contained brief: repo, task,
accepted behaviour, files owned, relevant context paths, constraints,
verification, and expected result. Pass paths instead of the full chat.
This is a tool-call policy, not a claim that repository text changes the
app's selected root model or account quota.

One implementation worker at a time when files overlap. Use a fresh Sol
reviewer after implementation. Keep orchestrator reads targeted: inspect
contracts and risky diffs as needed; don't repeat a worker's entire search.
Require concise reports: changed behaviour/files, actual test results,
remaining limitations, and commit IDs only if commits were made.

## Acceptance and review

Current user decisions supersede older specs and handoffs. Record changed
scope with the affected ticket; preserve historical evidence as history.
Keep readiness for human testing separate from owner acceptance.

Before calling a product change done, obtain an independent adversarial
Sol review with `Verdict: ship` or `Verdict: do not ship`. Give the reviewer
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
