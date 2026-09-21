[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("start", "reserve", "commit", "release", "evidence", "llm", "validate", "escalate", "complete", "show")]
  [string]$Action,

  [string]$RunId = "",
  [string]$Task = "",
  [string]$TaskClass = "unknown",
  [string[]]$Acceptance = @(),
  [string[]]$RequiredValidators = @(),
  [string]$Tool = "unknown",
  [string]$Profile = "",

  [ValidateSet("targeted", "balanced", "deep")]
  [string]$Strategy = "targeted",

  [ValidateSet("contextTokens", "inputTokens", "outputTokens", "llmCalls", "escalations")]
  [string]$BudgetType = "contextTokens",

  [int]$Amount = 0,
  [int]$ActualAmount = -1,
  [string]$ReservationId = "",

  [string]$EvidenceKind = "",
  [string]$Source = "",
  [int]$TokenCost = 0,
  [double]$Relevance = 0,
  [double]$Reliability = 0,
  [double]$Freshness = 0,

  [int]$InputTokens = 0,
  [int]$OutputTokens = 0,
  [string]$Provider = "",
  [string]$Model = "",
  [int]$DurationMs = 0,

  [string]$Validator = "",
  [ValidateSet("pass", "fail", "soft-pass", "unknown")]
  [string]$ValidationResult = "unknown",

  [ValidateSet("auto", "failed", "cancelled")]
  [string]$Completion = "auto",

  [string]$Notes = "",
  [string]$HomePath = [Environment]::GetFolderPath("UserProfile")
)

$ErrorActionPreference = "Stop"

function Get-UtcTimestamp {
  return [DateTimeOffset]::UtcNow.ToString("o")
}

function Get-RuntimeConfig {
  $configPath = Join-Path (Split-Path -Parent $PSScriptRoot) "RESOLUTION_RUNTIME.json"
  if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Resolution runtime config not found: $configPath"
  }

  return Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Resolve-ConfiguredPath {
  param(
    [string]$ConfiguredPath,
    [string]$UserHome
  )

  if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
    throw "Configured runtime path is empty."
  }

  $homeForText = [System.IO.Path]::GetFullPath($UserHome).TrimEnd([char[]]@('\\', '/'))
  $resolved = $ConfiguredPath.Replace("{{USER_HOME}}", $homeForText)
  $resolved = $resolved.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  return [System.IO.Path]::GetFullPath($resolved)
}

function Assert-RunId {
  param([string]$Id)

  if ([string]::IsNullOrWhiteSpace($Id)) {
    throw "RunId is required for action '$Action'."
  }

  if ($Id -notmatch "^[A-Za-z0-9._-]+$") {
    throw "RunId contains unsupported characters."
  }
}

function Get-StateFile {
  param(
    [string]$StateRoot,
    [string]$Id
  )

  Assert-RunId -Id $Id
  return Join-Path $StateRoot "$Id.json"
}

