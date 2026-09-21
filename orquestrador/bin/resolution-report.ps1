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

function Get-RunAccumulator {
  param(
    [hashtable]$Map,
    [string]$RunId
  )

  if (-not $Map.ContainsKey($RunId)) {
    $Map[$RunId] = [pscustomobject][ordered]@{
      startedAt = $null
      contextTokens = 0
      inputTokens = 0
      outputTokens = 0
      candidateValidatedTokens = $null
      candidateValidatedAt = $null
      hadBudgetPressure = $false
    }
  }
  return $Map[$RunId]
}

if (-not (Test-Path -LiteralPath $LedgerPath)) {
  throw "Resolution ledger not found: $LedgerPath"
}

$completed = New-Object System.Collections.Generic.List[object]
$invalidLines = New-Object System.Collections.Generic.List[int]
$accumulators = @{}
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

  $runId = [string]$event.runId
  if ([string]::IsNullOrWhiteSpace($runId)) { continue }
  $acc = Get-RunAccumulator -Map $accumulators -RunId $runId

  switch ([string]$event.event) {
    "run-started" {
      $acc.startedAt = [string]$event.timestamp
      break
    }

    "budget-reserved" {
      if ([bool]$event.payload.wouldExceed) {
        $acc.hadBudgetPressure = $true
      }
      break
    }

    "budget-committed" {
      if ([string]$event.payload.type -eq "contextTokens") {
        $acc.contextTokens = [int]$acc.contextTokens + [int]$event.payload.actual
      }
      break
    }

    "llm-usage-recorded" {
      $acc.inputTokens = [int]$acc.inputTokens + [int]$event.payload.call.inputTokens
      $acc.outputTokens = [int]$acc.outputTokens + [int]$event.payload.call.outputTokens
      break
    }

    "validation-recorded" {
      $isValidated = $false
      if ($null -ne $event.payload.validated) {
        $isValidated = [bool]$event.payload.validated
      } elseif ($null -ne $event.payload.result) {
        # Backward-compatible reading of early V0 ledgers.
        $isValidated = ([string]$event.payload.result -eq "pass")
      }

      if ($isValidated) {
        if ($null -eq $acc.candidateValidatedTokens) {
          $acc.candidateValidatedTokens = [int]$acc.contextTokens + [int]$acc.inputTokens + [int]$acc.outputTokens
          $acc.candidateValidatedAt = [string]$event.timestamp
        }
      } else {
        # A later failed/unknown required validation revokes the previous candidate.
        $acc.candidateValidatedTokens = $null
        $acc.candidateValidatedAt = $null
      }
      break
    }

    "run-completed" {
      $budget = $event.payload.budget
      $contextTokens = [int]$budget.usage.contextTokens
      $inputTokens = [int]$budget.usage.inputTokens
      $outputTokens = [int]$budget.usage.outputTokens
      $totalTokens = $contextTokens + $inputTokens + $outputTokens
      $validated = [bool]$event.payload.validated

      $ttvo = $null
      $timeToValidatedMs = $null
      if ($validated) {
        if ($null -ne $acc.candidateValidatedTokens) {
          $ttvo = [int]$acc.candidateValidatedTokens
        } else {
          # Compatibility fallback for ledgers written before validation transition state was recorded.
          $ttvo = $totalTokens
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$acc.startedAt) -and -not [string]::IsNullOrWhiteSpace([string]$acc.candidateValidatedAt)) {
          $timeToValidatedMs = [int64]([DateTimeOffset]::Parse([string]$acc.candidateValidatedAt) - [DateTimeOffset]::Parse([string]$acc.startedAt)).TotalMilliseconds
        }
      }

      $withinFinalBudget = [bool]$event.payload.withinBudget
      $completed.Add([pscustomobject][ordered]@{
        runId = $runId
        timestamp = [string]$event.timestamp
        status = [string]$event.payload.status
        validated = $validated
        strategy = [string]$event.payload.strategy
        contextTokens = $contextTokens
        inputTokens = $inputTokens
        outputTokens = $outputTokens
        totalTokens = $totalTokens
        tokensToValidatedOutcome = $ttvo
        llmCalls = [int]$budget.usage.llmCalls
        escalations = [int]$budget.usage.escalations
        timeToValidatedMs = $timeToValidatedMs
        completionDurationMs = if ($null -ne $event.payload.durationMs) { [int64]$event.payload.durationMs } else { $null }
        withinFinalBudget = $withinFinalBudget
        hadBudgetPressure = [bool]$acc.hadBudgetPressure
        budgetHealthy = ($withinFinalBudget -and -not [bool]$acc.hadBudgetPressure)
        evidenceCount = [int]$event.payload.evidenceCount
        validationCount = [int]$event.payload.validationCount
        openReservations = if ($null -ne $event.payload.openReservations) { [int]$event.payload.openReservations } else { 0 }
      })
      break
    }
  }
}

$validatedRuns = @($completed | Where-Object { $_.validated })
$withEscalation = @($completed | Where-Object { $_.escalations -gt 0 })
$budgetHealthy = @($completed | Where-Object { $_.budgetHealthy })
$firstPass = @($completed | Where-Object { $_.validated -and $_.llmCalls -le 1 -and $_.escalations -eq 0 })

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
    medianTokensToValidatedOutcome = Get-Median -Values @($validRuns | ForEach-Object { $_.tokensToValidatedOutcome })
    averageTimeToValidatedMs = Get-Average -Values @($validRuns | ForEach-Object { $_.timeToValidatedMs })
    averageCompletionDurationMs = Get-Average -Values @($runs | ForEach-Object { $_.completionDurationMs })
  }
}

$result = [pscustomobject][ordered]@{
  ledgerPath = [System.IO.Path]::GetFullPath($LedgerPath)
  completedRuns = $completed.Count
  validatedRuns = $validatedRuns.Count
  validationRate = if ($completed.Count -gt 0) { [Math]::Round(($validatedRuns.Count / [double]$completed.Count), 4) } else { $null }
  firstPassValidatedRuns = $firstPass.Count
  firstPassValidationRate = if ($completed.Count -gt 0) { [Math]::Round(($firstPass.Count / [double]$completed.Count), 4) } else { $null }
  escalationRate = if ($completed.Count -gt 0) { [Math]::Round(($withEscalation.Count / [double]$completed.Count), 4) } else { $null }
  budgetHealthyRate = if ($completed.Count -gt 0) { [Math]::Round(($budgetHealthy.Count / [double]$completed.Count), 4) } else { $null }
  medianTokensToValidatedOutcome = Get-Median -Values @($validatedRuns | ForEach-Object { $_.tokensToValidatedOutcome })
  averageTokensToValidatedOutcome = Get-Average -Values @($validatedRuns | ForEach-Object { $_.tokensToValidatedOutcome })
  averageTimeToValidatedMs = Get-Average -Values @($validatedRuns | ForEach-Object { $_.timeToValidatedMs })
  averageCompletionDurationMs = Get-Average -Values @($completed | ForEach-Object { $_.completionDurationMs })
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
