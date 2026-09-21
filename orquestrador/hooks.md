# Orquestrador Hooks

This file is intentionally compact. Use it as a hook router, not as a full catalog.

## Preflight Hook

Before broad work:

1. Read project `AGENTS.md`.
2. Read `{{USER_HOME}}/.orquestrador\SKILL_EXECUTION_PROFILES.json`.
3. Read `{{USER_HOME}}/.orquestrador\SKILL_ALIASES.json`.
4. Read `{{USER_HOME}}/.orquestrador\SKILLS_ROUTER.json`.
5. Use `{{USER_HOME}}/.orquestrador\SKILL_CHAINS.json` only after selecting the primary skill.
6. Select only the skills needed for the task.
7. Avoid loading full catalogs unless doing inventory or diagnostics.

## Adaptive Resolution Shadow Hook

For substantive work, when `{{USER_HOME}}/.orquestrador/bin/resolution-runtime.ps1` exists:

1. Start a resolution run in the strategy mapped by `RESOLUTION_RUNTIME.json`.
2. Record evidence that was actually opened or acquired; never invent relevance, token, latency, or provider metrics.
3. Record LLM token usage only when the active tool exposes measured usage.
4. Record the validation result before completing the run.
5. Keep the runtime in `shadow` mode: budget violations are telemetry and must not block the existing Maestro workflow.
6. Keep resolution state and ledgers local under `{{USER_HOME}}/.orquestrador/logs`; never publish them.

The shadow hook measures cost-to-validated-outcome. It does not replace skill routing, project memory, context selection, or verification.

## Verification Hook

Before claiming completion:

1. Run the lightest meaningful validation.
2. For code changes, prefer build/lint/test when available.
3. For global config changes, run:

`powershell -NoProfile -ExecutionPolicy Bypass -File {{USER_HOME}}/.orquestrador\doctor.ps1`

## Sync Hook

After adding or changing a shared skill, run:

`powershell -NoProfile -ExecutionPolicy Bypass -File {{USER_HOME}}/.orquestrador\sync-skills.ps1 -Apply`

## Automatic Skill Hooks

| Trigger | Skill |
|---|---|
| Build, review, or plan SaaS product/dashboard/payments | `/skill:skill-saas-factory` |
| SaaS admin panel, users, plans, payments, logs, metrics | `/skill:skill-saas-admin-dashboard` |
| AbacatePay, PIX, CPF/CNPJ, BRL billing | `/skill:skill-abacatepay-integration` |
| Stripe Checkout, Billing, subscriptions, portal | `/skill:skill-stripe-integration` |
| Plan limits, quotas, trials, grace, entitlements | `/skill:skill-saas-core-limits` |
| Local SaaS repository security scan | `/skill:skill-saas-security-scan` |
| Authorized staging or preview DAST/recon | `/skill:skill-saas-dast-recon` |
| Git hooks or CI security gates | `/skill:skill-security-hooks` |
| Supabase, RLS, tenant isolation, policies | `/skill:skill-supabase-rls` |
| AI routing, model fallback, token budget, agent gateway | `/skill:skill-ai-orchestration` |
| Subagents, multiagents, swarm, team execution, delegation | `/skill:skill-multiagent-orchestration` |
| AionUi, cowork app, Team Mode, unified MCP/agent UI | `/skill:skill-aionui-cowork-orchestration` |
| WhatsApp, Evolution API, message webhooks | `/skill:skill-evolution-api` |
| Frontend polish, responsive guardrails, layout QA | `/skill:skill-frontend-ux-guardrails` |
| SaaS UI system or admin component patterns | `/skill:skill-modern-ui-patterns` |
| Open-design visual upgrade or design tokens | `/skill:skill-open-design-ui` |
| Live video/audio processing pipeline | `/skill:skill-live-processing` |
| Manual video upload and processing | `/skill:skill-manual-video-processing` |
| Smart clips, highlights, video moment detection | `/skill:skill-smart-clip-detection` |
| Product analytics, events, funnels, KPIs | `/skill:skill-unified-analytics` |
| ElevenLabs, TTS, voice cloning | `/skill:skill-elevenlabs-voice-cloning` |
| Google Workspace, Calendar, Meet, FreeBusy, OAuth sync | `/skill:skill-google-workspace-sync` |

## Token Budget Rule

Do not load all skills to decide what to do. Read aliases, profiles, and router first. In `fast`, load one skill. In `standard`, load at most three skills. In `deep`, `saas`, or `security`, load more only when `SKILL_CHAINS.json` says the chain is allowed.

## Usage Log

When a tool supports persistent logging, append one JSON line after broad work:

`{{USER_HOME}}/.orquestrador\logs\skill-usage.jsonl`

Use schema:

`{{USER_HOME}}/.orquestrador\SKILL_USAGE_SCHEMA.json`

## Entrypoints

Use:

`{{USER_HOME}}/.orquestrador\PROGRAM_ENTRYPOINTS.json`

## Router

Use:

`{{USER_HOME}}/.orquestrador\SKILLS_ROUTER.json`

## Related Control Files

- `{{USER_HOME}}/.orquestrador\SKILL_ALIASES.json`
- `{{USER_HOME}}/.orquestrador\SKILL_CHAINS.json`
- `{{USER_HOME}}/.orquestrador\SKILL_EXECUTION_PROFILES.json`
- `{{USER_HOME}}/.orquestrador\SKILL_USAGE_SCHEMA.json`
