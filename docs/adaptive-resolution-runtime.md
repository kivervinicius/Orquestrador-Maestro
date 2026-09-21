# Adaptive Resolution Runtime

## Status

Experimental V0. The runtime is installed with the Orquestrador but defaults to `shadow` mode. Shadow mode records decisions and costs without blocking the existing Maestro execution flow.

## Goal

Measure and later minimize **cost to validated outcome**, not just prompt size.

The runtime establishes four primitives before any learned optimizer is introduced:

1. resolution contract and run state;
2. explicit budget accounting;
3. evidence and LLM usage telemetry;
4. validation-backed completion.

The current skill router, memory conventions, and context workflow remain authoritative. This runtime observes them so future optimization can be based on real data instead of guessed heuristics.

## Files

- `orquestrador/RESOLUTION_RUNTIME.json`: runtime mode, storage paths, initial strategy budgets, and validation policy.
- `orquestrador/bin/resolution-runtime.ps1`: local append-only resolution runtime.
- `scripts/test-resolution-runtime.ps1`: dependency-free smoke test.
- each LLM event may record provider, model, input/output tokens, and measured duration when the active tool exposes them.
- local state: `%USERPROFILE%\.orquestrador\logs\resolution-runs\*.json`.
- local event ledger: `%USERPROFILE%\.orquestrador\logs\resolution-ledger.jsonl`.

Runtime logs are local data and must never be committed to the public snapshot.

## Strategy Levels

The V0 understands three bounded strategy levels:

| Strategy | Intent |
|---|---|
| `targeted` | Start with the smallest evidence/context budget appropriate to a focused task. |
| `balanced` | Allow broader context, memory, and additional LLM calls. |
| `deep` | Allow high-cost investigation only when the task or escalation requires it. |

These are budget envelopes, not claims about task quality. In shadow mode an over-budget reservation is recorded and flagged, but execution is not blocked.

Existing Maestro execution profiles can be passed to the runtime and are mapped through `profileStrategyMap`. This keeps the experiment aligned with the current `fast`, `standard`, `deep`, `multiagent`, `saas`, and `security` profiles instead of creating a competing routing taxonomy.

## Resolution Lifecycle

```text
start
  |
  +--> reserve --> commit/release
  |
  +--> evidence
  |
  +--> llm
  |
  +--> validate
  |
  +--> escalate (optional)
  |
  +--> complete
```

A run can declare `requiredValidators` in its resolution contract. When they are present, every required validator must have `pass` as its latest result and no validator may have a latest `fail`. A validator can fail and later recover after a successful rerun. Without required validators, at least one latest hard result must pass and none may fail. A `soft-pass` never becomes a hard validated outcome.

## Example

```powershell
$runtime = "$env:USERPROFILE\.orquestrador\bin\resolution-runtime.ps1"

$run = & $runtime -Action start `
  -Task "Corrigir regressao do login Google" `
  -TaskClass bugfix `
  -Strategy targeted `
  -Tool codex

$reservation = & $runtime -Action reserve `
  -RunId $run.RunId `
  -BudgetType contextTokens `
  -Amount 1200

& $runtime -Action commit `
  -RunId $run.RunId `
  -ReservationId $reservation.ReservationId `
  -ActualAmount 980

& $runtime -Action evidence `
  -RunId $run.RunId `
  -EvidenceKind source-file `
  -Source "src/auth/google.ts" `
  -TokenCost 980 `
  -Relevance 0.94

& $runtime -Action llm `
  -RunId $run.RunId `
  -InputTokens 3200 `
  -OutputTokens 900

& $runtime -Action validate `
  -RunId $run.RunId `
  -Validator "auth-tests" `
  -ValidationResult pass

& $runtime -Action complete -RunId $run.RunId
```

## Budget Reservation

Context acquisition can be measured before and after it happens:

```text
reserve(estimated cost)
        |
        +-- commit(actual cost)
        |
        +-- release()
```

This gives the future Evidence Engine a safe primitive for deciding whether additional information is worth acquiring.

Evidence metadata and budget accounting are intentionally separate in V0: recording an `evidence` event does not consume the context budget by itself. The caller must reserve and commit the actual context cost. This avoids accidental double-counting.

## Ledger

Every state-changing action also appends an event to the JSONL ledger. A state file is kept per run for fast inspection.

The ledger is intended to answer questions such as:

- how many tokens were consumed before a validated result;
- how many LLM calls were required;
- which evidence was acquired;
- whether a lower-cost strategy later escalated;
- how often budget limits would have been exceeded;
- which validators actually established success.

## Initial Metric

The first useful metric is **Tokens To Validated Outcome (TTVO)**:

```text
context tokens
+ LLM input tokens
+ LLM output tokens
until hard validation passes
```

Money, latency, tool execution, retries, and provider-specific prices can be layered on after reliable baseline telemetry exists.

## Rollout

1. **V0 - Shadow telemetry:** record current behavior; do not block it.
2. **V1 - Evidence ranking:** score candidate evidence and compare against what the current flow loaded.
3. **V2 - Progressive context:** acquire high-value evidence first with budget gates.
4. **V3 - Progressive escalation:** targeted -> balanced -> deep based on failed validation or missing evidence.
5. **V4 - Learned strategy policy:** train a small local classifier only after enough validated runs exist.

The learned model is deliberately not the starting point. The runtime first creates the dataset needed to know whether a learned policy is actually better.

## V0 Concurrency Boundary

V0 assumes a single writer per resolution run. State replacement is atomic, but concurrent writers for the same `RunId` are not yet coordinated with a lock. This is acceptable for shadow telemetry, but `enforce` mode must not be enabled until per-run locking and atomic ledger coordination are implemented and tested.
