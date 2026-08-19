<#
.SYNOPSIS
  Install the agy-staff skills for GitHub Copilot in VS Code (Windows).

.DESCRIPTION
  Copilot has no marketplace or plugin mechanism: skills are plain directories
  it discovers on disk. This script copies skills\* out of this checkout and
  rewrites, in the copies only, the three things that break once a skill leaves
  the repo:

    1. <skill-dir>/../../companion/agy-companion.mjs -> an absolute path back
       into this checkout (the relative hop no longer resolves).
    2. ../jobs/... cross-links -> ../agy-jobs/... (see 3).
    3. the frontmatter name: -> agy-<name>, because Copilot turns it into a
       bare slash command and ~\.copilot\skills is account-wide, where /ask or
       /review would collide with anything else installed.

  The sources under skills\ are never touched, so pulling upstream stays
  conflict-free. Re-run this script after every git pull to pick up changes.

  Requires the Antigravity CLI (agy) and Node.js.

.PARAMETER Project
  Install into the current project (.\.github\skills) instead of the account-
  wide ~\.copilot\skills.

.PARAMETER Dest
  Install into an explicit directory.

.PARAMETER DryRun
  Print what would happen, write nothing.

.EXAMPLE
  .\scripts\install-copilot.ps1

.EXAMPLE
  .\scripts\install-copilot.ps1 -Project
#>
[CmdletBinding()]
param(
  [switch]$Project,
  [string]$Dest,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Companion = Join-Path $RepoRoot 'companion\agy-companion.mjs'

# --- preconditions -----------------------------------------------------------

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  Write-Error "node not found on PATH. The companion runs on Node.js - install it first."
  exit 1
}

$agy = Get-Command agy -ErrorAction SilentlyContinue
if ($agy) { $agyVersion = (& agy --version 2>$null | Select-Object -First 1) }
if (-not $agy -or $LASTEXITCODE -ne 0) {
  Write-Error @"
'agy --version' failed. Install the Antigravity CLI first:
  https://antigravity.google/docs/cli/install
"@
  exit 1
}

if (-not (Test-Path -LiteralPath $Companion)) {
  Write-Error "companion not found at $Companion - run this script from its checkout."
  exit 1
}

# --- target ------------------------------------------------------------------

if ($Dest)         { $Target = $Dest }
elseif ($Project)  { $Target = Join-Path (Get-Location).Path '.github\skills' }
else               { $Target = Join-Path $HOME '.copilot\skills' }

Write-Host "agy-staff -> Copilot"
Write-Host "  source:    $(Join-Path $RepoRoot 'skills')"
Write-Host "  companion: $Companion"
Write-Host "  target:    $Target"
Write-Host "  node:      $(& node --version)   agy: $agyVersion"
Write-Host ""

$skillDirs = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'skills') -Directory -ErrorAction SilentlyContinue
if (-not $skillDirs) {
  Write-Error "no skills found under $(Join-Path $RepoRoot 'skills')"
  exit 1
}

foreach ($src in $skillDirs) {
  $name = "agy-$($src.Name)"
  $out  = Join-Path $Target $name

  if ($DryRun) {
    Write-Host "  would install $($src.Name) -> $out"
    continue
  }

  New-Item -ItemType Directory -Force -Path $Target | Out-Null
  if (Test-Path -LiteralPath $out) {
    Remove-Item -LiteralPath $out -Recurse -Force   # idempotent: replace, never merge
  }
  Copy-Item -LiteralPath $src.FullName -Destination $out -Recurse

  # Rewrite the copies. Replace() is literal, so no regex escaping of the
  # checkout path (which may contain $, backslashes, spaces) is needed.
  foreach ($md in Get-ChildItem -LiteralPath $out -Recurse -Filter '*.md' -File) {
    $text = Get-Content -LiteralPath $md.FullName -Raw
    $text = $text.Replace('<skill-dir>/../../companion/agy-companion.mjs', $Companion)
    $text = $text.Replace('../jobs/', '../agy-jobs/')
    Set-Content -LiteralPath $md.FullName -Value $text -NoNewline
  }

  # The frontmatter name only exists in SKILL.md; stop at the closing --- so
  # nothing in the body is touched.
  $skillFile = Join-Path $out 'SKILL.md'
  if (Test-Path -LiteralPath $skillFile) {
    $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $skillFile)
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($i -gt 0 -and $lines[$i] -eq '---') { break }
      if ($lines[$i] -match '^name: ') {
        $lines[$i] = $lines[$i] -replace '^name: ', 'name: agy-'
        break
      }
    }
    Set-Content -LiteralPath $skillFile -Value $lines
  }

  Write-Host "  installed $($src.Name) -> $out  (/$name)"
}

if ($DryRun) {
  Write-Host ""
  Write-Host "dry run - nothing was written."
  exit 0
}

Write-Host @"

Done ($($skillDirs.Count) skills). Verify in two steps:

  1. In a terminal, prove the companion itself works - this is the real
     dependency, and it fails loudly if agy is not signed in:

       node "$Companion" ask "reply with OK"

  2. Restart VS Code, open Copilot Chat, switch the mode picker to **Agent**
     (skills do not load in Ask or Edit mode), then run:

       /agy-ask reply with OK

Notes:
  - Copilot asks you to approve every terminal command, so a background job
    needs at least two approvals: one to start it, one for the wait that
    collects the result.
  - Upgrading: git pull in $RepoRoot, then re-run this script.
  - To remove the skills again: Remove-Item -Recurse (Join-Path `$HOME '.copilot\skills\agy-*')
"@
