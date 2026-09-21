[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$CandidatesPath,

  [ValidateSet("targeted", "balanced", "deep")]
  [string]$Strategy = "targeted",

  [string]$ConfigPath = "",
  [switch]$AsJson
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) "RESOLUTION_RUNTIME.json"
}

function Clamp-Unit {
  param([double]$Value)
  return [Math]::Max(0.0, [Math]::Min(1.0, $Value))
}

function Get-CandidateId {
  param([object]$Candidate, [int]$Index)
  if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.id)) {
    return [string]$Candidate.id
  }
  return "candidate-$Index"
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Resolution runtime config not found: $ConfigPath"
}
if (-not (Test-Path -LiteralPath $CandidatesPath)) {
  throw "Evidence candidates file not found: $CandidatesPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$policy = $config.evidencePolicy
if ($null -eq $policy) {
  throw "Resolution runtime config does not define evidencePolicy."
}

$strategyConfig = $config.strategies.$Strategy
if ($null -eq $strategyConfig) {
  throw "Unknown strategy: $Strategy"
}

$raw = Get-Content -LiteralPath $CandidatesPath -Raw -Encoding UTF8 | ConvertFrom-Json
$candidates = @($raw)
$budget = [int]$strategyConfig.maxContextTokens
$maxCandidates = [int]$policy.maxCandidates.$Strategy
$minScore = [double]$policy.minimumPriorityScore
$tokenScale = [double]$policy.tokenScale

$evaluated = New-Object System.Collections.Generic.List[object]
$index = 0
foreach ($candidate in $candidates) {
  $index++
  $tokens = [int]$candidate.estimatedTokens
  if ($tokens -lt 0) {
    throw "Candidate estimatedTokens must be zero or greater: $(Get-CandidateId -Candidate $candidate -Index $index)"
  }

  $relevance = Clamp-Unit -Value ([double]$candidate.relevance)
  $reliability = Clamp-Unit -Value ([double]$candidate.reliability)
  $freshness = Clamp-Unit -Value ([double]$candidate.freshness)
  $failureRelation = Clamp-Unit -Value ([double]$candidate.failureRelation)
  $dependencyProximity = Clamp-Unit -Value ([double]$candidate.dependencyProximity)

  $informationValue =
    ($relevance * [double]$policy.weights.relevance) +
    ($reliability * [double]$policy.weights.reliability) +
    ($freshness * [double]$policy.weights.freshness) +
    ($failureRelation * [double]$policy.weights.failureRelation) +
    ($dependencyProximity * [double]$policy.weights.dependencyProximity)

  $costFactor = 1.0 / (1.0 + ($tokens / [Math]::Max(1.0, $tokenScale)))
  $priorityScore = $informationValue * $costFactor

  $evaluated.Add([pscustomobject][ordered]@{
    id = Get-CandidateId -Candidate $candidate -Index $index
    kind = [string]$candidate.kind
    source = [string]$candidate.source
    contentHash = [string]$candidate.contentHash
    required = [bool]$candidate.required
    estimatedTokens = $tokens
    relevance = $relevance
    reliability = $reliability
    freshness = $freshness
    failureRelation = $failureRelation
    dependencyProximity = $dependencyProximity
    informationValue = [Math]::Round($informationValue, 6)
    costFactor = [Math]::Round($costFactor, 6)
    priorityScore = [Math]::Round($priorityScore, 6)
  })
}

# Dedupe before selection. Prefer required evidence, then the highest priority score.
$deduped = New-Object System.Collections.Generic.List[object]
$duplicates = New-Object System.Collections.Generic.List[object]
$groups = @{}
foreach ($item in $evaluated) {
  $key = if (-not [string]::IsNullOrWhiteSpace($item.contentHash)) {
    "hash:$($item.contentHash)"
  } elseif (-not [string]::IsNullOrWhiteSpace($item.source)) {
    "source:$($item.source.ToLowerInvariant())"
  } else {
    "id:$($item.id)"
  }

  if (-not $groups.ContainsKey($key)) {
    $groups[$key] = New-Object System.Collections.Generic.List[object]
  }
  $groups[$key].Add($item)
}

foreach ($key in $groups.Keys) {
  $ordered = @($groups[$key] | Sort-Object @{ Expression = { if ($_.required) { 1 } else { 0 } }; Descending = $true }, @{ Expression = { $_.priorityScore }; Descending = $true })
  $deduped.Add($ordered[0])
  foreach ($duplicate in @($ordered | Select-Object -Skip 1)) {
    $duplicates.Add([pscustomobject]@{
      id = $duplicate.id
      source = $duplicate.source
      reason = "duplicate"
      duplicateOf = $ordered[0].id
    })
  }
}

$selected = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]
$usedTokens = 0
$budgetOverflow = $false

$required = @($deduped | Where-Object { $_.required } | Sort-Object @{ Expression = { $_.priorityScore }; Descending = $true })
foreach ($item in $required) {
  $selected.Add($item)
  $usedTokens += [int]$item.estimatedTokens
  if ($usedTokens -gt $budget) {
    $budgetOverflow = $true
  }
}

$optional = @($deduped | Where-Object { -not $_.required } | Sort-Object @{ Expression = { $_.priorityScore }; Descending = $true })
foreach ($item in $optional) {
  if ($item.priorityScore -lt $minScore) {
    $skipped.Add([pscustomobject]@{
      id = $item.id
      source = $item.source
      reason = "below-minimum-score"
      priorityScore = $item.priorityScore
      estimatedTokens = $item.estimatedTokens
    })
    continue
  }

  if ($selected.Count -ge $maxCandidates) {
    $skipped.Add([pscustomobject]@{
      id = $item.id
      source = $item.source
      reason = "candidate-limit"
      priorityScore = $item.priorityScore
      estimatedTokens = $item.estimatedTokens
    })
    continue
  }

  if (($usedTokens + [int]$item.estimatedTokens) -gt $budget) {
    $skipped.Add([pscustomobject]@{
      id = $item.id
      source = $item.source
      reason = "token-budget"
      priorityScore = $item.priorityScore
      estimatedTokens = $item.estimatedTokens
    })
    continue
  }

  $selected.Add($item)
  $usedTokens += [int]$item.estimatedTokens
}

$result = [pscustomobject][ordered]@{
  policyVersion = [int]$policy.version
  strategy = $Strategy
  tokenBudget = $budget
  estimatedSelectedTokens = $usedTokens
  budgetOverflow = $budgetOverflow
  selected = @($selected)
  skipped = @($skipped)
  duplicates = @($duplicates)
  stats = [pscustomobject]@{
    inputCandidates = $candidates.Count
    uniqueCandidates = $deduped.Count
    selectedCandidates = $selected.Count
    skippedCandidates = $skipped.Count + $duplicates.Count
  }
}

if ($AsJson) {
  $result | ConvertTo-Json -Depth 12
} else {
  $result
}
