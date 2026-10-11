# --- awsp: AWS profile switcher for PowerShell (Windows PowerShell 5.1 and PowerShell 7+) ---
# Dot-source this file from your PowerShell profile (the installers add the line for you).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

$global:AWSP_VERSION = "1.12.0"
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
  if ($dir -match '(?i)[\\/]Programs[\\/]awsp') {
    Write-Host 'awsp was installed with the setup installer; download the latest awsp-<version>-setup.exe from https://github.com/ops4life/awsp/releases'
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

# "[profile x]" / "[ x ]" -> "x"; returns $null when the line is not a section header.
function _awsp_config_section_name([string]$line) {
  if ($line -match '^\s*\[(.*)\]\s*$') {
    return ($Matches[1].Trim() -replace '^profile\s+', '').Trim()
  }
  return $null
}

# Emits profile names (one per pipeline item). Callers wrap the call in @().
function _awsp_list_profiles([bool]$hasAws) {
  $found = @()
  if ($hasAws) {
    $found = @(& aws configure list-profiles 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
  }
  if ($found.Count -eq 0) {
    $dir = Join-Path (_awsp_home) '.aws'
    $names = New-Object System.Collections.Generic.List[string]
    $cfg = Join-Path $dir 'config'
    if (Test-Path -LiteralPath $cfg -PathType Leaf) {
      foreach ($l in [System.IO.File]::ReadAllLines($cfg)) {
        $n = _awsp_config_section_name $l
        if ($n) { $names.Add($n) }
      }
    }
    $cred = Join-Path $dir 'credentials'
    if (Test-Path -LiteralPath $cred -PathType Leaf) {
      foreach ($l in [System.IO.File]::ReadAllLines($cred)) {
        if ($l -match '^\s*\[(.*)\]\s*$') {
          $n = $Matches[1].Trim()
          if ($n) { $names.Add($n) }
        }
      }
    }
    $found = @($names | Sort-Object -Unique)
  }
  $found
}

# Numbered picker; returns the chosen name or $null (after printing why).
function _awsp_pick([string[]]$profiles, [bool]$quiet) {
  if ($profiles.Count -eq 0) { _awsp_err 'No AWS profiles found.'; return $null }
  if (-not $quiet) { Write-Host 'Pick an AWS profile:' }
  for ($i = 0; $i -lt $profiles.Count; $i++) {
    Write-Host ('{0,2}) {1}' -f ($i + 1), $profiles[$i])
  }
  $choice = _awsp_read 'Select number'
  $n = 0L
  if (([string]$choice) -notmatch '^\d+$' -or -not [long]::TryParse([string]$choice, [ref]$n) -or $n -lt 1 -or $n -gt $profiles.Count) {
    Write-Host 'No selection.'
    return $null
  }
  return $profiles[$n - 1]
}

# Runs `aws <args>` silently; $true when it exits 0.
function _awsp_aws_quiet([string[]]$a) {
  $global:LASTEXITCODE = 0
  & aws @a *> $null
  return ($LASTEXITCODE -eq 0)
}

function _awsp_is_sso_profile([string]$name) {
  $cfg = Join-Path (Join-Path (_awsp_home) '.aws') 'config'
  if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { return $false }
  try { $lines = [System.IO.File]::ReadAllLines($cfg) } catch { return $false }
  $in = $false
  foreach ($line in $lines) {
    $sec = _awsp_config_section_name $line
    if ($null -ne $sec) { $in = ($sec -ceq $name); continue }
    if ($in -and $line -match '^\s*(sso_start_url|sso_region|sso_account_id|sso_role_name)') { return $true }
  }
  return $false
}

# Comment out static keys in ~/.aws/credentials for an SSO profile (they would override SSO).
function _awsp_disable_static_creds([string]$name, [bool]$quiet = $true) {
  if (-not (_awsp_is_sso_profile $name)) { return }
  $creds = Join-Path (Join-Path (_awsp_home) '.aws') 'credentials'
  if (-not (Test-Path -LiteralPath $creds -PathType Leaf)) { return }
  try { $lines = [System.IO.File]::ReadAllLines($creds) } catch { return }
  $out = New-Object System.Collections.Generic.List[string]
  $in = $false; $modified = $false
  foreach ($line in $lines) {
    if ($line -ceq "[$name]") { $in = $true; $out.Add($line) }
    elseif ($line.StartsWith('[')) { $in = $false; $out.Add($line) }
    elseif ($in -and $line -match '^(aws_access_key_id|aws_secret_access_key|aws_session_token)') {
      $out.Add("# $line"); $modified = $true
    }
    else { $out.Add($line) }
  }
  if (-not $modified) { return }
  try {
    Copy-Item -LiteralPath $creds -Destination ("$creds.backup." + (Get-Date -Format yyyyMMddHHmmss)) -ErrorAction Stop
    [System.IO.File]::WriteAllLines($creds, $out.ToArray())
  } catch { return }
  if (-not $quiet) { Write-Host '-> Disabled static credentials in ~/.aws/credentials (backup created)' }
}

function _awsp_autoload {
  if ($env:AWS_PROFILE) { return }
  $file = Join-Path (_awsp_state_dir) 'current_profile'
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return }
  try { $saved = ([string](Get-Content -LiteralPath $file -TotalCount 1 -ErrorAction Stop)).Trim() } catch { return }
  if (-not $saved) { return }
  foreach ($v in 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  _awsp_disable_static_creds $saved $true
  $env:AWS_SDK_LOAD_CONFIG = '1'
  $env:AWS_PROFILE = $saved
  $env:AWS_DEFAULT_PROFILE = $saved
}

# Remove one profile section from a config ($isConfig) or credentials file, keeping a timestamped backup.
function _awsp_remove_section([string]$path, [string]$name, [bool]$isConfig) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
  try {
    $lines = [System.IO.File]::ReadAllLines($path)
    Copy-Item -LiteralPath $path -Destination ("$path.backup." + (Get-Date -Format yyyyMMddHHmmss)) -ErrorAction Stop
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
      if ($isConfig) {
        $sec = _awsp_config_section_name $line
        $isHeader = ($null -ne $sec)
        if ($isHeader) { $skip = ($sec -ceq $name) }
      } else {
        $isHeader = $line.StartsWith('[')
        if ($isHeader) { $skip = ($line -ceq "[$name]") }
      }
      if (-not $skip) { $out.Add($line) }
    }
    [System.IO.File]::WriteAllLines($path, $out.ToArray())
  } catch { Write-Verbose "awsp: could not rewrite ${path}: $_" }
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

  # ---------- collect profiles ----------
  $hasAws = [bool](Get-Command aws -ErrorAction SilentlyContinue)
  $profiles = @(_awsp_list_profiles $hasAws)
  $count = $profiles.Count

  if ($addProfile) {
    if (-not $hasAws) { _awsp_err 'awsp: aws CLI is required to add a profile'; $global:LASTEXITCODE = 1; return }
    $newName = _awsp_read 'New profile name'
    $tries = 1
    while ([string]::IsNullOrEmpty($newName)) {
      if ($tries -ge 5) { _awsp_err 'awsp: no profile name given'; $global:LASTEXITCODE = 1; return }
      $newName = _awsp_read 'Profile name cannot be empty. New profile name'
      $tries++
    }
    $type = _awsp_read "Profile type: [1] SSO (recommended)  [2] Static credentials`nSelect"
    $global:LASTEXITCODE = 0
    switch ($type) {
      '1' {
        $method = _awsp_read "SSO login method: [1] Open browser (recommended)  [2] Device code (no browser access)`nSelect"
        if ($method -eq '2') { & aws configure sso --profile $newName --use-device-code }
        else { & aws configure sso --profile $newName }
      }
      '2' { & aws configure --profile $newName }
      default { _awsp_err 'awsp: invalid selection'; $global:LASTEXITCODE = 1; return }
    }
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 1; return }
    $prof = $newName
  }

  if ($removeProfile) {
    if (-not $prof) {
      $prof = _awsp_pick $profiles $quiet
      if (-not $prof) { $global:LASTEXITCODE = 1; return }
    }
    $answer = _awsp_read "Remove profile `"$prof`"? This deletes it from ~/.aws/config and ~/.aws/credentials (y/N)"
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Removal cancelled.'; $global:LASTEXITCODE = 1; return }
    $awsDir = Join-Path (_awsp_home) '.aws'
    _awsp_remove_section (Join-Path $awsDir 'config') $prof $true
    _awsp_remove_section (Join-Path $awsDir 'credentials') $prof $false
    if ($env:AWS_PROFILE -ceq $prof) { _awsp_unset $quiet }
    $saved = Join-Path (_awsp_state_dir) 'current_profile'
    if ((Test-Path -LiteralPath $saved -PathType Leaf) -and ([string](Get-Content -LiteralPath $saved -TotalCount 1)).Trim() -ceq $prof) {
      Remove-Item -LiteralPath $saved -Force -ErrorAction SilentlyContinue
    }
    Write-Host "-> Removed profile `"$prof`" (backups created)"
    $global:LASTEXITCODE = 0; return
  }

  if ($modifyProfile) {
    if (-not $hasAws) { _awsp_err 'awsp: aws CLI is required to modify a profile'; $global:LASTEXITCODE = 1; return }
    if (-not $prof) {
      $prof = _awsp_pick $profiles $quiet
      if (-not $prof) { $global:LASTEXITCODE = 1; return }
    }
    $global:LASTEXITCODE = 0
    if (_awsp_is_sso_profile $prof) {
      $method = _awsp_read "SSO login method: [1] Open browser (recommended)  [2] Device code (no browser access)`nSelect"
      if ($method -eq '2') { & aws configure sso --profile $prof --use-device-code }
      else { & aws configure sso --profile $prof }
    } else {
      & aws configure --profile $prof
    }
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 1; return }
    Write-Host "-> Updated profile `"$prof`""
    $global:LASTEXITCODE = 0; return
  }

  if ($count -eq 0 -and -not $addProfile) {
    Write-Host 'No AWS profiles found. Create one with: aws configure sso'
    $global:LASTEXITCODE = 1; return
  }

  if ($listOnly) { Write-Output $profiles; $global:LASTEXITCODE = 0; return }

  # ---------- choose profile if not provided ----------
  if (-not $prof) {
    $prof = _awsp_pick $profiles $quiet
    if (-not $prof) { $global:LASTEXITCODE = 1; return }
  }

  # ---------- set env (avoid static creds override) ----------
  _awsp_unset $quiet
  $env:AWS_SDK_LOAD_CONFIG = '1'
  $env:AWS_PROFILE = $prof
  $env:AWS_DEFAULT_PROFILE = $prof
  if (-not $quiet) { Write-Host "-> Switched to $prof" }

  # Disable static credentials in the credentials file to prevent conflicts with SSO
  _awsp_disable_static_creds $prof $quiet

  # Save profile for auto-load in future shells (silent)
  try {
    $stateDir = _awsp_state_dir
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $stateDir 'current_profile'), "$prof`n")
  } catch { Write-Verbose "awsp: could not save the current profile: $_" }

  # ---------- verify / login logic ----------
  if ($hasAws) {
    if ($forceLogin) {
      if (-not $quiet) { Write-Host "Authenticating SSO for $prof..." }
      if (-not (_awsp_aws_quiet @('sso', 'login', '--profile', $prof))) {
        Write-Host 'SSO login failed.'; $global:LASTEXITCODE = 1; return
      }
    }
    if ($verify -ne 'off') {
      if (-not (_awsp_aws_quiet @('sts', 'get-caller-identity'))) {
        if (-not $quiet) { Write-Host "Authenticating SSO for $prof..." }
        if (-not (_awsp_aws_quiet @('sso', 'login', '--profile', $prof))) {
          Write-Host 'SSO login failed.'; $global:LASTEXITCODE = 1; return
        }
      }
      $global:LASTEXITCODE = 0
      & aws sts get-caller-identity --output $outfmt
      return
    }
  } else {
    if (-not $quiet) { Write-Host 'Note: aws CLI not found in PATH; env switched but cannot verify.' }
  }
  $global:LASTEXITCODE = 0
}

# Restore the profile saved by the last `awsp <profile>` (silent).
_awsp_autoload

# Tab completion: next to the script (installed layout) or in ../completions (repo layout).
if ($PSCommandPath) {
  $_awspDir = Split-Path -Parent $PSCommandPath
  foreach ($_awspCand in (Join-Path (Join-Path $_awspDir 'completions') 'awsp.completion.ps1'),
                         (Join-Path (Join-Path (Split-Path -Parent $_awspDir) 'completions') 'awsp.completion.ps1')) {
    if (Test-Path -LiteralPath $_awspCand -PathType Leaf) { . $_awspCand; break }
  }
  Remove-Variable _awspDir, _awspCand -ErrorAction SilentlyContinue
}
