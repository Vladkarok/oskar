# omarchy-osk

A mouse-driven on-screen keyboard for Omarchy (Arch + Hyprland +
Quickshell). Start with [docs/orientation.md](docs/orientation.md).

## Agent skills

### Issue tracker

Local markdown under `.scratch/<feature>/`, gitignored. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context; the decision log is `docs/decisions.md`, not `docs/adr/`. See `docs/agents/domain.md`.

### Working the board

`/board` runs the tickets one at a time through subagents, one per ticket, so the orchestrating context stays small. See `.claude/skills/board/SKILL.md`.
