[CmdletBinding()]
param(
  [string]$HomePath = [Environment]::GetFolderPath("UserProfile"),
  [switch]$SkipToolProfiles
)

$ErrorActionPreference = "Stop"

$issues = New-Object System.Collections.Generic.List[string]

function Add-Issue {
  param([string]$Message)
  $issues.Add($Message)
}

function Assert-Path {
  param([string]$Path, [string]$Label)
  if (-not (Test-Path -LiteralPath $Path)) {
    Add-Issue "$Label missing: $Path"
  }
}

function Assert-FileContains {
  param([string]$Path, [string]$Pattern, [string]$Label)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ($content -notmatch $Pattern) {
    Add-Issue "$Label does not include expected content: $Path"
  }
}

function Count-Dirs {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  return @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue).Count
}

function Count-Files {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  return @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue).Count
}

$orquestrador = Join-Path $HomePath ".orquestrador"
$codex = Join-Path $HomePath ".codex"

Assert-Path -Path (Join-Path $orquestrador "rules.md") -Label "Orquestrador rules"
Assert-Path -Path (Join-Path $orquestrador "maestro.md") -Label "Orquestrador maestro"
Assert-Path -Path (Join-Path $orquestrador "PROJECT_DEV_HIERARCHY.md") -Label "Project DEV hierarchy"
Assert-Path -Path (Join-Path $orquestrador "bin\init-project-dev.ps1") -Label "Project DEV initializer"
Assert-Path -Path (Join-Path $orquestrador "RESOLUTION_RUNTIME.json") -Label "Adaptive Resolution Runtime config"
Assert-Path -Path (Join-Path $orquestrador "bin\resolution-runtime.ps1") -Label "Adaptive Resolution Runtime"
Assert-Path -Path (Join-Path $orquestrador "SKILLS_INDEX.md") -Label "Orquestrador skills index"
Assert-Path -Path (Join-Path $orquestrador "SKILLS_ROUTER.json") -Label "Orquestrador skills router"
Assert-Path -Path (Join-Path $orquestrador "skills") -Label "Orquestrador canonical skills"
Assert-Path -Path (Join-Path $HomePath "AGENTS.md") -Label "Global AGENTS.md"
Assert-FileContains -Path (Join-Path $HomePath "AGENTS.md") -Pattern "DEV/" -Label "Global AGENTS.md"
Assert-FileContains -Path (Join-Path $HomePath "AGENTS.md") -Pattern "DEV/WORKLOG\.md" -Label "Global AGENTS.md"
Assert-FileContains -Path (Join-Path $orquestrador "rules.md") -Pattern "DEV/WORKLOG\.md" -Label "Orquestrador rules"
Assert-FileContains -Path (Join-Path $orquestrador "PROJECT_DEV_HIERARCHY.md") -Pattern "DEV/WORKLOG\.md" -Label "Project DEV hierarchy"

$resolutionConfigPath = Join-Path $orquestrador "RESOLUTION_RUNTIME.json"
if (Test-Path -LiteralPath $resolutionConfigPath) {
  try {
    $resolutionConfig = Get-Content -LiteralPath $resolutionConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$resolutionConfig.mode)) {
      Add-Issue "Adaptive Resolution Runtime config does not declare mode: $resolutionConfigPath"
    }
    foreach ($strategy in @("targeted", "balanced", "deep")) {
      if ($null -eq $resolutionConfig.strategies.$strategy) {
        Add-Issue "Adaptive Resolution Runtime config is missing strategy '$strategy': $resolutionConfigPath"
      }
    }
  } catch {
    Add-Issue "Adaptive Resolution Runtime config is not valid JSON: $resolutionConfigPath"
  }
}

Assert-Path -Path (Join-Path $codex "skills") -Label "Codex skills"
Assert-Path -Path (Join-Path $codex "agents") -Label "Codex agents"
Assert-Path -Path (Join-Path $codex "prompts") -Label "Codex prompts"

$compatRoots = @(
  ".agents\skills",
  ".claude\skills",
  ".opencode\skills",
  ".cursor\skills",
  ".gemini\skills",
  ".windsurf\skills",
  ".antigravity-skills\skills"
)

foreach ($root in $compatRoots) {
  Assert-Path -Path (Join-Path $HomePath $root) -Label "Compatibility skill root $root"
}

