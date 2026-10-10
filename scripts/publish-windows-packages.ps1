# Publishes the Windows packages for a released version. Missing secrets are skipped, not errors.
#   CHOCO_API_KEY      push awsp.<version>.nupkg to community.chocolatey.org
param(
  [Parameter(Mandatory)][string]$Version,
  [Parameter(Mandatory)][string]$Dir
)
$ErrorActionPreference = 'Stop'
$failures = @()

if ($env:CHOCO_API_KEY) {
  try {
    choco push (Join-Path $Dir "awsp.$Version.nupkg") --source https://push.chocolatey.org/ --api-key $env:CHOCO_API_KEY
    if ($LASTEXITCODE -ne 0) { throw 'choco push failed' }
  } catch {
    Write-Host "::error::$_"
    $failures += 'Chocolatey'
  }
} else {
  Write-Host '::notice::CHOCO_API_KEY not set; skipping Chocolatey publish'
}

if ($failures.Count -gt 0) { throw "Publish failed for: $($failures -join ', ')" }