function Read-State {
  param(
    [string]$StateRoot,
    [string]$Id
  )

  $path = Get-StateFile -StateRoot $StateRoot -Id $Id
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Resolution run not found: $Id"
  }

  return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-State {
  param(
    [string]$StateRoot,
    [object]$State
  )

  New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
  $path = Get-StateFile -StateRoot $StateRoot -Id $State.id
  $tmp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
  $json = $State | ConvertTo-Json -Depth 16
  [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Append-LedgerEvent {
  param(
    [string]$LedgerPath,
    [string]$Id,
    [string]$EventType,
    [object]$Payload
  )

  $dir = Split-Path -Parent $LedgerPath
  New-Item -ItemType Directory -Force -Path $dir | Out-Null

  $event = [ordered]@{
    version = 1
    timestamp = Get-UtcTimestamp
    runId = $Id
    event = $EventType
    payload = $Payload
  }

  $line = $event | ConvertTo-Json -Depth 16 -Compress
  [System.IO.File]::AppendAllText($LedgerPath, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function New-BudgetObject {
  param([object]$StrategyConfig)

  return [pscustomobject][ordered]@{
    limits = [pscustomobject][ordered]@{
      contextTokens = [int]$StrategyConfig.maxContextTokens
      inputTokens = [int]$StrategyConfig.maxInputTokens
      outputTokens = [int]$StrategyConfig.maxOutputTokens
      llmCalls = [int]$StrategyConfig.maxLlmCalls
      escalations = [int]$StrategyConfig.maxEscalations
    }
    usage = [pscustomobject][ordered]@{
      contextTokens = 0
      inputTokens = 0
      outputTokens = 0
      llmCalls = 0
      escalations = 0
    }
    reserved = [pscustomobject][ordered]@{
      contextTokens = 0
      inputTokens = 0
      outputTokens = 0
      llmCalls = 0
      escalations = 0
    }
  }
}

function Get-StrategyConfig {
  param(
    [object]$Config,
    [string]$Name
  )

  $value = $Config.strategies.$Name
  if ($null -eq $value) {
    throw "Unknown resolution strategy: $Name"
  }

  return $value
}

function Get-BudgetStatus {
  param([object]$State)

  $violations = New-Object System.Collections.Generic.List[string]
  foreach ($name in @("contextTokens", "inputTokens", "outputTokens", "llmCalls", "escalations")) {
    $limit = [int]$State.budget.limits.$name
    $usage = [int]$State.budget.usage.$name
    $reserved = [int]$State.budget.reserved.$name
    if (($usage + $reserved) -gt $limit) {
      $violations.Add($name)
    }
  }

  return [pscustomobject]@{
    withinBudget = ($violations.Count -eq 0)
    violations = @($violations)
  }
}

function Update-ValidationOutcome {
  param([object]$State)

  $latest = @{}
  foreach ($item in @($State.validations)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$item.validator)) {
      $latest[[string]$item.validator] = [string]$item.result
    }
  }

  $required = @($State.contract.requiredValidators | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  $failed = @($latest.Keys | Where-Object { $latest[$_] -eq "fail" })
  $hardPassed = @($latest.Keys | Where-Object { $latest[$_] -eq "pass" })
  $softPassed = @($latest.Keys | Where-Object { $latest[$_] -eq "soft-pass" })

  if ($required.Count -gt 0) {
    $allRequiredPassed = $true
    foreach ($name in $required) {
      if (-not $latest.ContainsKey([string]$name) -or $latest[[string]$name] -ne "pass") {
        $allRequiredPassed = $false
        break
      }
    }
    $State.outcome.validated = ($allRequiredPassed -and $failed.Count -eq 0)
  } else {
    $State.outcome.validated = ($hardPassed.Count -gt 0 -and $failed.Count -eq 0)
  }

  $State.outcome.softValidated = ($softPassed.Count -gt 0 -and $failed.Count -eq 0)
}

function Save-And-Log {
  param(
    [object]$State,
    [string]$EventType,
    [object]$Payload
  )

  $State.updatedAt = Get-UtcTimestamp
  Write-State -StateRoot $script:stateRoot -State $State
  Append-LedgerEvent -LedgerPath $script:ledgerPath -Id $State.id -EventType $EventType -Payload $Payload
}

$config = Get-RuntimeConfig
if ([string]$config.mode -ne "shadow") {
  throw "Adaptive Resolution Runtime V0 supports shadow mode only. Refusing mode '$($config.mode)'."
}
$script:stateRoot = Resolve-ConfiguredPath -ConfiguredPath $config.statePath -UserHome $HomePath
$script:ledgerPath = Resolve-ConfiguredPath -ConfiguredPath $config.ledgerPath -UserHome $HomePath

switch ($Action) {
  "start" {
    if ([string]::IsNullOrWhiteSpace($Task)) {
      throw "Task is required for action 'start'."
    }

    $effectiveStrategy = $Strategy
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
      $mappedStrategy = $config.profileStrategyMap.$Profile
      if ($null -eq $mappedStrategy) {
        throw "Unknown execution profile for resolution mapping: $Profile"
      }
      $effectiveStrategy = [string]$mappedStrategy
    }

    $strategyConfig = Get-StrategyConfig -Config $config -Name $effectiveStrategy
    $id = $RunId
    if ([string]::IsNullOrWhiteSpace($id)) {
      $id = [guid]::NewGuid().ToString("N")
    }
    Assert-RunId -Id $id

    $stateFile = Get-StateFile -StateRoot $script:stateRoot -Id $id
    if (Test-Path -LiteralPath $stateFile) {
      throw "Resolution run already exists: $id"
    }

    $now = Get-UtcTimestamp
    $state = [pscustomobject][ordered]@{
      version = 1
      id = $id
      mode = [string]$config.mode
      status = "active"
      createdAt = $now
      updatedAt = $now
      contract = [pscustomobject][ordered]@{
        objective = $Task
        taskClass = $TaskClass
        acceptance = @($Acceptance)
        requiredValidators = @($RequiredValidators)
        tool = $Tool
        profile = $Profile
      }
      strategy = $effectiveStrategy
      budget = New-BudgetObject -StrategyConfig $strategyConfig
      reservations = @()
      evidence = @()
      llm = [pscustomobject][ordered]@{
        calls = @()
      }
      validations = @()
      outcome = [pscustomobject][ordered]@{
        validated = $false
        softValidated = $false
        completion = $null
        completedAt = $null
        durationMs = $null
      }
      notes = @()
    }

    Write-State -StateRoot $script:stateRoot -State $state
    Append-LedgerEvent -LedgerPath $script:ledgerPath -Id $id -EventType "run-started" -Payload ([pscustomobject]@{
      strategy = $effectiveStrategy
      taskClass = $TaskClass
      tool = $Tool
      profile = $Profile
      requiredValidators = @($RequiredValidators)
      mode = [string]$config.mode
    })

    [pscustomobject]@{
      RunId = $id
      Mode = [string]$config.mode
      Strategy = $effectiveStrategy
      Profile = $Profile
      Status = "active"
    }
    break
  }

  "reserve" {
    Assert-RunId -Id $RunId
    if ($Amount -le 0) {
      throw "Amount must be greater than zero for action 'reserve'."
    }

    $state = Read-State -StateRoot $script:stateRoot -Id $RunId
    if ($state.status -ne "active") {
      throw "Cannot reserve budget for run in status '$($state.status)'."
    }

    $limit = [int]$state.budget.limits.$BudgetType
    $usage = [int]$state.budget.usage.$BudgetType
    $reserved = [int]$state.budget.reserved.$BudgetType
    $wouldExceed = (($usage + $reserved + $Amount) -gt $limit)

    $reservation = [pscustomobject][ordered]@{
      id = [guid]::NewGuid().ToString("N")
      type = $BudgetType
      estimated = $Amount
      actual = $null
      status = "reserved"
      createdAt = Get-UtcTimestamp
      committedAt = $null
      releasedAt = $null
      notes = $Notes
    }

    $payload = [pscustomobject]@{
      reservationId = $reservation.id
      type = $BudgetType
      amount = $Amount
      limit = $limit
      usage = $usage
      alreadyReserved = $reserved
      wouldExceed = $wouldExceed
      mode = $state.mode
    }

    if ($wouldExceed -and $state.mode -eq "enforce") {
      Append-LedgerEvent -LedgerPath $script:ledgerPath -Id $state.id -EventType "budget-reservation-denied" -Payload $payload
      throw "Budget reservation would exceed '$BudgetType' limit."
    }

    $state.reservations = @($state.reservations) + $reservation
    $state.budget.reserved.$BudgetType = $reserved + $Amount
    Save-And-Log -State $state -EventType "budget-reserved" -Payload $payload

    [pscustomobject]@{
      RunId = $RunId
      ReservationId = $reservation.id
      Allowed = (-not $wouldExceed)
      ShadowAccepted = ($wouldExceed -and $state.mode -eq "shadow")
      WouldExceed = $wouldExceed
    }
    break
  }

  "commit" {
    Assert-RunId -Id $RunId
    if ([string]::IsNullOrWhiteSpace($ReservationId)) {
      throw "ReservationId is required for action 'commit'."
    }

    $state = Read-State -StateRoot $script:stateRoot -Id $RunId
    $reservation = @($state.reservations | Where-Object { $_.id -eq $ReservationId }) | Select-Object -First 1
    if ($null -eq $reservation) {
      throw "Reservation not found: $ReservationId"
    }
    if ($reservation.status -ne "reserved") {
      throw "Reservation '$ReservationId' is not active."
    }

    $actual = $ActualAmount
    if ($actual -lt 0) {
      $actual = [int]$reservation.estimated
    }

    $type = [string]$reservation.type
    $currentReserved = [int]$state.budget.reserved.$type
    $state.budget.reserved.$type = [Math]::Max(0, $currentReserved - [int]$reservation.estimated)
    $state.budget.usage.$type = [int]$state.budget.usage.$type + $actual
    $reservation.actual = $actual
    $reservation.status = "committed"
    $reservation.committedAt = Get-UtcTimestamp

    $budgetStatus = Get-BudgetStatus -State $state
    Save-And-Log -State $state -EventType "budget-committed" -Payload ([pscustomobject]@{
      reservationId = $ReservationId
      type = $type
      estimated = [int]$reservation.estimated
      actual = $actual
      withinBudget = $budgetStatus.withinBudget
      violations = $budgetStatus.violations
    })

    [pscustomobject]@{
      RunId = $RunId
      ReservationId = $ReservationId
      Actual = $actual
      WithinBudget = $budgetStatus.withinBudget
      Violations = $budgetStatus.violations
    }
    break
  }

  "release" {
    Assert-RunId -Id $RunId
    if ([string]::IsNullOrWhiteSpace($ReservationId)) {
      throw "ReservationId is required for action 'release'."
    }

    $state = Read-State -StateRoot $script:stateRoot -Id $RunId
    $reservation = @($state.reservations | Where-Object { $_.id -eq $ReservationId }) | Select-Object -First 1
    if ($null -eq $reservation) {
      throw "Reservation not found: $ReservationId"
    }
    if ($reservation.status -ne "reserved") {
      throw "Reservation '$ReservationId' is not active."
    }

    $type = [string]$reservation.type
    $currentReserved = [int]$state.budget.reserved.$type
    $state.budget.reserved.$type = [Math]::Max(0, $currentReserved - [int]$reservation.estimated)
    $reservation.status = "released"
    $reservation.releasedAt = Get-UtcTimestamp

    Save-And-Log -State $state -EventType "budget-released" -Payload ([pscustomobject]@{
      reservationId = $ReservationId
      type = $type
      estimated = [int]$reservation.estimated
    })

    [pscustomobject]@{
      RunId = $RunId
      ReservationId = $ReservationId
      Released = $true
    }
    break
  }

  "evidence" {
    Assert-RunId -Id $RunId
    if ([string]::IsNullOrWhiteSpace($EvidenceKind)) {
      throw "EvidenceKind is required for action 'evidence'."
    }
    if ([string]::IsNullOrWhiteSpace($Source)) {
      throw "Source is required for action 'evidence'."
    }

    $state = Read-State -StateRoot $script:stateRoot -Id $RunId
    $entry = [pscustomobject][ordered]@{
      id = [guid]::NewGuid().ToString("N")
      timestamp = Get-UtcTimestamp
      kind = $EvidenceKind
      source = $Source
      tokenCost = $TokenCost
      relevance = $Relevance
      reliability = $Reliability
      freshness = $Freshness
      notes = $Notes
    }

    $state.evidence = @($state.evidence) + $entry
    Save-And-Log -State $state -EventType "evidence-recorded" -Payload $entry

    [pscustomobject]@{
      RunId = $RunId
      EvidenceId = $entry.id
      Recorded = $true
    }
    break
  }

  "llm" {
    Assert-RunId -Id $RunId
    if ($InputTokens -lt 0 -or $OutputTokens -lt 0 -or $DurationMs -lt 0) {
      throw "InputTokens, OutputTokens, and DurationMs must be zero or greater."
    }

    $state = Read-State -StateRoot $script:stateRoot -Id $RunId
    $call = [pscustomobject][ordered]@{
      id = [guid]::NewGuid().ToString("N")
      timestamp = Get-UtcTimestamp
      inputTokens = $InputTokens
      outputTokens = $OutputTokens
      provider = $Provider
      model = $Model
      durationMs = $DurationMs
      notes = $Notes
    }

    $state.llm.calls = @($state.llm.calls) + $call
    $state.budget.usage.inputTokens = [int]$state.budget.usage.inputTokens + $InputTokens
    $state.budget.usage.outputTokens = [int]$state.budget.usage.outputTokens + $OutputTokens
    $state.budget.usage.llmCalls = [int]$state.budget.usage.llmCalls + 1

    $budgetStatus = Get-BudgetStatus -State $state
    Save-And-Log -State $state -EventType "llm-usage-recorded" -Payload ([pscustomobject]@{
      call = $call
      withinBudget = $budgetStatus.withinBudget
      violations = $budgetStatus.violations
    })

    [pscustomobject]@{
      RunId = $RunId
      LlmCallId = $call.id
      WithinBudget = $budgetStatus.withinBudget
      Violations = $budgetStatus.violations
    }
    break
  }

  "validate" {
    Assert-RunId -Id $RunId
    if ([string]::IsNullOrWhiteSpace($Validator)) {
      throw "Validator is required for action 'validate'."
    }

    $state = Read-State -StateRoot $script:stateRoot -Id $RunId
    $entry = [pscustomobject][ordered]@{
      id = [guid]::NewGuid().ToString("N")
      timestamp = Get-UtcTimestamp
      validator = $Validator
      result = $ValidationResult
      notes = $Notes
    }

    $state.validations = @($state.validations) + $entry
    Update-ValidationOutcome -State $state

    Save-And-Log -State $state -EventType "validation-recorded" -Payload $entry

    [pscustomobject]@{
      RunId = $RunId
      Validator = $Validator
      Result = $ValidationResult
      Validated = [bool]$state.outcome.validated
      SoftValidated = [bool]$state.outcome.softValidated
    }
    break
  }

  "escalate" {
    Assert-RunId -Id $RunId
    $state = Read-State -StateRoot $script:stateRoot -Id $RunId

    $order = @("targeted", "balanced", "deep")
    $currentIndex = [Array]::IndexOf($order, [string]$state.strategy)
    $nextIndex = $currentIndex + 1
    if ($currentIndex -lt 0 -or $nextIndex -ge $order.Count) {
      throw "No higher strategy available from '$($state.strategy)'."
    }

    $next = $order[$nextIndex]
    $previous = [string]$state.strategy
    $nextConfig = Get-StrategyConfig -Config $config -Name $next

    $state.strategy = $next
    $state.budget.usage.escalations = [int]$state.budget.usage.escalations + 1
    $state.budget.limits.contextTokens = [int]$nextConfig.maxContextTokens
    $state.budget.limits.inputTokens = [int]$nextConfig.maxInputTokens
    $state.budget.limits.outputTokens = [int]$nextConfig.maxOutputTokens
    $state.budget.limits.llmCalls = [int]$nextConfig.maxLlmCalls
    $state.budget.limits.escalations = [int]$nextConfig.maxEscalations

    $budgetStatus = Get-BudgetStatus -State $state
    Save-And-Log -State $state -EventType "strategy-escalated" -Payload ([pscustomobject]@{
      from = $previous
      to = $next
      reason = $Notes
      withinBudget = $budgetStatus.withinBudget
      violations = $budgetStatus.violations
    })

    [pscustomobject]@{
      RunId = $RunId
      From = $previous
      To = $next
      WithinBudget = $budgetStatus.withinBudget
    }
    break
  }

  "complete" {
    Assert-RunId -Id $RunId
    $state = Read-State -StateRoot $script:stateRoot -Id $RunId

    if ($Completion -eq "failed") {
      $state.status = "failed"
      $state.outcome.completion = "failed"
    } elseif ($Completion -eq "cancelled") {
      $state.status = "cancelled"
      $state.outcome.completion = "cancelled"
    } elseif ([bool]$state.outcome.validated) {
      $state.status = "validated"
      $state.outcome.completion = "validated"
    } else {
      $state.status = "completed-unvalidated"
      $state.outcome.completion = "completed-unvalidated"
    }

    if (-not [string]::IsNullOrWhiteSpace($Notes)) {
      $state.notes = @($state.notes) + $Notes
    }

    $completedAt = Get-UtcTimestamp
    $state.outcome.completedAt = $completedAt
    $state.outcome.durationMs = [int64]([DateTimeOffset]::Parse($completedAt) - [DateTimeOffset]::Parse([string]$state.createdAt)).TotalMilliseconds

    $budgetStatus = Get-BudgetStatus -State $state
    Save-And-Log -State $state -EventType "run-completed" -Payload ([pscustomobject]@{
      status = $state.status
      validated = [bool]$state.outcome.validated
      softValidated = [bool]$state.outcome.softValidated
      strategy = [string]$state.strategy
      budget = $state.budget
      withinBudget = $budgetStatus.withinBudget
      violations = $budgetStatus.violations
      evidenceCount = @($state.evidence).Count
      validationCount = @($state.validations).Count
      requiredValidators = @($state.contract.requiredValidators)
      durationMs = [int64]$state.outcome.durationMs
      openReservations = @($state.reservations | Where-Object { $_.status -eq "reserved" }).Count
    })

    [pscustomobject]@{
      RunId = $RunId
      Status = $state.status
      Validated = [bool]$state.outcome.validated
      Strategy = [string]$state.strategy
      ContextTokens = [int]$state.budget.usage.contextTokens
      InputTokens = [int]$state.budget.usage.inputTokens
      OutputTokens = [int]$state.budget.usage.outputTokens
      LlmCalls = [int]$state.budget.usage.llmCalls
      Escalations = [int]$state.budget.usage.escalations
      DurationMs = [int64]$state.outcome.durationMs
      OpenReservations = @($state.reservations | Where-Object { $_.status -eq "reserved" }).Count
      WithinBudget = $budgetStatus.withinBudget
    }
    break
  }

  "show" {
    Assert-RunId -Id $RunId
    Read-State -StateRoot $script:stateRoot -Id $RunId
    break
  }
}
