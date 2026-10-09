# --- awsp: AWS profile switcher for PowerShell (Windows PowerShell 5.1 and PowerShell 7+) ---
# Dot-source this file from your PowerShell profile (the installers add the line for you).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

$global:AWSP_VERSION = "1.8.1"
$global:_AWSP_SCRIPT = $PSCommandPath

function _awsp_home {
  if ($env:USERPROFILE) { return $env:USERPROFILE }
  return $HOME
}

function _awsp_state_dir {
  return (Join-Path (Join-Path (_awsp_home) '.config') 'awsp')
}

# Write-Host (not stderr) so messages are capturable with *>&1 in tests and transcripts.
function _awsp_err([string]$msg) {
  Write-Host $msg
}

function _awsp_read([string]$prompt) {
  return (Read-Host $prompt)
}

function _awsp_usage {
  Write-Output @'
Usage: awsp [options] [PROFILE]

Switch AWS profile with SSO auto-login (if needed). If PROFILE is omitted,
a numbered list will be shown.

Options:
  -h, --help         Show help and exit
  -V, --version      Show version and exit
  -l, --list         List profiles and exit
  -c, --current      Print current AWS profile and exit
  -u, --unset        Unset AWS profile & static creds and exit
  -U, --upgrade      Show how to upgrade awsp for this install method
  -a, --add          Add a new profile (SSO or static credentials) and switch to it
  -r, --remove       Remove a profile (prompts for selection if omitted)
  -m, --modify       Modify/reconfigure an existing profile (prompts if omitted)
  -L, --login        Force "aws sso login" for the selected/current profile
  -v, --verify       Verify identity via STS (default: auto)
      --no-verify    Do not verify identity
      --json         Output STS identity as JSON instead of table
  -q, --quiet        Suppress non-essential output
'@
}

function _awsp_unset([bool]$quiet) {
  foreach ($v in 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_PROFILE', 'AWS_DEFAULT_PROFILE') {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath (Join-Path (_awsp_state_dir) 'current_profile') -Force -ErrorAction SilentlyContinue
  if (-not $quiet) { Write-Host '-> AWS env cleared' }
}

function _awsp_upgrade {
  $path = [string]$global:_AWSP_SCRIPT
  $dir = ''
  if ($path) { $dir = Split-Path -Parent $path }
  if ($dir -match '(?i)[\\/]chocolatey[\\/]') {
    Write-Host 'awsp was installed with Chocolatey; upgrade with: choco upgrade awsp'
    return
  }
  if ($dir -match '(?i)[\\/](WinGet[\\/]|Programs[\\/]awsp)') {
    Write-Host 'awsp was installed with winget; upgrade with: winget upgrade ops4life.awsp'
    return
  }
  $root = ''
  if ($dir) { $root = Split-Path -Parent $dir }
  if ($root -and (Test-Path -LiteralPath (Join-Path $root '.git'))) {
    Write-Host "awsp is running from a git checkout; update with: git -C `"$root`" pull"
    return
  }
  Write-Host 'awsp was installed with the install script; upgrade by re-running it:'
  Write-Host '  irm https://raw.githubusercontent.com/ops4life/awsp/main/install.ps1 | iex'
}

function awsp {
  $ErrorActionPreference = 'Continue'
  $listOnly = $false; $showCurrent = $false; $forceLogin = $false; $unsetOnly = $false
  $upgrade = $false; $addProfile = $false; $removeProfile = $false; $modifyProfile = $false
  $verify = 'auto'   # auto|on|off
  $quiet = $false
  $outfmt = 'table'  # table|json
  $prof = ''
  $positionalOnly = $false

  # ---------- parse args ----------
  foreach ($a in $args) {
    $a = [string]$a
    if ($positionalOnly -or -not $a.StartsWith('-')) {
      if ($prof -eq '') { $prof = $a }
      else { _awsp_err 'awsp: only one PROFILE allowed'; $global:LASTEXITCODE = 2; return }
      continue
    }
    switch -CaseSensitive ($a) {
      { $_ -cin '-h', '--help' } { _awsp_usage; $global:LASTEXITCODE = 0; return }
      { $_ -cin '-V', '--version' } { Write-Output "awsp version $global:AWSP_VERSION"; $global:LASTEXITCODE = 0; return }
      { $_ -cin '-l', '--list' } { $listOnly = $true }
      { $_ -cin '-c', '--current' } { $showCurrent = $true }
      { $_ -cin '-u', '--unset' } { $unsetOnly = $true }
      { $_ -cin '-U', '--upgrade' } { $upgrade = $true }
      { $_ -cin '-a', '--add' } { $addProfile = $true }
      { $_ -cin '-r', '--remove' } { $removeProfile = $true }
      { $_ -cin '-m', '--modify' } { $modifyProfile = $true }
      { $_ -cin '-L', '--login' } { $forceLogin = $true }
      { $_ -cin '-v', '--verify' } { $verify = 'on' }
      '--no-verify' { $verify = 'off' }
      '--json' { $outfmt = 'json' }
      { $_ -cin '-q', '--quiet' } { $quiet = $true }
      '--' { $positionalOnly = $true }
      default { _awsp_err "awsp: unknown option: $a"; _awsp_usage; $global:LASTEXITCODE = 2; return }
    }
  }

  # ---------- quick actions ----------
  if ($showCurrent) {
    if ($env:AWS_PROFILE) { Write-Output $env:AWS_PROFILE } else { Write-Output '(no AWS_PROFILE set)' }
    $global:LASTEXITCODE = 0; return
  }
  if ($unsetOnly) { _awsp_unset $quiet; $global:LASTEXITCODE = 0; return }
  if ($upgrade) { _awsp_upgrade; $global:LASTEXITCODE = 0; return }

  # (profile discovery and switching are added in Task 2)
}
