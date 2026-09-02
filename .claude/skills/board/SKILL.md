---
name: board
description: Work the .scratch issue board ticket by ticket, one subagent per ticket, keeping the main context clean. Use when the user says "work the board", "next ticket", "keep going through the tickets", or invokes /board.
---

# Working the board

You are the orchestrator. **You do not write code and you do not read
source files.** One subagent per ticket does that; you pick the ticket,
brief it, check its claims cheaply, and move on. The point is that your
context after ten tickets looks like ten short reports, not ten diffs.

## The one rule that keeps this working

Every token you spend reading the repo is a token the next ticket does
not get. You may run `git log --oneline`, `git status -sb`, `grep` for a
`Status:` line, and `tools/run-tests.sh`. You may read a ticket file.
**Nothing else.** If you catch yourself opening `Keyboard.qml`, stop —
that is the subagent's job, and a question about the code is a question
for a subagent.

## Each cycle

### 1. Pick the ticket

```bash
for f in .scratch/v1-keyboard/issues/*.md; do
  printf "%-42s %s\n" "$(basename $f)" "$(grep -m1 '^\*\*Status:\*\*' $f | sed 's/\*\*Status:\*\* //')"
done
```

Take the lowest-numbered ticket that is `ready-for-agent` and whose
`Blocked by:` tickets are all `resolved`. Read that one file — it is the
only file you read this cycle.

`ready-for-human` means a human has to see it, not that it is unstarted:
read its Comments, tell the user what is left, and skip to the next.

### 2. Spawn one subagent

One at a time. The tickets pile onto the same few files, and parallel
agents in one checkout collide. Give it the ticket path and let it read
its own context — do not paste the ticket body into the prompt.

Brief it with: the repo path; the ticket path; that `CLAUDE.md`,
`docs/orientation.md`, `docs/spec-v1.md` and `CONTEXT.md` are the
standing context; that the two test seams in spec §15 are where tests
go and a third seam is not wanted; that host suites run through
`tools/run-tests.sh` and socket-level work through
`tools/nested-session.sh tools/smoke-daemon.sh`; that it must commit in
conventional-commit style and update the ticket's `Status:` and
`## Comments` before returning.

Require the report back in **under 200 words**: what changed, the commit
SHAs, the last line of each suite it ran verbatim, and anything a human
has to verify. Tell it that unfinished is a fine answer and inventing a
green test is not.

### 3. Check the claims, cheaply

Do not take the report at face value and do not re-read the diff:

```bash
git log --oneline -3
tools/run-tests.sh 2>&1 | tail -5
```

The suite is the check that costs nothing and catches the one failure
mode that matters — a subagent that reported green on red. If the ticket
touched the socket, ask the user to run the nested-session suite, or run
it yourself if this session is not the one under test.

Confirm the ticket's `Status:` line actually changed. A subagent that
forgot is a one-line fix, not a respawn.

### 4. Report one paragraph, then continue

Per ticket, tell the user: what landed, the commit, suites green or not,
and what needs them. Then take the next ticket without asking — they
started this loop to stop being asked.

## Stopping

Stop and hand back when: a subagent reports a blocker or a design
question the ticket does not answer; the suite goes red and the fix is
not obvious from the report; a ticket needs the VM or a human eye; or
the board has no unblocked `ready-for-agent` ticket left.

End with the human-verification list you accumulated — the VM runs and
eyeball checks — in one place, so the user can do them in a single
sitting instead of one per ticket.
