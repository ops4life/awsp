# Publishes the Windows packages for a released version. Missing secrets are skipped, not errors.
#   CHOCO_API_KEY      push awsp.<version>.nupkg to community.chocolatey.org
#   WINGET_PKGS_TOKEN  submit a version bump PR to microsoft/winget-pkgs via wingetcreate
param(
  [Parameter(Mandatory)][string]$Version,
  [Parameter(Mandatory)][string]$Dir
)
$ErrorActionPreference = 'Stop'

if ($env:CHOCO_API_KEY) {
  choco push (Join-Path $Dir "awsp.$Version.nupkg") --source https://push.chocolatey.org/ --api-key $env:CHOCO_API_KEY
  if ($LASTEXITCODE -ne 0) { throw 'choco push failed' }
} else {
  Write-Host '::notice::CHOCO_API_KEY not set; skipping Chocolatey publish'
}

if ($env:WINGET_PKGS_TOKEN) {
  $wc = Join-Path ([System.IO.Path]::GetTempPath()) 'wingetcreate.exe'
  Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/wingetcreate/latest' -OutFile $wc
  $url = "https://github.com/ops4life/awsp/releases/download/v$Version/awsp-$Version-setup.exe"
  & $wc update ops4life.awsp --version $Version --urls $url --submit --token $env:WINGET_PKGS_TOKEN
  if ($LASTEXITCODE -ne 0) { throw 'wingetcreate update failed' }
} else {
  Write-Host '::notice::WINGET_PKGS_TOKEN not set; skipping winget submission'
}
