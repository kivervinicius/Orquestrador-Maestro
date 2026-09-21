# Maestro Protocol

The user is the maestro. Codex and other agents act as the orquestrador.

## Execution Loop

1. Observe: read the relevant entrypoints, project instructions, and `DEV/` overview docs when the project has them.
2. Route: consult `{{USER_HOME}}/.orquestrador\SKILLS_ROUTER.json`.
3. Select: open only the task-relevant skills.
4. Act: make the smallest safe change that solves the task.
5. Verify: run the lightest meaningful validation.
6. Report: summarize what changed, what was verified, and any remaining risk.

## Project DEV Context

When a project has a `DEV/` directory, use it as local project memory after reading the nearest project `AGENTS.md` and before selecting global skills. Start with `DEV/AGENTS.md`, `DEV/README.md`, `DEV/INDEX.md`, `DEV/PROJECT.md`, or `DEV/CONTEXT.md`, then open only the files relevant to the task.

Create and update durable project documentation under `DEV/` by default. After substantive work, update `DEV/WORKLOG.md` with a compact work hook. Update `DEV/INDEX.md` and `DEV/CONTEXT.md` when the documentation map or project state changes.

## Token Discipline

- Optimize for cost to a validated outcome, not the smallest first prompt.
- Prefer compact indexes over full catalogs.
- Acquire evidence progressively; load more context only when it can materially change execution or validation.
- Prefer measured or deterministic evidence signals; do not fabricate scores merely to satisfy the optimizer.
- Avoid loading every skill directory.
- Avoid repeating long instructions across tools.
- Keep entrypoint files short and stable.
- Never trade required validation for lower token usage.

When the Adaptive Resolution Runtime is available, use it in shadow mode for substantive work to measure evidence, budget, LLM usage, escalation, and validation. Shadow telemetry must not override the existing execution loop.

## Global Changes

Changes to shared roots are allowed only when they improve compatibility or reduce duplication. Back up config files before editing.

Do not remove legacy roots unless the user explicitly asks.

## Security Work

For SaaS security automation:

- local repo scan: `/skill:skill-saas-security-scan`
- authorized staging/preview DAST: `/skill:skill-saas-dast-recon`
- git hooks and CI gates: `/skill:skill-security-hooks`
