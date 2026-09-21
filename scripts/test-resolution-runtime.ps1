[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$runtime = Join-Path $repoRoot "orquestrador\bin\resolution-runtime.ps1"
if (-not (Test-Path -LiteralPath $runtime)) {
  throw "Runtime script not found: $runtime"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("maestro-resolution-test-" + [guid]::NewGuid().ToString("N"))
$home = Join-Path $tempRoot "home"
New-Item -ItemType Directory -Force -Path $home | Out-Null

function Assert-Equal {
  param(
    [object]$Actual,
    [object]$Expected,
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message. Expected '$Expected', got '$Actual'."
  }
}

try {
  $started = & $runtime `
    -Action start `
    -Task "Fix Google authentication regression" `
    -TaskClass "bugfix" `
    -Acceptance @("typecheck passes", "auth test passes") `
    -Tool "self-test" `
    -Strategy targeted `
    -HomePath $home

  $runId = [string]$started.RunId
  if ([string]::IsNullOrWhiteSpace($runId)) {
    throw "Runtime did not return a RunId."
  }

  $reservation = & $runtime `
    -Action reserve `
    -RunId $runId `
    -BudgetType contextTokens `
    -Amount 1000 `
    -Notes "auth source context" `
    -HomePath $home

  Assert-Equal -Actual $reservation.Allowed -Expected $true -Message "Expected context reservation to fit targeted budget"

  & $runtime `
    -Action commit `
    -RunId $runId `
    -ReservationId $reservation.ReservationId `
    -ActualAmount 900 `
    -HomePath $home | Out-Null

  & $runtime `
    -Action evidence `
    -RunId $runId `
    -EvidenceKind "source-file" `
    -Source "src/auth/google.ts" `
    -TokenCost 900 `
    -Relevance 0.95 `
    -Reliability 0.95 `
    -Freshness 1.0 `
    -HomePath $home | Out-Null

  & $runtime `
    -Action llm `
    -RunId $runId `
    -InputTokens 2000 `
    -OutputTokens 500 `
    -Notes "targeted repair" `
    -HomePath $home | Out-Null

  & $runtime `
    -Action validate `
    -RunId $runId `
    -Validator "typecheck+auth-test" `
    -ValidationResult pass `
    -HomePath $home | Out-Null

  $completed = & $runtime `
    -Action complete `
    -RunId $runId `
    -HomePath $home

  Assert-Equal -Actual $completed.Status -Expected "validated" -Message "Validated run should complete as validated"
  Assert-Equal -Actual $completed.ContextTokens -Expected 900 -Message "Committed context usage mismatch"
  Assert-Equal -Actual $completed.InputTokens -Expected 2000 -Message "Input token usage mismatch"
  Assert-Equal -Actual $completed.OutputTokens -Expected 500 -Message "Output token usage mismatch"
  Assert-Equal -Actual $completed.LlmCalls -Expected 1 -Message "LLM call count mismatch"

  $validationRegression = & $runtime `
    -Action start `
    -Task "Validation regression check" `
    -TaskClass "test" `
    -Tool "self-test" `
    -Strategy targeted `
    -HomePath $home

  & $runtime `
    -Action validate `
    -RunId $validationRegression.RunId `
    -Validator "first-check" `
    -ValidationResult pass `
    -HomePath $home | Out-Null

  & $runtime `
    -Action validate `
    -RunId $validationRegression.RunId `
    -Validator "regression-check" `
    -ValidationResult fail `
    -HomePath $home | Out-Null

  $validationState = & $runtime `
    -Action show `
    -RunId $validationRegression.RunId `
    -HomePath $home

  Assert-Equal -Actual $validationState.outcome.validated -Expected $false -Message "A later hard validation failure must revoke validated state"

  $validationCompleted = & $runtime `
    -Action complete `
    -RunId $validationRegression.RunId `
    -HomePath $home

  Assert-Equal -Actual $validationCompleted.Status -Expected "completed-unvalidated" -Message "Run with a hard validation failure must not complete as validated"

  $over = & $runtime `
    -Action start `
    -Task "Shadow over-budget check" `
    -TaskClass "test" `
    -Tool "self-test" `
    -Strategy targeted `
    -HomePath $home

  $overReservation = & $runtime `
    -Action reserve `
    -RunId $over.RunId `
    -BudgetType contextTokens `
    -Amount 6000 `
    -HomePath $home

  Assert-Equal -Actual $overReservation.Allowed -Expected $false -Message "Over-budget reservation should be flagged"
  Assert-Equal -Actual $overReservation.ShadowAccepted -Expected $true -Message "Shadow mode should record but not block over-budget reservations"

  $ledger = Join-Path $home ".orquestrador\logs\resolution-ledger.jsonl"
  if (-not (Test-Path -LiteralPath $ledger)) {
    throw "Resolution ledger was not created."
  }

  $lines = @(Get-Content -LiteralPath $ledger -Encoding UTF8)
  if ($lines.Count -lt 7) {
    throw "Resolution ledger has fewer events than expected."
  }

  foreach ($line in $lines) {
    $line | ConvertFrom-Json | Out-Null
  }

  "Adaptive Resolution Runtime self-test passed."
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
