# History cleanup plan (owner decision required)

246 commits on `spec/v1.1-fixes` ahead of `master`, never pushed. The owner
asked for tidying (squash/delete the noise). **This plan is a proposal —
history rewriting only happens on the owner's explicit go.**

## What the 246 commits look like

- Days 2026-09-02..09-12, one ticket-board session per day.
- Heavy WIP churn: broken builds fixed minutes later (the 52ee947 quoting
  incident), repeated "fix review findings" chains, superseded attempts
  (three jiggle cuts, two fallback designs in the layout fix).
- Three docs/review artifacts that quote old code — a squash keeps the
  files (they document findings, not commits) but commit IDs inside them
  become stale references to pre-squash history.

## Proposed target: ~12 commits

One commit per coherent milestone (all content preserved; only the
boundaries change):

1. `feat: the panel and helper v1 baseline` — days 02–05 (typing, layout
   mirroring, claims, VM harness, helper hardening).
2. `feat: settings, colour editor and the popover` — ticket 07/08 era.
3. `feat: direct symbols page and reserved block` — tickets 12/18/19/20/21.
4. `fix: flicker-free switching and shutdown release` — tickets 16/17.
5. `feat: emoji page, catalogue and delivery` — tickets 24/26/28.
6. `feat: paste chip and search focus` — tickets 14/25/29.
7. `feat: super marks and colour indicators` — tickets 22/23/15.
8. `feat: packaging skeleton (Makefile, PKGBUILD, exit 78)` — D2.
9. `fix: layout desync (remembered identity) and wine chords`.
10. `refactor: provenance zero — the tree wholly ours`.
11. `refactor: dead code out, duplication down`.
12. `docs: specs, decisions, handoffs and reviews` (or fold docs into each
    milestone commit — owner preference).

## Method (safe, no interactive rebase)

```sh
git branch backup/pre-squash spec/v1.1-fixes   # absolute safety net
git checkout -b tidy spec/v1.1-fixes
# then, per milestone: git reset --soft <milestone-start>; git commit
```
Alternatively `git rebase --autosquash` is unnecessary — the soft-reset
loop is deterministic and scriptable.

## Costs and what NOT to do

- Commit IDs cited in tickets/decisions/reviews become historical; the
  docs stay truthful about *what* happened, the references just point at
  the backup branch if kept. `.scratch` board references are unaffected
  (it cites commits in prose only).
- Do NOT drop the two review appendices or session-handoff history —
  they are the audit trail for the ship verdicts.
- If the owner prefers zero risk: skip squashing entirely; the AUR source
  can point at a squashed `release` branch cut from this one, leaving
  the working branch untouched. **This is the recommended default.**

## Owner decision

- [ ] A: squash to ~12 on this branch (backup branch kept)
- [ ] B: leave history; cut a clean `release` branch at tag time (default)
- [ ] C: something else (write it)
