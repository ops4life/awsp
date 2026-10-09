# awsp installer for Windows PowerShell 5.1 / PowerShell 7+.
# Downloads a release zip, verifies its checksum, installs to ~\.config\awsp and
# adds a line to your PowerShell profile that loads awsp.
#
#   irm https://raw.githubusercontent.com/ops4life/awsp/main/install.ps1 | iex
#
# Environment:
#   AWSP_VERSION       version to install, e.g. 1.9.0 (default: latest release)
#   PREFIX             install dir (default: ~\.config\awsp)
#   AWSP_ARCHIVE       local zip to install instead of downloading (testing)
#   AWSP_PROFILE_FILE  profile file to edit instead of the default ones (testing)
#   AWSP_UNINSTALL=1   remove awsp instead of installing it
# ASCII-only source: Windows PowerShell 5.1 reads BOM-less files as ANSI.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

& {
  $repo = 'ops4life/awsp'
  $userHome = $HOME
  if ($env:USERPROFILE) { $userHome = $env:USERPROFILE }
  $prefix = Join-Path (Join-Path $userHome '.config') 'awsp'
  if ($env:PREFIX) { $prefix = $env:PREFIX }
  $own = @('awsp.ps1', 'awsp-profile.ps1', 'current_profile', (Join-Path 'completions' 'awsp.completion.ps1'))

  function Die([string]$msg) { throw "awsp install: $msg" }

  function Invoke-ProfileHook([string]$action) {
    $hook = Join-Path $prefix 'awsp-profile.ps1'
    $hookArgs = @{ Action = $action; ScriptPath = (Join-Path $prefix 'awsp.ps1') }
    if ($env:AWSP_PROFILE_FILE) { $hookArgs.ProfileFile = $env:AWSP_PROFILE_FILE }
    & $hook @hookArgs
  }

  if ($env:AWSP_UNINSTALL -eq '1') {
    if (Test-Path -LiteralPath (Join-Path $prefix 'awsp-profile.ps1')) { Invoke-ProfileHook 'Remove' }
    foreach ($f in $own) { Remove-Item -LiteralPath (Join-Path $prefix $f) -Force -ErrorAction SilentlyContinue }
    foreach ($d in (Join-Path $prefix 'completions'), $prefix) {
      if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d -Force }
    }
    Write-Host "Uninstalled awsp from $prefix"
    return
  }

  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('awsp-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    if ($env:AWSP_ARCHIVE) {
      $zip = $env:AWSP_ARCHIVE
    } else {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      $version = $env:AWSP_VERSION
      if (-not $version) {
        $version = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
      }
      $version = $version.TrimStart('v')
      $name = "awsp-$version.zip"
      $base = "https://github.com/$repo/releases/download/v$version"
      Write-Host "-> Downloading awsp v$version..."
      $zip = Join-Path $tmp $name
      Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $zip
      Invoke-WebRequest -UseBasicParsing -Uri "$base/$name.sha256" -OutFile "$zip.sha256"
      Write-Host '-> Verifying checksum...'
      $expected = ((Get-Content -LiteralPath "$zip.sha256" -Raw).Trim() -split '\s+')[0]
      $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
      if ($actual -ne $expected) { Die 'checksum mismatch' }
    }

    $extract = Join-Path $tmp 'extract'
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $src = Get-ChildItem -LiteralPath $extract -Directory -Filter 'awsp-*' | Select-Object -First 1
    if (-not $src -or -not (Test-Path -LiteralPath (Join-Path $src.FullName 'bin/awsp.ps1'))) { Die 'unexpected archive layout' }

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
      Write-Host 'WARNING: AWS CLI not found in PATH; SSO features require AWS CLI v2 (https://aws.amazon.com/cli/).'
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $prefix 'completions') | Out-Null
    Copy-Item -LiteralPath (Join-Path $src.FullName 'bin/awsp.ps1') -Destination $prefix -Force
    Copy-Item -LiteralPath (Join-Path $src.FullName 'bin/awsp-profile.ps1') -Destination $prefix -Force
    Copy-Item -LiteralPath (Join-Path $src.FullName 'completions/awsp.completion.ps1') -Destination (Join-Path $prefix 'completions') -Force
    Invoke-ProfileHook 'Add'

    Write-Host "Installed to $prefix"
    Write-Host "Reload PowerShell or run: . '$(Join-Path $prefix 'awsp.ps1')'"
    $blocked = 'Restricted', 'AllSigned'
    $policy = [string](Get-ExecutionPolicy -Scope CurrentUser)
    if ($policy -eq 'Undefined') { $policy = [string](Get-ExecutionPolicy) }
    if ($blocked -contains $policy) {
      Write-Host 'NOTE: your execution policy blocks profile scripts. Run once: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
    }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
