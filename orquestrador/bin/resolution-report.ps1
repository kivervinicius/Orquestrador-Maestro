[CmdletBinding()]
param(
  [string]$LedgerPath = "",
  [string]$HomePath = [Environment]::GetFolderPath("UserProfile"),
  [switch]$AsJson
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($LedgerPath)) {
  $LedgerPath = Join-Path $HomePath ".orquestrador\logs\resolution-ledger.jsonl"
}

function Get-Average {
  param([object[]]$Values)
  $items = @($Values | Where-Object { $null -ne $_ })
  if ($items.Count -eq 0) { return $null }
  return [Math]::Round((($items | Measure-Object -Average).Average), 2)
}

function Get-Median {
  param([object[]]$Values)
  $items = @($Values | Where-Object { $null -ne $_ } | Sort-Object)
  if ($items.Count -eq 0) { return $null }
  $middle = [int][Math]::Floor($items.Count / 2)
  if (($items.Count % 2) -eq 1) {
    return [double]$items[$middle]
  }
  return [Math]::Round((([double]$items[$middle - 1] + [double]$items[$middle]) / 2.0), 2)
}

if (-not (Test-Path -LiteralPath $LedgerPath)) {
  throw "Resolution ledger not found: $LedgerPath"
}

$completed = New-Object System.Collections.Generic.List[object]
$invalidLines = New-Object System.Collections.Generic.List[int]
$lineNumber = 0
foreach ($line in Get-Content -LiteralPath $LedgerPath -Encoding UTF8) {
  $lineNumber++
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  try {
    $event = $line | ConvertFrom-Json
  } catch {
    $invalidLines.Add($lineNumber)
    continue
  }

  if ($event.event -eq "run-completed") {
    $budget = $event.payload.budget
    $contextTokens = [int]$budget.usage.contextTokens
    $inputTokens = [int]$budget.usage.inputTokens
    $outputTokens = [int]$budget.usage.outputTokens
    $totalTokens = $contextTokens + $inputTokens + $outputTokens

    $completed.Add([pscustomobject][ordered]@{
      runId = [string]$event.runId
      timestamp = [string]$event.timestamp
      status = [string]$event.payload.status
      validated = [bool]$event.payload.validated
      strategy = [string]$event.payload.strategy
      contextTokens = $contextTokens
      inputTokens = $inputTokens
      outputTokens = $outputTokens
      totalTokens = $totalTokens
      llmCalls = [int]$budget.usage.llmCalls
      escalations = [int]$budget.usage.escalations
      durationMs = if ($null -ne $event.payload.durationMs) { [int64]$event.payload.durationMs } else { $null }
      withinBudget = [bool]$event.payload.withinBudget
      evidenceCount = [int]$event.payload.evidenceCount
      validationCount = [int]$event.payload.validationCount
      openReservations = if ($null -ne $event.payload.openReservations) { [int]$event.payload.openReservations } else { 0 }
    })
  }
}

$validated = @($completed | Where-Object { $_.validated })
$withEscalation = @($completed | Where-Object { $_.escalations -gt 0 })
$withinBudget = @($completed | Where-Object { $_.withinBudget })
$firstPass = @($validated | Where-Object { $_.llmCalls -le 1 -and $_.escalations -eq 0 })

$byStrategy = @()
foreach ($strategy in @("targeted", "balanced", "deep")) {
  $runs = @($completed | Where-Object { $_.strategy -eq $strategy })
  if ($runs.Count -eq 0) { continue }
  $validRuns = @($runs | Where-Object { $_.validated })
  $byStrategy += [pscustomobject][ordered]@{
    strategy = $strategy
    runs = $runs.Count
    validated = $validRuns.Count
    validationRate = [Math]::Round(($validRuns.Count / [double]$runs.Count), 4)
    medianValidatedTokens = Get-Median -Values @($validRuns | ForEach-Object { $_.totalTokens })
    averageDurationMs = Get-Average -Values @($runs | ForEach-Object { $_.durationMs })
  }
}

$result = [pscustomobject][ordered]@{
  ledgerPath = [System.IO.Path]::GetFullPath($LedgerPath)
  completedRuns = $completed.Count
  validatedRuns = $validated.Count
  validationRate = if ($completed.Count -gt 0) { [Math]::Round(($validated.Count / [double]$completed.Count), 4) } else { $null }
  firstPassValidatedRuns = $firstPass.Count
  firstPassValidationRate = if ($validated.Count -gt 0) { [Math]::Round(($firstPass.Count / [double]$validated.Count), 4) } else { $null }
  escalationRate = if ($completed.Count -gt 0) { [Math]::Round(($withEscalation.Count / [double]$completed.Count), 4) } else { $null }
  withinBudgetRate = if ($completed.Count -gt 0) { [Math]::Round(($withinBudget.Count / [double]$completed.Count), 4) } else { $null }
  medianTokensToValidatedOutcome = Get-Median -Values @($validated | ForEach-Object { $_.totalTokens })
  averageTokensToValidatedOutcome = Get-Average -Values @($validated | ForEach-Object { $_.totalTokens })
  averageDurationMs = Get-Average -Values @($completed | ForEach-Object { $_.durationMs })
  totalLlmCalls = [int](($completed | Measure-Object -Property llmCalls -Sum).Sum)
  invalidLedgerLines = @($invalidLines)
  byStrategy = @($byStrategy)
  runs = @($completed)
}

if ($AsJson) {
  $result | ConvertTo-Json -Depth 12
} else {
  $result
}