if (-not $SkipToolProfiles) {
  Assert-Path -Path (Join-Path $HomePath ".codex\AGENTS.md") -Label "Codex AGENTS profile"
  Assert-Path -Path (Join-Path $HomePath ".config\opencode\AGENTS.md") -Label "OpenCode global AGENTS profile"
  Assert-Path -Path (Join-Path $HomePath ".config\opencode\opencode.json") -Label "OpenCode global config"
  Assert-Path -Path (Join-Path $HomePath ".opencode\default-skill.json") -Label "OpenCode default skill profile"
  Assert-Path -Path (Join-Path $HomePath ".opencode\hooks.md") -Label "OpenCode hooks profile"
  Assert-Path -Path (Join-Path $HomePath ".claude\CLAUDE.md") -Label "Claude global memory"
  Assert-Path -Path (Join-Path $HomePath ".claude\hooks.md") -Label "Claude hooks profile"
  Assert-Path -Path (Join-Path $HomePath ".cursor\AGENTS.md") -Label "Cursor AGENTS profile"
  Assert-Path -Path (Join-Path $HomePath ".cursor\rules\orquestrador-maestro.mdc") -Label "Cursor Orquestrador rule"
  Assert-Path -Path (Join-Path $HomePath ".cursor\hooks.md") -Label "Cursor hooks profile"
  Assert-Path -Path (Join-Path $HomePath ".gemini\GEMINI.md") -Label "Gemini global context"
  Assert-Path -Path (Join-Path $HomePath ".gemini\hooks.md") -Label "Gemini hooks profile"
  Assert-Path -Path (Join-Path $HomePath ".codeium\windsurf\memories\global_rules.md") -Label "Windsurf global rules"
  Assert-Path -Path (Join-Path $HomePath ".windsurf\hooks.md") -Label "Windsurf hooks profile"
  Assert-Path -Path (Join-Path $HomePath "antigravity-rules.json") -Label "Antigravity global rules"
  Assert-Path -Path (Join-Path $HomePath ".antigravity\antigravity.json") -Label "Antigravity integration config"
  Assert-Path -Path (Join-Path $HomePath ".antigravity\settings.json") -Label "Antigravity settings"
  Assert-Path -Path (Join-Path $HomePath ".ai-standards\core\rules.md") -Label "Antigravity AI standards rules"
  Assert-Path -Path (Join-Path $HomePath ".ai-standards\core\workflow.md") -Label "Antigravity AI standards workflow"

  Assert-FileContains -Path (Join-Path $HomePath ".codex\AGENTS.md") -Pattern "DEV/WORKLOG\.md" -Label "Codex AGENTS profile"
  Assert-FileContains -Path (Join-Path $HomePath ".config\opencode\AGENTS.md") -Pattern "DEV/WORKLOG\.md" -Label "OpenCode global AGENTS profile"
  Assert-FileContains -Path (Join-Path $HomePath ".claude\CLAUDE.md") -Pattern "DEV/WORKLOG\.md" -Label "Claude global memory"
  Assert-FileContains -Path (Join-Path $HomePath ".cursor\AGENTS.md") -Pattern "DEV/WORKLOG\.md" -Label "Cursor AGENTS profile"
  Assert-FileContains -Path (Join-Path $HomePath ".cursor\rules\orquestrador-maestro.mdc") -Pattern "DEV/WORKLOG\.md" -Label "Cursor Orquestrador rule"
  Assert-FileContains -Path (Join-Path $HomePath ".gemini\GEMINI.md") -Pattern "DEV/WORKLOG\.md" -Label "Gemini global context"
  Assert-FileContains -Path (Join-Path $HomePath ".codeium\windsurf\memories\global_rules.md") -Pattern "DEV/WORKLOG\.md" -Label "Windsurf global rules"
  Assert-FileContains -Path (Join-Path $HomePath "antigravity-rules.json") -Pattern "\.ai-standards" -Label "Antigravity global rules"
  Assert-FileContains -Path (Join-Path $HomePath ".antigravity\antigravity.json") -Pattern "\.orquestrador" -Label "Antigravity integration config"
  Assert-FileContains -Path (Join-Path $HomePath ".ai-standards\core\rules.md") -Pattern "DEV/WORKLOG\.md" -Label "Antigravity AI standards rules"

  $opencodeConfig = Join-Path $HomePath ".config\opencode\opencode.json"
  if (Test-Path -LiteralPath $opencodeConfig) {
    try {
      $config = Get-Content -LiteralPath $opencodeConfig -Raw -Encoding UTF8 | ConvertFrom-Json
      $instructions = @($config.instructions)
      if (-not ($instructions -contains "~/.orquestrador/rules.md")) {
        Add-Issue "OpenCode global config does not include Orquestrador rules: $opencodeConfig"
      }
      if (-not ($instructions -contains "~/.orquestrador/maestro.md")) {
        Add-Issue "OpenCode global config does not include Orquestrador maestro: $opencodeConfig"
      }
    } catch {
      Add-Issue "OpenCode global config is not valid JSON: $opencodeConfig"
    }
  }

  foreach ($jsonPath in @(
    (Join-Path $HomePath "antigravity-rules.json"),
    (Join-Path $HomePath ".antigravity\antigravity.json"),
    (Join-Path $HomePath ".antigravity\settings.json")
  )) {
    if (Test-Path -LiteralPath $jsonPath) {
      try {
        Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
      } catch {
        Add-Issue "Antigravity JSON is not valid: $jsonPath"
      }
    }
  }
}

$summary = [pscustomobject]@{
  HomePath = $HomePath
  OrquestradorSkills = Count-Dirs -Path (Join-Path $orquestrador "skills")
  CodexSkills = Count-Dirs -Path (Join-Path $codex "skills")
  CodexAgents = Count-Files -Path (Join-Path $codex "agents")
  CodexPrompts = Count-Files -Path (Join-Path $codex "prompts")
  AgentSkills = Count-Dirs -Path (Join-Path $HomePath ".agents\skills")
  ClaudeSkills = Count-Dirs -Path (Join-Path $HomePath ".claude\skills")
  OpenCodeSkills = Count-Dirs -Path (Join-Path $HomePath ".opencode\skills")
  AntigravitySkills = Count-Dirs -Path (Join-Path $HomePath ".antigravity-skills\skills")
  ToolProfilesChecked = -not $SkipToolProfiles
}

if ($issues.Count -gt 0) {
  "Install verification failed:"
  $issues | ForEach-Object { "  - $_" }
  $summary | Format-List
  exit 1
}

"Install verification passed."
$summary | Format-List
