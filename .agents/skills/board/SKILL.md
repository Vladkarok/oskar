---
name: board
description: Execute the requested local .scratch issue board sequentially with one implementation subagent per ticket. Use for /board, work the board, or next ticket; not for merely explaining ticket status.
---

# Working the board

Follow [agent workflow](../../../docs/agents/workflow.md) for models, review,
verification and deployment. This skill is self-contained; no `implement`
skill or external Codex process is required.

## Select

1. Read the current session handoff and identify the board the user scheduled.
   Inspect its ticket titles, status and dependencies. Read Comments before
   treating an old status or checklist as current. Never assume the historical
   `.scratch/v1-keyboard/` board is active.
2. Pick the lowest-numbered authorised `ready-for-agent` ticket whose blockers
   are resolved. Respect explicit ordering and exclusions in the current
   handoff. A request to explain or approve one ticket does not schedule all
   blocked work. `ready-for-human` is implemented work awaiting acceptance,
   not permission to reimplement it.
3. Explain a human gate as a short, concrete click/check procedure. Record an
   owner's actual acceptance before resolving it; elapsed time is not approval.

## Implement and review

4. Spawn one Sol implementation worker with a fresh context. Supply repo and
   ticket paths, accepted deviations, owned files, relevant spec/decision
   pointers, preserved dirty work, and required checks. The worker reads its
   own source context, implements and runs relevant tests. It updates ticket
   Comments with evidence and the honest status; no automatic push.
5. Check the reported result against the changed files and test output. Run a
   fresh Sol adversarial review according to the workflow. Reuse the worker
   for fixes; keep the independent reviewer separate. Do not repeat tests
   already observed unless changes, failures, or uncertainty justify it.
6. Report ticket number, meaning, result, checks, and owner acceptance still
   needed. Continue to the next eligible ticket within the scheduled scope.

## Stop

Stop at a scope/design question, unresolved blocker, or exhausted eligible
work. If VM access is needed, check `ssh -o ConnectTimeout=5 omarchy-vm true`;
if unavailable, continue independent host work and ask only for the missing
boot/unlock action. End with the remaining human decisions in one place.
