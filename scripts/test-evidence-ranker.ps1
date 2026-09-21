[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$ranker = Join-Path $repoRoot "orquestrador\bin\evidence-ranker.ps1"
if (-not (Test-Path -LiteralPath $ranker)) {
  throw "Evidence ranker not found: $ranker"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("maestro-evidence-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$candidatesPath = Join-Path $tempRoot "candidates.json"

$candidates = @(
  [ordered]@{
    id = "stack"
    kind = "error"
    source = "stack-trace"
    contentHash = "hash-stack"
    required = $true
    estimatedTokens = 120
    relevance = 1.0
    reliability = 0.95
    freshness = 1.0
    failureRelation = 1.0
    dependencyProximity = 0.8
  },
  [ordered]@{
    id = "auth-file"
    kind = "source-file"
    source = "src/auth/google.ts"
    contentHash = "hash-auth"
    required = $false
    estimatedTokens = 800
    relevance = 0.95
    reliability = 0.9
    freshness = 0.9
    failureRelation = 0.95
    dependencyProximity = 1.0
  },
  [ordered]@{
    id = "auth-file-copy"
    kind = "memory"
    source = "DEV/RESEARCH/auth-copy.md"
    contentHash = "hash-auth"
    required = $false
    estimatedTokens = 700
    relevance = 0.7
    reliability = 0.7
    freshness = 0.5
    failureRelation = 0.5
    dependencyProximity = 0.5
  },
  [ordered]@{
    id = "whole-repo"
    kind = "repository"
    source = "."
    contentHash = "hash-repo"
    required = $false
    estimatedTokens = 50000
    relevance = 0.25
    reliability = 0.6
    freshness = 0.8
    failureRelation = 0.1
    dependencyProximity = 0.1
  }
)

try {
  [System.IO.File]::WriteAllText($candidatesPath, ($candidates | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
  $result = & $ranker -CandidatesPath $candidatesPath -Strategy targeted

  $selectedIds = @($result.selected | ForEach-Object { $_.id })
  if (-not ($selectedIds -contains "stack")) {
    throw "Required stack evidence was not selected."
  }
  if (-not ($selectedIds -contains "auth-file")) {
    throw "High-value auth evidence was not selected."
  }
  if ($selectedIds -contains "whole-repo") {
    throw "Low-value oversized repository context should not be selected."
  }

  if (@($result.duplicates).Count -ne 1) {
    throw "Expected exactly one deduplicated candidate."
  }
  if ($result.estimatedSelectedTokens -gt $result.tokenBudget) {
    throw "Optional evidence selection exceeded targeted token budget."
  }

  "Evidence ranker self-test passed."
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
