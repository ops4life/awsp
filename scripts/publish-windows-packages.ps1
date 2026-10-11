# Publishes the Windows packages for a released version. Missing secrets are skipped, not errors.
#   CHOCO_API_KEY      push awsp.<version>.nupkg to community.chocolatey.org
#   WINGET_PKGS_TOKEN  submit a version bump PR to microsoft/winget-pkgs via wingetcreate
param(
  [Parameter(Mandatory)][string]$Version,
  [Parameter(Mandatory)][string]$Dir
)
$ErrorActionPreference = 'Stop'
$failures = @()

# Each publish runs on its own; a failure is recorded and reported at the end so one
# bad credential does not block the other target.
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

if ($env:WINGET_PKGS_TOKEN) {
  try {
    $wc = Join-Path ([System.IO.Path]::GetTempPath()) 'wingetcreate.exe'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/wingetcreate/latest' -OutFile $wc
    $url = "https://github.com/ops4life/awsp/releases/download/v$Version/awsp-$Version-setup.exe"
    & $wc update ops4life.awsp --version $Version --urls $url --submit --token $env:WINGET_PKGS_TOKEN
    if ($LASTEXITCODE -ne 0) { throw 'wingetcreate update failed' }
  } catch {
    Write-Host "::error::$_"
    $failures += 'winget'
  }
} else {
  Write-Host '::notice::WINGET_PKGS_TOKEN not set; skipping winget submission'
}

if ($failures.Count -gt 0) { throw "Publish failed for: $($failures -join ', ')" }
