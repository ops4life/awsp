# Native Windows (PowerShell) Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a native PowerShell port of `awsp` with a one-line installer, a Chocolatey package and a winget package.

**Architecture:** `bin/awsp.ps1` defines an `awsp` function (dot-sourced into the user's session) that mirrors `bin/awsp.sh` flag-for-flag. `bin/awsp-profile.ps1` is a small shared helper that adds/removes the dot-source line in PowerShell profile files; the script installer, the Inno Setup installer (winget) and the Chocolatey package all call it. The Linux/macOS code is untouched.

**Tech Stack:** Windows PowerShell 5.1 + PowerShell 7 (no `??`, `?:`, `&&`), Pester 5, PSScriptAnalyzer, Inno Setup 6, Chocolatey (`choco pack`), `wingetcreate`, GitHub Actions (`windows-latest`).

**Spec:** `docs/superpowers/specs/2026-10-09-windows-support-design.md`

## Global Constraints

- Works on Windows PowerShell 5.1 and PowerShell 7+. Syntax limited to what 5.1 parses (no `??`, `?:`, `&&`/`||`, ternaries, `-Parallel`).
- `.ps1` files are **ASCII only** (5.1 reads BOM-less files as ANSI). Use `->` instead of `→`.
- Same flags as `awsp.sh`: `-h --help`, `-V --version`, `-l --list`, `-c --current`, `-u --unset`, `-U --upgrade`, `-a --add`, `-r --remove`, `-m --modify`, `-L --login`, `-v --verify`, `--no-verify`, `--json`, `-q --quiet`, `--`; parsed by hand from `$args` (no named parameters). Flag matching is **case-sensitive** (`-V` != `-v`).
- Exit codes: unknown option / extra profile = 2; every other failure = 1; success = 0. Set via `$global:LASTEXITCODE`.
- Profile names are compared case-sensitively and literally (never as regex).
- Never name a variable `$profile` (collides with `$PROFILE`); use `$prof`.
- State dir `%USERPROFILE%\.config\awsp` (same relative path as POSIX); `current_profile` lives there.
- Home dir is `$env:USERPROFILE`, falling back to `$HOME`. Tests isolate it by setting `$env:USERPROFILE`.
- Commits: Conventional Commits, **no AI attribution lines** (user rule overrides any reminder). Never commit to `main`; one feature branch per phase. Do not push or open PRs without asking the user.
- Packages install files only; the user's session must source them (matches Homebrew/deb). Nothing is published to Chocolatey/winget by the agent.
- Not ported (intentional): the Bash/Zsh `precmd` hook that re-unsets static credentials each prompt (PowerShell has no equivalent without wrapping `prompt`, which conflicts with oh-my-posh/starship). Auto-load of the saved profile at startup IS ported.

## Review Focus

- `~/.aws` missing entirely, or `%USERPROFILE%` containing spaces: no exceptions; "No AWS profiles found" and exit 1 (tests run under a home dir with a space in its name).
- `config` / `credentials` saved with UTF-8 BOM and CRLF line endings (Windows editors do this): profiles still detected, SSO detection and static-credential commenting still work.
- Profile names containing spaces or regex metacharacters (`my dev`, `dev.1`): switching works, and removing `dev.1` must not remove `devX1`.
- Picker input that is empty, `0`, out of range, non-numeric or absurdly long (`99999999999999999999`): "No selection." and exit 1, never an exception.
- Saved `current_profile` that is empty, whitespace-only or has CRLF: ignored or trimmed on auto-load, never sets `AWS_PROFILE` to whitespace.

---

## Phase 1 - `awsp.ps1` (branch `feature/windows-powershell-port`)

Local test command (no PowerShell on this Linux box; use Docker). Reused by every task as **TEST**:

```bash
docker run --rm -v /opt/awsp:/repo -w /repo mcr.microsoft.com/powershell:latest pwsh -NoProfile -Command "Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser -SkipPublisherCheck; \$c = New-PesterConfiguration; \$c.Run.Path = './tests'; \$c.Run.Exit = \$true; \$c.Output.Verbosity = 'Detailed'; Invoke-Pester -Configuration \$c"
```

(First run downloads the image and Pester; later runs are quick. CI additionally runs Windows PowerShell 5.1, which Docker cannot.)

### Task 1: Branch, harness, core flags, upgrade hint

**Files:**
- Create: `bin/awsp.ps1`
- Create: `tests/awsp.Tests.ps1`
- Create: `tests/fixtures/mock-aws.ps1`
- Create: `tests/fixtures/test-helpers.ps1`

**Interfaces:**
- Produces (`bin/awsp.ps1`): globals `$AWSP_VERSION`, `$_AWSP_SCRIPT`; functions `_awsp_home`, `_awsp_state_dir`, `_awsp_err([string])`, `_awsp_read([string])`, `_awsp_usage`, `_awsp_unset([bool]$quiet)`, `_awsp_upgrade`, `awsp`. Inside `awsp`, locals `$listOnly $showCurrent $forceLogin $unsetOnly $upgrade $addProfile $removeProfile $modifyProfile $verify $quiet $outfmt $prof`.
- Produces (fixtures): `aws` mock function; `Set-AwspInput([string[]])`; `_awsp_read` override that dequeues; `Write-ConfigProfile -Name [-Sso]`; `Write-CredsProfile -Name`.

- [ ] **Step 1: Create the feature branch and commit the spec and plan**

```bash
cd /opt/awsp && git checkout -b feature/windows-powershell-port \
  && git add docs/superpowers && git commit -m "docs: add Windows PowerShell support spec and plan"
```

- [ ] **Step 2: Write the fixtures**

`tests/fixtures/mock-aws.ps1`:

```powershell
# Mock AWS CLI for Pester tests (a function, so it shadows any real aws on PATH).
#
# Controlled via env vars:
#   MOCK_AWS_LOG               - if set, append every invocation to this file
#   MOCK_AWS_PROFILES          - newline-separated profiles for "configure list-profiles"
#   MOCK_AWS_STS_FAIL          - "1" makes "sts get-caller-identity" fail until "sso login" ran
#   MOCK_AWS_SSO_LOGIN_EXIT    - exit code for "sso login" (default 0)
#   MOCK_AWS_CONFIGURE_EXIT    - exit code for "configure sso" / "configure" (default 0)

function aws {
  $a = @($args | ForEach-Object { [string]$_ })
  if ($env:MOCK_AWS_LOG) { Add-Content -LiteralPath $env:MOCK_AWS_LOG -Value ($a -join ' ') }
  $global:LASTEXITCODE = 0
  $userHome = $env:USERPROFILE
  $awsDir = Join-Path $userHome '.aws'

  $p = ''
  for ($i = 0; $i -lt $a.Count - 1; $i++) { if ($a[$i] -eq '--profile') { $p = $a[$i + 1] } }

  switch ($a[0]) {
    'configure' {
      if ($a[1] -eq 'list-profiles') {
        if ($env:MOCK_AWS_PROFILES) { $env:MOCK_AWS_PROFILES -split "`n" }
        return
      }
      New-Item -ItemType Directory -Force -Path $awsDir | Out-Null
      if ($a[1] -eq 'sso') {
        Add-Content -LiteralPath (Join-Path $awsDir 'config') -Value @(
          "[profile $p]",
          'sso_start_url = https://example.awsapps.com/start',
          'sso_region = us-east-1',
          'sso_account_id = 123456789012',
          'sso_role_name = Admin')
      } else {
        Add-Content -LiteralPath (Join-Path $awsDir 'credentials') -Value @(
          "[$p]", 'aws_access_key_id = AKIAFAKE', 'aws_secret_access_key = fakesecret')
      }
      if ($env:MOCK_AWS_CONFIGURE_EXIT) { $global:LASTEXITCODE = [int]$env:MOCK_AWS_CONFIGURE_EXIT }
      return
    }
    'sts' {
      if ($env:MOCK_AWS_STS_FAIL -eq '1' -and -not (Test-Path -LiteralPath (Join-Path $userHome '.mock-sso-logged-in'))) {
        $global:LASTEXITCODE = 1
        return
      }
      if ($a -contains 'json') { '{"Account":"123456789012"}' } else { '||  Account  ||' }
      return
    }
    'sso' {
      $code = 0
      if ($env:MOCK_AWS_SSO_LOGIN_EXIT) { $code = [int]$env:MOCK_AWS_SSO_LOGIN_EXIT }
      if ($code -eq 0) { New-Item -ItemType File -Force -Path (Join-Path $userHome '.mock-sso-logged-in') | Out-Null }
      $global:LASTEXITCODE = $code
      return
    }
  }
}
```

`tests/fixtures/test-helpers.ps1` (dot-sourced AFTER `bin/awsp.ps1` so its `_awsp_read` replaces the real one):

```powershell
# Feeds scripted answers to awsp's interactive prompts.
function Set-AwspInput {
  param([string[]]$Lines)
  $global:AwspTestInputs = New-Object System.Collections.Queue
  foreach ($l in $Lines) { $global:AwspTestInputs.Enqueue($l) }
}

function _awsp_read {
  param([string]$prompt)
  if ($global:AwspTestInputs -and $global:AwspTestInputs.Count -gt 0) { return $global:AwspTestInputs.Dequeue() }
  return ''
}

function Write-ConfigProfile {
  param([string]$Name, [switch]$Sso)
  $lines = @("[profile $Name]")
  if ($Sso) {
    $lines += 'sso_start_url = https://example.awsapps.com/start', 'sso_region = us-east-1',
      'sso_account_id = 123456789012', 'sso_role_name = Admin'
  } else {
    $lines += 'region = us-east-1'
  }
  Add-Content -LiteralPath (Join-Path (Join-Path $env:USERPROFILE '.aws') 'config') -Value $lines
}

function Write-CredsProfile {
  param([string]$Name)
  Add-Content -LiteralPath (Join-Path (Join-Path $env:USERPROFILE '.aws') 'credentials') `
    -Value @("[$Name]", 'aws_access_key_id = AKIAFAKE', 'aws_secret_access_key = fakesecret')
}
```

- [ ] **Step 3: Write the failing tests**

`tests/awsp.Tests.ps1`:

```powershell
BeforeAll {
  $script:Repo = Split-Path -Parent $PSScriptRoot
  $script:AwspPs1 = Join-Path $script:Repo 'bin/awsp.ps1'
  $script:MockAws = Join-Path $PSScriptRoot 'fixtures/mock-aws.ps1'
  $script:Helpers = Join-Path $PSScriptRoot 'fixtures/test-helpers.ps1'
}

BeforeEach {
  $script:OrigPath = $env:PATH
  $script:OrigUserProfile = $env:USERPROFILE
  # A space in the path catches unquoted-path bugs.
  $script:TestHome = Join-Path ([System.IO.Path]::GetTempPath()) ('awsp test ' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path (Join-Path $script:TestHome '.aws') | Out-Null
  $env:USERPROFILE = $script:TestHome
  $env:MOCK_AWS_LOG = Join-Path $script:TestHome 'aws-calls.log'
  foreach ($v in 'MOCK_AWS_PROFILES', 'MOCK_AWS_STS_FAIL', 'MOCK_AWS_SSO_LOGIN_EXIT', 'MOCK_AWS_CONFIGURE_EXIT',
                 'AWS_PROFILE', 'AWS_DEFAULT_PROFILE', 'AWS_SDK_LOAD_CONFIG',
                 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN') {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
  }
  . $script:MockAws
  . $script:AwspPs1
  . $script:Helpers
}

AfterEach {
  $env:PATH = $script:OrigPath
  $env:USERPROFILE = $script:OrigUserProfile
  Remove-Item -LiteralPath $script:TestHome -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'basic flags' {
  It '--version prints the version' {
    $out = awsp --version *>&1 | Out-String
    $LASTEXITCODE | Should -Be 0
    $out | Should -Match 'awsp version \d+\.\d+\.\d+'
  }

  It '-V and -v are different flags (case-sensitive)' {
    $out = awsp -V *>&1 | Out-String
    $out | Should -Match 'awsp version'
  }

  It '--help prints usage including the --add flag' {
    $out = awsp --help *>&1 | Out-String
    $LASTEXITCODE | Should -Be 0
    $out | Should -Match '-a, --add'
  }

  It 'unknown option returns exit code 2' {
    awsp --bogus *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 2
  }

  It 'more than one positional profile is rejected' {
    $out = awsp foo bar *>&1 | Out-String
    $LASTEXITCODE | Should -Be 2
    $out | Should -Match 'only one PROFILE allowed'
  }

  It 'arguments after -- are treated as the profile name' {
    $out = awsp -- --weird *>&1 | Out-String
    $out | Should -Not -Match 'unknown option'
  }
}

Describe '--current and --unset' {
  It '--current reports no profile set initially' {
    $out = awsp --current *>&1 | Out-String
    $LASTEXITCODE | Should -Be 0
    $out | Should -Match 'no AWS_PROFILE set'
  }

  It '--current prints the active profile' {
    $env:AWS_PROFILE = 'dev'
    (awsp --current *>&1 | Out-String).Trim() | Should -Be 'dev'
  }

  It '--unset clears env vars and removes the persisted profile' {
    $state = Join-Path (Join-Path $env:USERPROFILE '.config') 'awsp'
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    Set-Content -LiteralPath (Join-Path $state 'current_profile') -Value 'dev'
    $env:AWS_PROFILE = 'dev'; $env:AWS_DEFAULT_PROFILE = 'dev'
    $env:AWS_ACCESS_KEY_ID = 'x'; $env:AWS_SECRET_ACCESS_KEY = 'y'; $env:AWS_SESSION_TOKEN = 'z'
    awsp --unset --quiet *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0
    $env:AWS_PROFILE | Should -BeNullOrEmpty
    $env:AWS_DEFAULT_PROFILE | Should -BeNullOrEmpty
    $env:AWS_ACCESS_KEY_ID | Should -BeNullOrEmpty
    $env:AWS_SESSION_TOKEN | Should -BeNullOrEmpty
    Test-Path -LiteralPath (Join-Path $state 'current_profile') | Should -BeFalse
  }
}

Describe '--upgrade' {
  It 'defers to Chocolatey for choco-installed copies' {
    $global:_AWSP_SCRIPT = Join-Path $script:TestHome 'chocolatey/lib/awsp/tools/awsp.ps1'
    $out = awsp -U *>&1 | Out-String
    $LASTEXITCODE | Should -Be 0
    $out | Should -Match 'choco upgrade awsp'
  }

  It 'defers to winget for installer-based copies' {
    $global:_AWSP_SCRIPT = Join-Path $script:TestHome 'AppData/Local/Programs/awsp/awsp.ps1'
    $out = awsp -U *>&1 | Out-String
    $out | Should -Match 'winget upgrade ops4life.awsp'
  }

  It 'tells script-install users to re-run install.ps1' {
    $global:_AWSP_SCRIPT = Join-Path $script:TestHome '.config/awsp/awsp.ps1'
    $out = awsp -U *>&1 | Out-String
    $out | Should -Match 'install\.ps1'
  }

  It 'tells git-checkout users to git pull' {
    $out = awsp -U *>&1 | Out-String   # _AWSP_SCRIPT is the repo's bin/awsp.ps1
    $out | Should -Match 'git -C'
  }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run **TEST**. Expected: FAIL (every `It` errors with "The term 'awsp' is not recognized" / dot-source of missing `bin/awsp.ps1`).

- [ ] **Step 5: Write `bin/awsp.ps1` (core)**

```powershell
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
```

- [ ] **Step 6: Run tests to verify they pass**

Run **TEST**. Expected: all `basic flags`, `--current and --unset`, `--upgrade` tests PASS.

- [ ] **Step 7: Commit**

```bash
git add bin/awsp.ps1 tests && git commit -m "feat: add PowerShell awsp core flags and test harness"
```

### Task 2: Profile discovery, list, picker, switching, verify/login

**Files:**
- Modify: `bin/awsp.ps1` (add helpers above `function awsp {`; replace the `# (profile discovery ...)` comment)
- Modify: `tests/awsp.Tests.ps1` (append)

**Interfaces:**
- Consumes: Task 1 locals and helpers.
- Produces: `_awsp_config_section_name([string]$line)` -> `[string]` or `$null`; `_awsp_list_profiles([bool]$hasAws)` -> unrolled strings (caller wraps in `@()`); `_awsp_pick([string[]]$profiles, [bool]$quiet)` -> `[string]` or `$null`; `_awsp_aws_quiet([string[]]$a)` -> `[bool]`.

- [ ] **Step 1: Append failing tests**

```powershell
Describe 'profile discovery and --list' {
  It 'uses aws configure list-profiles when the aws CLI is present' {
    $env:MOCK_AWS_PROFILES = "dev`nprod"
    $out = awsp --list *>&1 | Out-String
    $LASTEXITCODE | Should -Be 0
    $out | Should -Match 'dev'
    $out | Should -Match 'prod'
  }

  It 'falls back to parsing config/credentials without the aws CLI' {
    Remove-Item Function:\aws
    $env:PATH = Join-Path $script:TestHome 'empty'
    Write-ConfigProfile -Name 'dev'
    Write-CredsProfile -Name 'legacy'
    $out = awsp --list *>&1 | Out-String
    $LASTEXITCODE | Should -Be 0
    $out | Should -Match 'dev'
    $out | Should -Match 'legacy'
  }

  It 'reports no profiles (exit 1) when ~/.aws does not exist at all' {
    Remove-Item -LiteralPath (Join-Path $script:TestHome '.aws') -Recurse -Force
    $out = awsp --list *>&1 | Out-String
    $LASTEXITCODE | Should -Be 1
    $out | Should -Match 'No AWS profiles found'
  }

  It 'reports no profiles when nothing is configured' {
    $out = awsp --list *>&1 | Out-String
    $LASTEXITCODE | Should -Be 1
    $out | Should -Match 'No AWS profiles found'
  }
}

Describe 'switching' {
  BeforeEach { $env:MOCK_AWS_PROFILES = "dev`nprod" }

  It 'sets env vars and persists the profile' {
    awsp dev --no-verify --quiet *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0
    $env:AWS_PROFILE | Should -Be 'dev'
    $env:AWS_DEFAULT_PROFILE | Should -Be 'dev'
    $env:AWS_SDK_LOAD_CONFIG | Should -Be '1'
    (Get-Content -LiteralPath (Join-Path (_awsp_state_dir) 'current_profile') -Raw).Trim() | Should -Be 'dev'
  }

  It 'clears static credentials from the environment when switching' {
    $env:AWS_ACCESS_KEY_ID = 'x'; $env:AWS_SECRET_ACCESS_KEY = 'y'
    awsp dev --no-verify --quiet *>&1 | Out-Null
    $env:AWS_ACCESS_KEY_ID | Should -BeNullOrEmpty
    $env:AWS_SECRET_ACCESS_KEY | Should -BeNullOrEmpty
  }

  It 'handles profile names with spaces and dots' {
    $env:MOCK_AWS_PROFILES = "my dev`ndev.1"
    awsp 'my dev' --no-verify --quiet *>&1 | Out-Null
    $env:AWS_PROFILE | Should -Be 'my dev'
    awsp 'dev.1' --no-verify --quiet *>&1 | Out-Null
    $env:AWS_PROFILE | Should -Be 'dev.1'
  }

  It 'numbered-list selection switches to the chosen profile' {
    Set-AwspInput '2'
    awsp --no-verify --quiet *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0
    $env:AWS_PROFILE | Should -Be 'prod'
  }

  It 'rejects bad picker input without throwing' {
    foreach ($bad in '', '0', '3', 'abc', '99999999999999999999', '-1') {
      Set-AwspInput $bad
      $out = awsp --no-verify --quiet *>&1 | Out-String
      $LASTEXITCODE | Should -Be 1
      $out | Should -Match 'No selection'
      $env:AWS_PROFILE | Should -BeNullOrEmpty
    }
  }
}

Describe 'verify / login flow' {
  BeforeEach { $env:MOCK_AWS_PROFILES = 'dev' }

  It '--no-verify skips STS verification' {
    $env:MOCK_AWS_STS_FAIL = '1'
    awsp dev --no-verify --quiet *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0
    (Get-Content -LiteralPath $env:MOCK_AWS_LOG -ErrorAction SilentlyContinue) -match '^sts ' | Should -BeNullOrEmpty
  }

  It 'auto-logs in via SSO when the STS identity check fails' {
    $env:MOCK_AWS_STS_FAIL = '1'
    awsp dev --quiet *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0
    (Get-Content -LiteralPath $env:MOCK_AWS_LOG) -match '^sso login' | Should -Not -BeNullOrEmpty
  }

  It 'fails with exit 1 when SSO login fails' {
    $env:MOCK_AWS_STS_FAIL = '1'; $env:MOCK_AWS_SSO_LOGIN_EXIT = '1'
    $out = awsp dev --quiet *>&1 | Out-String
    $LASTEXITCODE | Should -Be 1
    $out | Should -Match 'SSO login failed'
  }

  It '--login forces aws sso login' {
    awsp dev --login --no-verify --quiet *>&1 | Out-Null
    (Get-Content -LiteralPath $env:MOCK_AWS_LOG) -match '^sso login --profile dev$' | Should -Not -BeNullOrEmpty
  }

  It '--json outputs the STS identity as JSON' {
    $out = awsp dev --quiet --json *>&1 | Out-String
    $LASTEXITCODE | Should -Be 0
    $out | Should -Match '"Account"'
  }

  It 'notes that verification is impossible without the aws CLI' {
    Remove-Item Function:\aws
    $env:PATH = Join-Path $script:TestHome 'empty'
    Write-ConfigProfile -Name 'dev'
    $out = awsp dev *>&1 | Out-String
    $env:AWS_PROFILE | Should -Be 'dev'
    $out | Should -Match 'aws CLI not found'
  }
}
```

- [ ] **Step 2: Run tests, verify the new ones fail**

Run **TEST**. Expected: the new `Describe` blocks FAIL (e.g. `--list` prints nothing, exit code stale).

- [ ] **Step 3: Insert helpers above `function awsp {`**

Use Edit on the line `function awsp {` (unique), prefixing it with:

```powershell
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
  if (-not [long]::TryParse([string]$choice, [ref]$n) -or ([string]$choice) -notmatch '^\d+$' -or $n -lt 1 -or $n -gt $profiles.Count) {
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

```

- [ ] **Step 4: Replace the `# (profile discovery and switching are added in Task 2)` line**

```powershell
  # ---------- collect profiles ----------
  $hasAws = [bool](Get-Command aws -ErrorAction SilentlyContinue)
  $profiles = @(_awsp_list_profiles $hasAws)
  $count = $profiles.Count

  # (add/remove/modify are added in Task 4)

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

  # Save profile for auto-load in future shells (silent)
  try {
    $stateDir = _awsp_state_dir
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $stateDir 'current_profile'), "$prof`n")
  } catch { }

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
```

- [ ] **Step 5: Run tests, verify all pass**

Run **TEST**. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/awsp.ps1 tests && git commit -m "feat: add PowerShell profile discovery, switching and SSO verify"
```

### Task 3: SSO detection, static-credential disabling, auto-load

**Files:**
- Modify: `bin/awsp.ps1`
- Modify: `tests/awsp.Tests.ps1` (append)

**Interfaces:**
- Consumes: `_awsp_config_section_name`, `_awsp_home`, `_awsp_state_dir`.
- Produces: `_awsp_is_sso_profile([string]$name)` -> `[bool]`; `_awsp_disable_static_creds([string]$name, [bool]$quiet = $true)`; `_awsp_autoload` (called once at dot-source).

- [ ] **Step 1: Append failing tests**

```powershell
Describe 'SSO detection and static credentials' {
  It '_awsp_is_sso_profile detects an SSO profile' {
    Write-ConfigProfile -Name 'dev' -Sso
    _awsp_is_sso_profile 'dev' | Should -BeTrue
  }

  It '_awsp_is_sso_profile rejects a non-SSO profile' {
    Write-ConfigProfile -Name 'dev'
    _awsp_is_sso_profile 'dev' | Should -BeFalse
  }

  It '_awsp_is_sso_profile is false when ~/.aws/config is missing' {
    _awsp_is_sso_profile 'dev' | Should -BeFalse
  }

  It 'works on config files with a UTF-8 BOM and CRLF line endings' {
    $cfg = Join-Path (Join-Path $env:USERPROFILE '.aws') 'config'
    $text = "[profile dev]`r`nsso_start_url = https://x`r`nsso_region = us-east-1`r`n"
    [System.IO.File]::WriteAllText($cfg, $text, (New-Object System.Text.UTF8Encoding $true))
    _awsp_is_sso_profile 'dev' | Should -BeTrue
    $env:MOCK_AWS_PROFILES = ''
    Remove-Item Function:\aws
    $env:PATH = Join-Path $script:TestHome 'empty'
    (awsp --list *>&1 | Out-String) | Should -Match 'dev'
  }

  It 'comments out static creds for SSO profiles and keeps a backup' {
    Write-ConfigProfile -Name 'dev' -Sso
    Write-CredsProfile -Name 'dev'
    Write-CredsProfile -Name 'other'
    _awsp_disable_static_creds 'dev' $true
    $creds = Get-Content -LiteralPath (Join-Path (Join-Path $env:USERPROFILE '.aws') 'credentials')
    $creds | Should -Contain '# aws_access_key_id = AKIAFAKE'
    ($creds | Where-Object { $_ -eq 'aws_access_key_id = AKIAFAKE' }).Count | Should -Be 1   # [other] untouched
    @(Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.aws') -Filter 'credentials.backup.*').Count | Should -Be 1
  }

  It 'leaves credentials alone for non-SSO profiles' {
    Write-ConfigProfile -Name 'dev'
    Write-CredsProfile -Name 'dev'
    _awsp_disable_static_creds 'dev' $true
    (Get-Content -LiteralPath (Join-Path (Join-Path $env:USERPROFILE '.aws') 'credentials')) | Should -Contain 'aws_access_key_id = AKIAFAKE'
  }

  It 'switching to an SSO profile disables its static creds' {
    $env:MOCK_AWS_PROFILES = 'dev'
    Write-ConfigProfile -Name 'dev' -Sso
    Write-CredsProfile -Name 'dev'
    $out = awsp dev --no-verify *>&1 | Out-String
    $out | Should -Match 'Disabled static credentials'
    (Get-Content -LiteralPath (Join-Path (Join-Path $env:USERPROFILE '.aws') 'credentials')) | Should -Contain '# aws_access_key_id = AKIAFAKE'
  }
}

Describe 'auto-load' {
  BeforeEach {
    $script:StateDir = Join-Path (Join-Path $env:USERPROFILE '.config') 'awsp'
    New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
  }

  It 'restores a previously saved profile at startup' {
    Set-Content -LiteralPath (Join-Path $script:StateDir 'current_profile') -Value 'dev'
    . $script:AwspPs1
    $env:AWS_PROFILE | Should -Be 'dev'
    $env:AWS_DEFAULT_PROFILE | Should -Be 'dev'
  }

  It 'trims CRLF in the saved file' {
    [System.IO.File]::WriteAllText((Join-Path $script:StateDir 'current_profile'), "dev`r`n")
    . $script:AwspPs1
    $env:AWS_PROFILE | Should -Be 'dev'
  }

  It 'ignores empty or whitespace-only saved files' {
    foreach ($content in '', '   ', "`r`n") {
      [System.IO.File]::WriteAllText((Join-Path $script:StateDir 'current_profile'), $content)
      . $script:AwspPs1
      $env:AWS_PROFILE | Should -BeNullOrEmpty
    }
  }

  It 'does not override an already-set AWS_PROFILE' {
    Set-Content -LiteralPath (Join-Path $script:StateDir 'current_profile') -Value 'dev'
    $env:AWS_PROFILE = 'prod'
    . $script:AwspPs1
    $env:AWS_PROFILE | Should -Be 'prod'
  }
}
```

- [ ] **Step 2: Run tests, verify failures**

Run **TEST**. Expected: new tests FAIL (`_awsp_is_sso_profile` not recognized).

- [ ] **Step 3: Insert helpers above `function awsp {` (below `_awsp_aws_quiet`)**

```powershell
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

```

- [ ] **Step 4: Wire it into switching and startup**

Edit: after the line `  if (-not $quiet) { Write-Host "-> Switched to $prof" }` add

```powershell

  # Disable static credentials in the credentials file to prevent conflicts with SSO
  _awsp_disable_static_creds $prof $quiet
```

Append to the very end of `bin/awsp.ps1` (after the closing `}` of `awsp`):

```powershell

# Restore the profile saved by the last `awsp <profile>` (silent).
_awsp_autoload
```

- [ ] **Step 5: Run tests, verify all pass**

Run **TEST**. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/awsp.ps1 tests && git commit -m "feat: add PowerShell SSO detection, static-credential guard and auto-load"
```

### Task 4: `--add`, `--remove`, `--modify`

**Files:**
- Modify: `bin/awsp.ps1`
- Modify: `tests/awsp.Tests.ps1` (append)

**Interfaces:**
- Consumes: `_awsp_pick`, `_awsp_read`, `_awsp_is_sso_profile`, `_awsp_unset`, `_awsp_config_section_name`.
- Produces: `_awsp_remove_section([string]$path, [string]$name, [bool]$isConfig)` (backs up then rewrites; no-op if file missing).

- [ ] **Step 1: Append failing tests** (mirror `awsp.bats` add tests, plus remove/modify)

```powershell
Describe '--add' {
  It 'requires the aws CLI' {
    Remove-Item Function:\aws
    $env:PATH = Join-Path $script:TestHome 'empty'
    $out = awsp --add *>&1 | Out-String
    $LASTEXITCODE | Should -Be 1
    $out | Should -Match 'aws CLI is required'
  }

  It 're-prompts on an empty profile name' {
    Set-AwspInput '', 'dev', '1', '1'
    awsp --add --no-verify --quiet *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0
    (Get-Content -LiteralPath (Join-Path (_awsp_state_dir) 'current_profile') -Raw).Trim() | Should -Be 'dev'
  }

  It 'gives up after repeated empty profile names' {
    Set-AwspInput '', '', '', '', '', ''
    $out = awsp --add --quiet *>&1 | Out-String
    $LASTEXITCODE | Should -Be 1
    $out | Should -Match 'no profile name'
  }

  It 'SSO browser option calls aws configure sso without --use-device-code' {
    Set-AwspInput 'dev', '1', '1'
    awsp --add --no-verify --quiet *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0
    (Get-Content -LiteralPath $env:MOCK_AWS_LOG) | Should -Contain 'configure sso --profile dev'
  }

  It 'SSO device-code option passes --use-device-code' {
    Set-AwspInput 'dev', '1', '2'
    awsp --add --no-verify --quiet *>&1 | Out-Null
    (Get-Content -LiteralPath $env:MOCK_AWS_LOG) | Should -Contain 'configure sso --profile dev --use-device-code'
  }

  It 'static credentials option calls aws configure' {
    Set-AwspInput 'dev', '2'
    awsp --add --no-verify --quiet *>&1 | Out-Null
    (Get-Content -LiteralPath $env:MOCK_AWS_LOG) | Should -Contain 'configure --profile dev'
    (Get-Content -LiteralPath (Join-Path (_awsp_state_dir) 'current_profile') -Raw).Trim() | Should -Be 'dev'
  }

  It 'an invalid profile-type selection fails' {
    Set-AwspInput 'dev', '9'
    $out = awsp --add --no-verify --quiet *>&1 | Out-String
    $LASTEXITCODE | Should -Be 1
    $out | Should -Match 'invalid selection'
  }

  It 'a failing aws configure aborts with exit 1' {
    $env:MOCK_AWS_CONFIGURE_EXIT = '1'
    Set-AwspInput 'dev', '2'
    awsp --add --no-verify --quiet *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 1
    $env:AWS_PROFILE | Should -BeNullOrEmpty
  }
}

Describe '--remove' {
  BeforeEach {
    Write-ConfigProfile -Name 'dev.1'
    Write-ConfigProfile -Name 'devX1'
    Write-CredsProfile -Name 'dev.1'
    Write-CredsProfile -Name 'devX1'
    $env:MOCK_AWS_PROFILES = "dev.1`ndevX1"
    $script:AwsDir = Join-Path $env:USERPROFILE '.aws'
  }

  It 'removes only the exact profile (dots are literal) and keeps backups' {
    Set-AwspInput 'y'
    awsp --remove 'dev.1' --quiet *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0
    $cfg = Get-Content -LiteralPath (Join-Path $script:AwsDir 'config')
    $cfg | Should -Not -Contain '[profile dev.1]'
    $cfg | Should -Contain '[profile devX1]'
    $cred = Get-Content -LiteralPath (Join-Path $script:AwsDir 'credentials')
    $cred | Should -Not -Contain '[dev.1]'
    $cred | Should -Contain '[devX1]'
    @(Get-ChildItem -LiteralPath $script:AwsDir -Filter 'config.backup.*').Count | Should -Be 1
  }

  It 'cancels unless the answer is yes' {
    Set-AwspInput 'n'
    $out = awsp --remove 'dev.1' *>&1 | Out-String
    $LASTEXITCODE | Should -Be 1
    $out | Should -Match 'Removal cancelled'
    (Get-Content -LiteralPath (Join-Path $script:AwsDir 'config')) | Should -Contain '[profile dev.1]'
  }

  It 'prompts with the picker when no profile is given' {
    Set-AwspInput '2', 'y'
    awsp --remove --quiet *>&1 | Out-Null
    (Get-Content -LiteralPath (Join-Path $script:AwsDir 'config')) | Should -Not -Contain '[profile devX1]'
  }

  It 'unsets the environment when the active profile is removed' {
    $env:AWS_PROFILE = 'dev.1'
    Set-AwspInput 'y'
    awsp --remove 'dev.1' --quiet *>&1 | Out-Null
    $env:AWS_PROFILE | Should -BeNullOrEmpty
  }

  It 'works on CRLF + BOM files' {
    $cfg = Join-Path $script:AwsDir 'config'
    [System.IO.File]::WriteAllText($cfg, "[profile a]`r`nregion = x`r`n[profile b]`r`nregion = y`r`n", (New-Object System.Text.UTF8Encoding $true))
    Set-AwspInput 'y'
    awsp --remove 'a' --quiet *>&1 | Out-Null
    $left = Get-Content -LiteralPath $cfg
    $left | Should -Not -Contain '[profile a]'
    $left | Should -Contain '[profile b]'
  }
}

Describe '--modify' {
  BeforeEach { $env:MOCK_AWS_PROFILES = 'dev' }

  It 'requires the aws CLI' {
    Remove-Item Function:\aws
    $env:PATH = Join-Path $script:TestHome 'empty'
    awsp --modify dev *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 1
  }

  It 'reconfigures an SSO profile with aws configure sso' {
    Write-ConfigProfile -Name 'dev' -Sso
    Set-AwspInput '1'
    awsp --modify dev *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0
    (Get-Content -LiteralPath $env:MOCK_AWS_LOG) | Should -Contain 'configure sso --profile dev'
  }

  It 'reconfigures a static profile with aws configure' {
    Write-ConfigProfile -Name 'dev'
    awsp --modify dev *>&1 | Out-Null
    (Get-Content -LiteralPath $env:MOCK_AWS_LOG) | Should -Contain 'configure --profile dev'
  }
}
```

- [ ] **Step 2: Run tests, verify failures**

Run **TEST**. Expected: new tests FAIL (flags parsed but no behavior; e.g. `--add` falls through to the picker).

- [ ] **Step 3: Insert `_awsp_remove_section` above `function awsp {`**

```powershell
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
  } catch { }
}

```

- [ ] **Step 4: Replace the `# (add/remove/modify are added in Task 4)` line**

```powershell
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
```

- [ ] **Step 5: Run tests, verify all pass**

Run **TEST**. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/awsp.ps1 tests && git commit -m "feat: add PowerShell profile add, remove and modify"
```

### Task 5: Completion, parity tests, lint and CI

**Files:**
- Create: `completions/awsp.completion.ps1`
- Modify: `bin/awsp.ps1` (load completion at end)
- Modify: `tests/awsp.Tests.ps1` (append)
- Modify: `.github/workflows/test.yaml` (add jobs)
- Modify: `.releaserc.json` (bump version in `bin/awsp.ps1`)

**Interfaces:**
- Produces: `_awsp_complete_words([string]$word)` -> `CompletionResult[]`; completers registered for `awsp`.

- [ ] **Step 1: Append failing tests**

```powershell
Describe 'completion' {
  It 'completes long flags' {
    $r = @(_awsp_complete_words '--j')
    $r.Count | Should -Be 1
    $r[0].CompletionText | Should -Be '--json'
  }

  It 'completes every flag when given a bare dash' {
    @(_awsp_complete_words '-').Count | Should -BeGreaterThan 15
  }

  It 'completes profile names' {
    $env:MOCK_AWS_PROFILES = "dev`nprod`nprod-eu"
    $names = @(_awsp_complete_words 'pro' | ForEach-Object CompletionText)
    $names | Should -Be @('prod', 'prod-eu')
  }

  It 'quotes profile names containing spaces' {
    $env:MOCK_AWS_PROFILES = 'my dev'
    @(_awsp_complete_words 'my')[0].CompletionText | Should -Be "'my dev'"
  }
}

Describe 'parity with awsp.sh' {
  It 'has the same version' {
    $sh = [regex]::Match((Get-Content -Raw (Join-Path $script:Repo 'bin/awsp.sh')), '(?m)^AWSP_VERSION="([^"]+)"').Groups[1].Value
    $global:AWSP_VERSION | Should -Be $sh
  }

  It 'documents the same flags' {
    $text = Get-Content -Raw (Join-Path $script:Repo 'bin/awsp.sh')
    $usage = [regex]::Match($text, "(?s)<<'USG'\r?\n(.*?)\r?\nUSG").Groups[1].Value
    $shFlags = [regex]::Matches($usage, '(?<![\w-])-{1,2}[A-Za-z][\w-]*') | ForEach-Object Value | Sort-Object -Unique
    $psHelp = awsp --help *>&1 | Out-String
    $psFlags = [regex]::Matches($psHelp, '(?<![\w-])-{1,2}[A-Za-z][\w-]*') | ForEach-Object Value | Sort-Object -Unique
    ($psFlags -join ',') | Should -Be ($shFlags -join ',')
  }
}
```

Note: the flag regex also matches words like `-pre`; the usage text contains none. If the comparison is noisy because of prose, restrict both sides to lines matching `^\s+-` (option lines).

- [ ] **Step 2: Run tests, verify failures**

Run **TEST**. Expected: completion tests FAIL (`_awsp_complete_words` missing); parity tests PASS or FAIL on real drift (fix usage text if so).

- [ ] **Step 3: Create `completions/awsp.completion.ps1`**

```powershell
# PowerShell tab completion for awsp: flags and profile names.
# Loaded by awsp.ps1; safe to dot-source on its own after awsp.ps1.

$script:_AwspFlags = @(
  '-h', '--help', '-V', '--version', '-l', '--list', '-c', '--current', '-u', '--unset',
  '-U', '--upgrade', '-a', '--add', '-r', '--remove', '-m', '--modify', '-L', '--login',
  '-v', '--verify', '--no-verify', '--json', '-q', '--quiet'
)

function _awsp_complete_words([string]$word) {
  $candidates = @()
  if ($word -like '-*') {
    $candidates = $script:_AwspFlags | Where-Object { $_ -clike "$word*" }
  } elseif (Get-Command _awsp_list_profiles -ErrorAction SilentlyContinue) {
    $hasAws = [bool](Get-Command aws -ErrorAction SilentlyContinue)
    $candidates = @(_awsp_list_profiles $hasAws) | Where-Object { $_ -like "$word*" }
  }
  foreach ($c in $candidates) {
    $text = $c
    if ($c -match '\s') { $text = "'" + ($c -replace "'", "''") + "'" }
    [System.Management.Automation.CompletionResult]::new($text, $c, 'ParameterValue', $c)
  }
}

# Native-style completer (works for argument positions of plain functions) ...
Register-ArgumentCompleter -Native -CommandName awsp -ScriptBlock {
  param($wordToComplete, $commandAst, $cursorPosition)
  _awsp_complete_words $wordToComplete
}
# ... and the regular one.
Register-ArgumentCompleter -CommandName awsp -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)
  _awsp_complete_words $wordToComplete
}
```

- [ ] **Step 4: Load it from `bin/awsp.ps1`** (append at the very end, after `_awsp_autoload`)

```powershell

# Tab completion: next to the script (installed layout) or in ../completions (repo layout).
if ($PSCommandPath) {
  $_awspDir = Split-Path -Parent $PSCommandPath
  foreach ($_awspCand in (Join-Path (Join-Path $_awspDir 'completions') 'awsp.completion.ps1'),
                         (Join-Path (Join-Path (Split-Path -Parent $_awspDir) 'completions') 'awsp.completion.ps1')) {
    if (Test-Path -LiteralPath $_awspCand -PathType Leaf) { . $_awspCand; break }
  }
  Remove-Variable _awspDir, _awspCand -ErrorAction SilentlyContinue
}
```

- [ ] **Step 5: Run tests, verify all pass**

Run **TEST**. Expected: PASS.

- [ ] **Step 6: Wire version bumping for the new file**

Edit `.releaserc.json`: replace the `prepareCmd` value with

```json
"prepareCmd": "sed -i.bak 's/^AWSP_VERSION=\".*\"/AWSP_VERSION=\"${nextRelease.version}\"/' bin/awsp.sh && rm bin/awsp.sh.bak && sed -i.bak 's/^$global:AWSP_VERSION = \".*\"/$global:AWSP_VERSION = \"${nextRelease.version}\"/' bin/awsp.ps1 && rm bin/awsp.ps1.bak"
```

and add `"bin/awsp.ps1"` to the `@semantic-release/git` `assets` array.

Verify the sed (note the file may have CRLF after checkout on Windows; this runs on ubuntu so LF):

```bash
cp bin/awsp.ps1 /tmp/claude-1000/-opt-awsp/c91b026f-c161-4312-983c-d46087aedc97/scratchpad/awsp.ps1.copy \
 && sed -i.bak 's/^$global:AWSP_VERSION = ".*"/$global:AWSP_VERSION = "9.9.9"/' /tmp/claude-1000/-opt-awsp/c91b026f-c161-4312-983c-d46087aedc97/scratchpad/awsp.ps1.copy \
 && grep -n 'AWSP_VERSION = ' /tmp/claude-1000/-opt-awsp/c91b026f-c161-4312-983c-d46087aedc97/scratchpad/awsp.ps1.copy | head -2
python3 -c "import json;json.load(open('.releaserc.json'))" && echo json-ok
```

Expected: `$global:AWSP_VERSION = "9.9.9"` and `json-ok`. (If the file has CRLF the `.*"` still matches; the CRLF is outside the quotes.)

- [ ] **Step 7: Add the Windows CI jobs**

Append to `jobs:` in `.github/workflows/test.yaml`:

```yaml
  pester:
    name: pester (${{ matrix.shell }})
    runs-on: windows-latest
    strategy:
      fail-fast: false
      matrix:
        shell: [pwsh, powershell]
    defaults:
      run:
        shell: ${{ matrix.shell }}
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v7

      - name: Install Pester
        run: |
          Set-PSRepository PSGallery -InstallationPolicy Trusted
          Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser

      - name: Run Pester
        run: |
          Import-Module Pester -MinimumVersion 5.5.0
          $c = New-PesterConfiguration
          $c.Run.Path = './tests'
          $c.Run.Exit = $true
          $c.Output.Verbosity = 'Detailed'
          Invoke-Pester -Configuration $c

  psscriptanalyzer:
    name: psscriptanalyzer
    runs-on: windows-latest
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v7

      - name: Lint PowerShell
        shell: pwsh
        run: |
          Set-PSRepository PSGallery -InstallationPolicy Trusted
          Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
          $exclude = 'PSAvoidUsingWriteHost', 'PSUseApprovedVerbs', 'PSAvoidGlobalVars',
            'PSUseShouldProcessForStateChangingFunctions', 'PSAvoidUsingPositionalParameters',
            'PSUseSingularNouns', 'PSAvoidAssignmentToAutomaticVariable'
          $paths = 'bin/awsp.ps1', 'completions/awsp.completion.ps1'
          $paths += Get-ChildItem -Path . -Recurse -Filter '*.ps1' |
            Where-Object { $_.FullName -match 'install\.ps1$|[\\/]scripts[\\/]|[\\/]bin[\\/]awsp-profile\.ps1$' } |
            ForEach-Object FullName
          $r = Invoke-ScriptAnalyzer -Path $paths -Severity Warning, Error -ExcludeRule $exclude
          $r | Format-Table -AutoSize
          if ($r) { exit 1 }
```

- [ ] **Step 8: Lint locally and commit**

```bash
docker run --rm -v /opt/awsp:/repo -w /repo mcr.microsoft.com/powershell:latest pwsh -NoProfile -Command "Install-Module PSScriptAnalyzer -Force -Scope CurrentUser; \$r = Invoke-ScriptAnalyzer -Path bin/awsp.ps1,completions/awsp.completion.ps1 -Severity Warning,Error -ExcludeRule PSAvoidUsingWriteHost,PSUseApprovedVerbs,PSAvoidGlobalVars,PSUseShouldProcessForStateChangingFunctions,PSAvoidUsingPositionalParameters,PSUseSingularNouns,PSAvoidAssignmentToAutomaticVariable; \$r | Format-Table; if (\$r) { exit 1 }"
pre-commit run --all-files   # yamllint on test.yaml
git add bin completions tests .github .releaserc.json && git commit -m "feat: add PowerShell completion, parity tests and Windows CI"
```

Expected: analyzer prints nothing and exits 0 (fix any finding it reports rather than excluding more rules); pre-commit passes.

- [ ] **Step 9: Ask the user before pushing**

Show `git log --oneline main..HEAD`; ask whether to push `feature/windows-powershell-port` and open the PR (title `feat: add native PowerShell (Windows) support`, no AI attribution in the body). Wait for the answer. After merge: `git checkout main && git pull origin main`.

---

## Phase 2 - Installer (branch `feature/windows-install-script`, from updated `main`)

### Task 6: Profile helper `awsp-profile.ps1`

**Files:**
- Create: `bin/awsp-profile.ps1`
- Create: `tests/awsp-profile.Tests.ps1`

**Interfaces:**
- Produces: script `bin/awsp-profile.ps1 -Action Add|Remove -ScriptPath <path> [-ProfileFile <path>] [-AllUsers]`. `Add` writes (idempotently) the line
  `if (Test-Path -LiteralPath '<ScriptPath>') { . '<ScriptPath>' } # awsp` to the target profile file(s); `Remove` deletes every line ending in `# awsp`. Targets: `-ProfileFile` if given; else current-user `Documents\WindowsPowerShell\profile.ps1` and `Documents\PowerShell\profile.ps1` (the running edition's is created, the other only if its folder exists); with `-AllUsers`: `%SystemRoot%\System32\WindowsPowerShell\v1.0\profile.ps1` and `%ProgramFiles%\PowerShell\7\profile.ps1` (latter only if its folder exists).

- [ ] **Step 1: `git checkout main && git pull origin main && git checkout -b feature/windows-install-script`**

- [ ] **Step 2: Write the failing tests** (`tests/awsp-profile.Tests.ps1`)

```powershell
BeforeAll {
  $script:Hook = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/awsp-profile.ps1'
}

BeforeEach {
  $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('awsp hook ' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $script:Dir | Out-Null
  $script:Prof = Join-Path $script:Dir 'profile.ps1'
  $script:Target = Join-Path $script:Dir 'awsp.ps1'
}

AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'awsp-profile.ps1' {
  It 'creates the profile with a dot-source line' {
    & $script:Hook -Action Add -ScriptPath $script:Target -ProfileFile $script:Prof
    $text = Get-Content -LiteralPath $script:Prof -Raw
    $text | Should -Match ([regex]::Escape(". '$($script:Target)'"))
    $text | Should -Match '# awsp\s*$'
  }

  It 'is idempotent' {
    1..3 | ForEach-Object { & $script:Hook -Action Add -ScriptPath $script:Target -ProfileFile $script:Prof }
    @(Get-Content -LiteralPath $script:Prof | Where-Object { $_ -match '# awsp$' }).Count | Should -Be 1
  }

  It 'replaces a stale line pointing at an old location and keeps other content' {
    Set-Content -LiteralPath $script:Prof -Value @('Set-Alias ll Get-ChildItem', "if (Test-Path -LiteralPath 'C:\old\awsp.ps1') { . 'C:\old\awsp.ps1' } # awsp")
    & $script:Hook -Action Add -ScriptPath $script:Target -ProfileFile $script:Prof
    $lines = Get-Content -LiteralPath $script:Prof
    $lines | Should -Contain 'Set-Alias ll Get-ChildItem'
    @($lines | Where-Object { $_ -match '# awsp$' }).Count | Should -Be 1
    ($lines -join "`n") | Should -Not -Match 'C:\\old'
  }

  It 'removes only awsp lines' {
    Set-Content -LiteralPath $script:Prof -Value @('Set-Alias ll Get-ChildItem')
    & $script:Hook -Action Add -ScriptPath $script:Target -ProfileFile $script:Prof
    & $script:Hook -Action Remove -ScriptPath $script:Target -ProfileFile $script:Prof
    $lines = @(Get-Content -LiteralPath $script:Prof)
    $lines | Should -Be @('Set-Alias ll Get-ChildItem')
  }

  It 'Remove on a missing profile is a no-op' {
    { & $script:Hook -Action Remove -ScriptPath $script:Target -ProfileFile $script:Prof } | Should -Not -Throw
    Test-Path -LiteralPath $script:Prof | Should -BeFalse
  }

  It 'escapes single quotes in the path' {
    $odd = Join-Path $script:Dir "o'brien/awsp.ps1"
    & $script:Hook -Action Add -ScriptPath $odd -ProfileFile $script:Prof
    (Get-Content -LiteralPath $script:Prof -Raw) | Should -Match "o''brien"
  }

  It 'the written line actually loads awsp when the profile is dot-sourced' {
    $repoScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/awsp.ps1'
    & $script:Hook -Action Add -ScriptPath $repoScript -ProfileFile $script:Prof
    $host_ = (Get-Process -Id $PID).Path
    $out = & $host_ -NoProfile -Command ". '$($script:Prof)'; awsp --version"
    ($out -join "`n") | Should -Match 'awsp version'
  }

  It 'writes a BOM-prefixed profile when the path is non-ASCII (5.1 safe)' {
    $uni = Join-Path $script:Dir 'caf?/awsp.ps1' -replace '\?', [string][char]0x00E9
    & $script:Hook -Action Add -ScriptPath $uni -ProfileFile $script:Prof
    $bytes = [System.IO.File]::ReadAllBytes($script:Prof)
    $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
  }
}
```

- [ ] **Step 3: Run tests, verify failure** (**TEST**; "script not found")

- [ ] **Step 4: Write `bin/awsp-profile.ps1`**

```powershell
# Adds/removes the line that loads awsp from PowerShell profile files.
# Shared by install.ps1, the Inno Setup (winget) installer and the Chocolatey package.
# ASCII-only source (Windows PowerShell 5.1 reads BOM-less files as ANSI).
param(
  [Parameter(Mandatory)][ValidateSet('Add', 'Remove')][string]$Action,
  [Parameter(Mandatory)][string]$ScriptPath,
  [string]$ProfileFile,
  [switch]$AllUsers
)

$ErrorActionPreference = 'Stop'
$marker = '# awsp'

function Get-Targets {
  if ($ProfileFile) { return @($ProfileFile) }
  if ($AllUsers) {
    $t = @(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\profile.ps1')
    $pf = Join-Path $env:ProgramFiles 'PowerShell\7'
    if ($Action -eq 'Remove' -or (Test-Path -LiteralPath $pf)) { $t += Join-Path $pf 'profile.ps1' }
    return $t
  }
  $docs = [Environment]::GetFolderPath('MyDocuments')
  $desktop = Join-Path (Join-Path $docs 'WindowsPowerShell') 'profile.ps1'
  $core = Join-Path (Join-Path $docs 'PowerShell') 'profile.ps1'
  $running = $core
  if ($PSVersionTable.PSEdition -ne 'Core') { $running = $desktop }
  $t = @($running)
  $other = $desktop
  if ($running -eq $desktop) { $other = $core }
  if (Test-Path -LiteralPath (Split-Path -Parent $other)) { $t += $other }
  return $t
}

$quoted = "'" + ($ScriptPath -replace "'", "''") + "'"
$line = "if (Test-Path -LiteralPath $quoted) { . $quoted } $marker"
$utf8Bom = New-Object System.Text.UTF8Encoding $true

foreach ($file in Get-Targets) {
  $exists = Test-Path -LiteralPath $file -PathType Leaf
  $existing = @()
  if ($exists) { $existing = [System.IO.File]::ReadAllLines($file) }
  $others = @($existing | Where-Object { -not $_.TrimEnd().EndsWith($marker) })
  $ours = @($existing | Where-Object { $_.TrimEnd().EndsWith($marker) })

  if ($Action -eq 'Remove') {
    if ($ours.Count -gt 0) { [System.IO.File]::WriteAllLines($file, $others) }
    continue
  }

  if ($ours.Count -eq 1 -and $ours[0] -ceq $line) { continue }
  if ($ours.Count -gt 0) { [System.IO.File]::WriteAllLines($file, $others) }
  $dir = Split-Path -Parent $file
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (-not $exists) {
    [System.IO.File]::WriteAllLines($file, @($line), $utf8Bom)
  } else {
    [System.IO.File]::AppendAllText($file, $line + [Environment]::NewLine)
  }
}
```

Note: appending to an existing file that does not end with a newline would glue the line to the previous one; guard it: before `AppendAllText`, if the file is non-empty and its last char is not `\n`, prepend `[Environment]::NewLine` to the appended text. Add that guard and a test (`'appends on its own line when the profile lacks a trailing newline'`: write `'Set-Alias a b'` with `-NoNewline`, run Add, assert 2 lines).

- [ ] **Step 5: Run tests, verify pass** (**TEST**), then commit

```bash
git add bin/awsp-profile.ps1 tests/awsp-profile.Tests.ps1 && git commit -m "feat: add PowerShell profile helper for installers"
```

### Task 7: Release zip and `install.ps1`

**Files:**
- Modify: `scripts/build-release.sh`
- Create: `install.ps1`
- Create: `tests/install.Tests.ps1`

**Interfaces:**
- Consumes: `bin/awsp-profile.ps1` CLI from Task 6.
- Produces: release artifacts `awsp-<version>.zip` (+ `.zip.sha256`, layout `awsp-<version>/{bin/awsp.ps1,bin/awsp-profile.ps1,completions/awsp.completion.ps1,LICENSE,README.md}`); `install.ps1` honoring env `AWSP_VERSION`, `PREFIX` (default `%USERPROFILE%\.config\awsp`), `AWSP_ARCHIVE` (local zip, skips download/checksum), `AWSP_PROFILE_FILE` (single profile target, for tests), `AWSP_UNINSTALL=1`. Installed layout: `PREFIX\awsp.ps1`, `PREFIX\awsp-profile.ps1`, `PREFIX\completions\awsp.completion.ps1`.

- [ ] **Step 1: Failing test for the zip** - append to the header comment of `scripts/build-release.sh` the line `#   awsp-<version>.zip            (+ .sha256; Windows/PowerShell files)`, then run:

```bash
scripts/build-release.sh 0.0.0-test && ls dist | grep -c zip
```

Expected before the change: `0`.

- [ ] **Step 2: Build the zip in `scripts/build-release.sh`**

After the tarball section (after the `sha256sum` line for the tarball) insert:

```sh
# --- zip (Windows / PowerShell) ---
zstage="$work/zip/awsp-$version"
mkdir -p "$zstage/bin" "$zstage/completions"
cp "$root/bin/awsp.ps1" "$root/bin/awsp-profile.ps1" "$zstage/bin/"
cp "$root/completions/awsp.completion.ps1" "$zstage/completions/"
cp "$root/LICENSE" "$root/README.md" "$zstage/"
(cd "$work/zip" && python3 -m zipfile -c "$dist/awsp-$version.zip" "awsp-$version")
(cd "$dist" && sha256sum "awsp-$version.zip" > "awsp-$version.zip.sha256")
```

Run the Step 1 command again. Expected: `2` (zip + zip.sha256), and `python3 -m zipfile -l dist/awsp-0.0.0-test.zip` lists the five paths with forward slashes. Then `rm -rf dist` (it is gitignored? check `git status`; if not ignored, delete it).

- [ ] **Step 3: Write failing install tests** (`tests/install.Tests.ps1`)

```powershell
BeforeAll {
  $script:Repo = Split-Path -Parent $PSScriptRoot
  $script:Installer = Join-Path $script:Repo 'install.ps1'
  $script:HostExe = (Get-Process -Id $PID).Path

  function script:New-TestZip {
    param([string]$Dir, [string]$Version = '9.9.9')
    $root = Join-Path $Dir "awsp-$Version"
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin'), (Join-Path $root 'completions') | Out-Null
    Copy-Item (Join-Path $script:Repo 'bin/awsp.ps1') (Join-Path $root 'bin')
    Copy-Item (Join-Path $script:Repo 'bin/awsp-profile.ps1') (Join-Path $root 'bin')
    Copy-Item (Join-Path $script:Repo 'completions/awsp.completion.ps1') (Join-Path $root 'completions')
    $zip = Join-Path $Dir "awsp-$Version.zip"
    Compress-Archive -Path $root -DestinationPath $zip -Force
    return $zip
  }

  function script:Invoke-Installer {
    param([hashtable]$Env)
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try { & $script:HostExe -NoProfile -ExecutionPolicy Bypass -File $script:Installer *>&1 | Out-String }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
  }
}

BeforeEach {
  $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('awsp inst ' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $script:Dir | Out-Null
  $script:Zip = New-TestZip -Dir $script:Dir
  $script:Prefix = Join-Path $script:Dir 'prefix dir'
  $script:Prof = Join-Path $script:Dir 'profile.ps1'
  $script:Env = @{ AWSP_ARCHIVE = $script:Zip; PREFIX = $script:Prefix; AWSP_PROFILE_FILE = $script:Prof; AWSP_UNINSTALL = $null }
}
AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'install.ps1' {
  It 'installs the files and adds the profile line' {
    $null = Invoke-Installer $script:Env
    Test-Path (Join-Path $script:Prefix 'awsp.ps1') | Should -BeTrue
    Test-Path (Join-Path $script:Prefix 'awsp-profile.ps1') | Should -BeTrue
    Test-Path (Join-Path $script:Prefix 'completions/awsp.completion.ps1') | Should -BeTrue
    (Get-Content -LiteralPath $script:Prof -Raw) | Should -Match 'awsp\.ps1'
  }

  It 'the installed function works from a fresh shell that sources the profile' {
    $null = Invoke-Installer $script:Env
    $out = & $script:HostExe -NoProfile -Command ". '$($script:Prof)'; awsp --version"
    ($out -join "`n") | Should -Match 'awsp version'
  }

  It 'is idempotent' {
    $null = Invoke-Installer $script:Env
    $null = Invoke-Installer $script:Env
    @(Get-Content -LiteralPath $script:Prof | Where-Object { $_ -match '# awsp$' }).Count | Should -Be 1
  }

  It 'uninstalls files, saved profile and profile line, keeping other profile content' {
    Set-Content -LiteralPath $script:Prof -Value 'Set-Alias ll Get-ChildItem'
    $null = Invoke-Installer $script:Env
    Set-Content -LiteralPath (Join-Path $script:Prefix 'current_profile') -Value 'dev'
    $env2 = $script:Env.Clone(); $env2['AWSP_UNINSTALL'] = '1'
    $null = Invoke-Installer $env2
    Test-Path -LiteralPath $script:Prefix | Should -BeFalse
    @(Get-Content -LiteralPath $script:Prof) | Should -Be @('Set-Alias ll Get-ChildItem')
  }

  It 'uninstall leaves unrelated files in PREFIX alone' {
    $null = Invoke-Installer $script:Env
    Set-Content -LiteralPath (Join-Path $script:Prefix 'mine.txt') -Value 'keep'
    $env2 = $script:Env.Clone(); $env2['AWSP_UNINSTALL'] = '1'
    $null = Invoke-Installer $env2
    Test-Path (Join-Path $script:Prefix 'mine.txt') | Should -BeTrue
    Test-Path (Join-Path $script:Prefix 'awsp.ps1') | Should -BeFalse
  }

  It 'fails clearly on a zip with an unexpected layout' {
    $bad = Join-Path $script:Dir 'bad.zip'
    Set-Content -LiteralPath (Join-Path $script:Dir 'x.txt') -Value 'x'
    Compress-Archive -Path (Join-Path $script:Dir 'x.txt') -DestinationPath $bad -Force
    $env2 = $script:Env.Clone(); $env2['AWSP_ARCHIVE'] = $bad
    $out = Invoke-Installer $env2
    $out | Should -Match 'unexpected archive layout'
    Test-Path (Join-Path $script:Prefix 'awsp.ps1') | Should -BeFalse
  }
}
```

Run **TEST**: Expected FAIL (installer missing).

- [ ] **Step 4: Write `install.ps1`**

```powershell
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
  $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
  $prefix = if ($env:PREFIX) { $env:PREFIX } else { Join-Path (Join-Path $userHome '.config') 'awsp' }
  $own = @('awsp.ps1', 'awsp-profile.ps1', 'current_profile', (Join-Path 'completions' 'awsp.completion.ps1'))

  function Die([string]$msg) { throw "awsp install: $msg" }

  function Invoke-ProfileHook([string]$action) {
    $hook = Join-Path $prefix 'awsp-profile.ps1'
    $argsList = @{ Action = $action; ScriptPath = (Join-Path $prefix 'awsp.ps1') }
    if ($env:AWSP_PROFILE_FILE) { $argsList.ProfileFile = $env:AWSP_PROFILE_FILE }
    & $hook @argsList
  }

  if ($env:AWSP_UNINSTALL -eq '1') {
    if (Test-Path -LiteralPath (Join-Path $prefix 'awsp-profile.ps1')) { Invoke-ProfileHook 'Remove' }
    foreach ($f in $own) { Remove-Item -LiteralPath (Join-Path $prefix $f) -Force -ErrorAction SilentlyContinue }
    $comp = Join-Path $prefix 'completions'
    foreach ($d in $comp, $prefix) {
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

    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem -LiteralPath $tmp -Directory -Filter 'awsp-*' | Select-Object -First 1
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
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -in 'Restricted', 'AllSigned' -or ($policy -eq 'Undefined' -and (Get-ExecutionPolicy) -in 'Restricted', 'AllSigned')) {
      Write-Host 'NOTE: your execution policy blocks profile scripts. Run once: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
    }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
```

Note: when run through `irm | iex` the `& { ... }` wrapper keeps variables out of the user's session and `return` ends only the installer.

- [ ] **Step 5: Run tests, verify pass** (**TEST**); run PSScriptAnalyzer (Task 5 Step 8 command with `install.ps1,bin/awsp-profile.ps1` added); fix findings.

- [ ] **Step 6: Document, commit**

Update docs (all in this step):
- `README.md` and `docs/getting-started/installation.md`: add to the install table `| Windows (PowerShell) | install script | \`irm https://raw.githubusercontent.com/ops4life/awsp/main/install.ps1 \| iex\` |` and replace the sentence `Windows is supported through WSL or Git Bash only.` with `On Windows, use the PowerShell installer above (or Chocolatey / winget once published); WSL and Git Bash use the POSIX install script. If PowerShell blocks your profile, run \`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned\` once. Uninstall with \`$env:AWSP_UNINSTALL=1; irm .../install.ps1 | iex\`.` (Chocolatey/winget rows are added in Task 11.)
- `README.md` header bullets: change `Works in **Bash** and **Zsh**.` to `Works in **Bash**, **Zsh** and **PowerShell** (Windows PowerShell 5.1 / PowerShell 7+).`
- `CLAUDE.md`: in "File Structure" add `bin/awsp.ps1`, `bin/awsp-profile.ps1`, `completions/awsp.completion.ps1`, `install.ps1`; in "Project Overview" add one sentence that a native PowerShell port exists with the same flags and must be kept in sync (the parity tests enforce version and flags).
- `docs/reference/repository-structure.md`: add the same files to the tree and a short description.

```bash
git add install.ps1 scripts/build-release.sh tests README.md CLAUDE.md docs && git commit -m "feat: add PowerShell install script and Windows release zip"
```

- [ ] **Step 7: CI** - the Pester job already runs `./tests`, so `install.Tests.ps1` and `awsp-profile.Tests.ps1` run on Windows PowerShell 5.1 and 7 automatically. Add one more step to the `ubuntu` bats job? No: instead add to `test.yaml` a `build-release` check on ubuntu:

```yaml
  release-artifacts:
    name: release artifacts
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v7
      - name: Build artifacts
        run: |
          scripts/build-release.sh 0.0.0-test
          test -f dist/awsp-0.0.0-test.zip
          python3 -m zipfile -l dist/awsp-0.0.0-test.zip | grep -q 'bin/awsp-profile.ps1'
```

Commit with `ci: build release artifacts on every PR`.

- [ ] **Step 8: Ask the user before pushing/PR** (same as Task 5 Step 9; title `feat: add Windows PowerShell installer`). After merge, return to `main` and pull.

---

## Phase 3 - Chocolatey and winget (branch `feature/windows-packages`, from updated `main`)

### Task 8: Chocolatey package

**Files:**
- Create: `packaging/chocolatey/awsp.nuspec`
- Create: `packaging/chocolatey/tools/chocolateyInstall.ps1`
- Create: `packaging/chocolatey/tools/chocolateyUninstall.ps1`
- Create: `scripts/build-windows-packages.ps1` (choco part first; Inno part in Task 9)
- Create: `tests/packaging.Tests.ps1`

**Interfaces:**
- Produces: `scripts/build-windows-packages.ps1 -Version <x.y.z> [-OutDir dist]` -> `dist/awsp.<version>.nupkg` (and, after Task 9, the installer and winget manifests). The nupkg embeds `tools/awsp.ps1`, `tools/awsp-profile.ps1`, `tools/completions/awsp.completion.ps1` (no network at install time). Install param `--params "/Profile"` adds the line to the all-users profiles; otherwise the install prints the line to add. Package id `awsp`; installed script path `$env:ChocolateyInstall\lib\awsp\tools\awsp.ps1`.

- [ ] **Step 1: `git checkout main && git pull origin main && git checkout -b feature/windows-packages`**

- [ ] **Step 2: Write the failing test** (`tests/packaging.Tests.ps1`; skipped where `choco` is absent so Linux/Docker runs stay green)

```powershell
BeforeAll {
  $script:Repo = Split-Path -Parent $PSScriptRoot
  $script:Build = Join-Path $script:Repo 'scripts/build-windows-packages.ps1'
  $script:HasChoco = [bool](Get-Command choco -ErrorAction SilentlyContinue)
  $script:Out = Join-Path ([System.IO.Path]::GetTempPath()) ('awsp pkg ' + [guid]::NewGuid().ToString('N'))
}
AfterAll { Remove-Item -LiteralPath $script:Out -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Chocolatey package' {
  It 'nuspec is well-formed with the expected id' {
    $xml = [xml](Get-Content -Raw (Join-Path $script:Repo 'packaging/chocolatey/awsp.nuspec'))
    $xml.package.metadata.id | Should -Be 'awsp'
    $xml.package.metadata.licenseUrl | Should -Match 'github.com/ops4life/awsp'
  }

  It 'builds a nupkg containing the PowerShell files' -Skip:(-not $script:HasChoco) {
    & $script:Build -Version 0.0.1 -OutDir $script:Out -Only chocolatey
    $nupkg = Join-Path $script:Out 'awsp.0.0.1.nupkg'
    Test-Path $nupkg | Should -BeTrue
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $names = [System.IO.Compression.ZipFile]::OpenRead($nupkg).Entries.FullName
    $names | Should -Contain 'tools/awsp.ps1'
    $names | Should -Contain 'tools/awsp-profile.ps1'
    $names | Should -Contain 'tools/completions/awsp.completion.ps1'
  }

  It 'installs and uninstalls with choco' -Skip:(-not $script:HasChoco) {
    & $script:Build -Version 0.0.1 -OutDir $script:Out -Only chocolatey
    choco install awsp --version 0.0.1 -s $script:Out -y --no-progress | Out-Null
    $LASTEXITCODE | Should -Be 0
    Test-Path (Join-Path $env:ChocolateyInstall 'lib/awsp/tools/awsp.ps1') | Should -BeTrue
    choco uninstall awsp -y --no-progress | Out-Null
    Test-Path (Join-Path $env:ChocolateyInstall 'lib/awsp') | Should -BeFalse
  }
}
```

Run **TEST**: the nuspec test FAILS (file missing); choco tests are skipped locally and exercised in CI on Windows.

- [ ] **Step 3: Create the package sources**

`packaging/chocolatey/awsp.nuspec`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>awsp</id>
    <version>0.0.0</version>
    <title>awsp</title>
    <authors>ops4life</authors>
    <owners>ops4life</owners>
    <projectUrl>https://github.com/ops4life/awsp</projectUrl>
    <projectSourceUrl>https://github.com/ops4life/awsp</projectSourceUrl>
    <docsUrl>https://ops4life.github.io/awsp/</docsUrl>
    <bugTrackerUrl>https://github.com/ops4life/awsp/issues</bugTrackerUrl>
    <licenseUrl>https://github.com/ops4life/awsp/blob/main/LICENSE</licenseUrl>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <copyright>2026 ops4life</copyright>
    <tags>aws profile sso switcher powershell cli</tags>
    <summary>Lightweight AWS profile switcher with SSO auto-login for PowerShell</summary>
    <description>awsp is a PowerShell function that switches AWS profiles (with SSO auto-login if needed).

It must be loaded from your PowerShell profile. Install with `--params "/Profile"` to add it to the all-users profiles automatically, otherwise the install output shows the line to add to your own profile.</description>
    <releaseNotes>https://github.com/ops4life/awsp/releases</releaseNotes>
  </metadata>
  <files>
    <file src="tools\**" target="tools" />
  </files>
</package>
```

`packaging/chocolatey/tools/chocolateyInstall.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script = Join-Path $toolsDir 'awsp.ps1'

$pp = Get-PackageParameters
if ($pp.ContainsKey('Profile')) {
  & (Join-Path $toolsDir 'awsp-profile.ps1') -Action Add -ScriptPath $script -AllUsers
  Write-Host 'awsp was added to the all-users PowerShell profiles. Restart PowerShell.'
} else {
  Write-Host 'awsp installed. Add this line to your PowerShell profile ($PROFILE):'
  Write-Host "  . '$script'"
  Write-Host 'Or reinstall with: choco install awsp --params "/Profile"'
}
```

`packaging/chocolatey/tools/chocolateyUninstall.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
& (Join-Path $toolsDir 'awsp-profile.ps1') -Action Remove -ScriptPath (Join-Path $toolsDir 'awsp.ps1') -AllUsers
```

- [ ] **Step 4: Write `scripts/build-windows-packages.ps1` (choco part)**

```powershell
# Builds Windows packages into -OutDir (default ./dist):
#   awsp.<version>.nupkg                  Chocolatey package (needs choco)
#   awsp-<version>-setup.exe (+ .sha256)  Inno Setup installer for winget (needs ISCC)
#   winget/*.yaml                         winget manifests rendered for this version
# Usage: scripts/build-windows-packages.ps1 -Version 1.9.0 [-OutDir dist] [-Only chocolatey|inno|winget]
param(
  [Parameter(Mandatory)][string]$Version,
  [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'),
  [ValidateSet('all', 'chocolatey', 'inno', 'winget')][string]$Only = 'all'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('awsp-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
  if ($Only -in 'all', 'chocolatey') {
    $stage = Join-Path $work 'choco'
    Copy-Item -Recurse (Join-Path $root 'packaging/chocolatey') $stage
    $tools = Join-Path $stage 'tools'
    New-Item -ItemType Directory -Force -Path (Join-Path $tools 'completions') | Out-Null
    Copy-Item (Join-Path $root 'bin/awsp.ps1'), (Join-Path $root 'bin/awsp-profile.ps1') $tools
    Copy-Item (Join-Path $root 'completions/awsp.completion.ps1') (Join-Path $tools 'completions')
    $nuspec = Join-Path $stage 'awsp.nuspec'
    (Get-Content -Raw $nuspec) -replace '<version>[^<]*</version>', "<version>$Version</version>" |
      Set-Content -NoNewline -Encoding UTF8 $nuspec
    Push-Location $stage
    try { choco pack awsp.nuspec --out $OutDir | Out-Host; if ($LASTEXITCODE -ne 0) { throw 'choco pack failed' } }
    finally { Pop-Location }
  }
  # (Inno Setup and winget manifests are added in Task 9)
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
```

- [ ] **Step 5: Run tests, verify the nuspec test passes** (**TEST**). On Windows CI the build/install tests run (the `pester` job). Commit:

```bash
git add packaging scripts tests && git commit -m "feat: add Chocolatey package for awsp"
```

### Task 9: Inno Setup installer and winget manifests

**Files:**
- Create: `packaging/windows/awsp.iss`
- Create: `packaging/winget/ops4life.awsp.yaml`, `ops4life.awsp.installer.yaml`, `ops4life.awsp.locale.en-US.yaml` (templates)
- Modify: `scripts/build-windows-packages.ps1`
- Modify: `tests/packaging.Tests.ps1`

**Interfaces:**
- Consumes: `bin/awsp-profile.ps1` CLI (Task 6).
- Produces: `dist/awsp-<version>-setup.exe` (+ `.sha256`, single `<hash>  <name>` line), per-user silent-installable to `%LOCALAPPDATA%\Programs\awsp`; winget manifests in `dist/winget/` with `{{VERSION}}` and `{{SHA256}}` substituted. winget package identifier: `ops4life.awsp`.

- [ ] **Step 1: Failing tests** - append to `tests/packaging.Tests.ps1`:

```powershell
Describe 'winget manifests' {
  It 'templates carry the package identifier and placeholders' {
    foreach ($f in 'ops4life.awsp.yaml', 'ops4life.awsp.installer.yaml', 'ops4life.awsp.locale.en-US.yaml') {
      $t = Get-Content -Raw (Join-Path $script:Repo "packaging/winget/$f")
      $t | Should -Match 'PackageIdentifier: ops4life\.awsp'
      $t | Should -Match '\{\{VERSION\}\}'
    }
    (Get-Content -Raw (Join-Path $script:Repo 'packaging/winget/ops4life.awsp.installer.yaml')) | Should -Match '\{\{SHA256\}\}'
  }

  It 'renders manifests with a version and hash' {
    & $script:Build -Version 0.0.1 -OutDir $script:Out -Only winget -InstallerSha256 ('AB' * 32)
    $inst = Get-Content -Raw (Join-Path $script:Out 'winget/ops4life.awsp.installer.yaml')
    $inst | Should -Match 'PackageVersion: 0\.0\.1'
    $inst | Should -Match ('AB' * 32)
    $inst | Should -Not -Match '\{\{'
  }
}

Describe 'Inno Setup installer' {
  BeforeAll {
    $script:Iscc = $null
    foreach ($c in (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source,
                   "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") {
      if ($c -and (Test-Path -LiteralPath $c)) { $script:Iscc = $c; break }
    }
  }

  It 'builds, silently installs, loads in PowerShell, and uninstalls cleanly' -Skip:(-not $script:Iscc) {
    & $script:Build -Version 0.0.1 -OutDir $script:Out -Only inno
    $exe = Join-Path $script:Out 'awsp-0.0.1-setup.exe'
    Test-Path $exe | Should -BeTrue
    Test-Path "$exe.sha256" | Should -BeTrue

    $app = Join-Path $env:LOCALAPPDATA 'Programs\awsp'
    $profileFile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\profile.ps1'
    $p = Start-Process $exe -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    $p.ExitCode | Should -Be 0
    Test-Path (Join-Path $app 'awsp.ps1') | Should -BeTrue
    (Get-Content -LiteralPath $profileFile -Raw) | Should -Match '# awsp'
    $out = powershell -NoProfile -Command ". '$profileFile'; awsp --version"
    ($out -join "`n") | Should -Match 'awsp version'

    $u = Start-Process (Join-Path $app 'unins000.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
    $u.ExitCode | Should -Be 0
    Start-Sleep -Seconds 2
    Test-Path (Join-Path $app 'awsp.ps1') | Should -BeFalse
    (Get-Content -LiteralPath $profileFile -Raw -ErrorAction SilentlyContinue) | Should -Not -Match '# awsp'
  }
}
```

Run **TEST**: winget tests FAIL (templates missing); Inno test skipped locally (runs in Windows CI, where Inno Setup is installed in Task 10).

- [ ] **Step 2: Create `packaging/windows/awsp.iss`**

```ini
; Inno Setup script for the winget package. Build: ISCC /DAppVersion=1.9.0 packaging\windows\awsp.iss
#ifndef AppVersion
  #error AppVersion is not defined (pass /DAppVersion=x.y.z)
#endif

[Setup]
AppId={{6C1B8F2E-4D77-4A0B-9E53-AWSP00000001}
AppName=awsp
AppVersion={#AppVersion}
AppPublisher=ops4life
AppPublisherURL=https://github.com/ops4life/awsp
AppSupportURL=https://github.com/ops4life/awsp/issues
DefaultDirName={localappdata}\Programs\awsp
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
Compression=lzma2
SolidCompression=yes
OutputDir=..\..\dist
OutputBaseFilename=awsp-{#AppVersion}-setup
UninstallDisplayName=awsp
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
Source: "..\..\bin\awsp.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\bin\awsp-profile.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\completions\awsp.completion.ps1"; DestDir: "{app}\completions"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\awsp-profile.ps1"" -Action Add -ScriptPath ""{app}\awsp.ps1"""; Flags: runhidden

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\awsp-profile.ps1"" -Action Remove -ScriptPath ""{app}\awsp.ps1"""; Flags: runhidden; RunOnceId: "RemoveAwspProfileLine"
```

Replace the placeholder AppId GUID with a real one generated once: `python3 -c "import uuid;print('{{'+str(uuid.uuid4()).upper()+'}')"` (Inno needs the doubled leading `{`). It must never change afterwards (winget/upgrade identity).

- [ ] **Step 3: Create the three winget templates**

`packaging/winget/ops4life.awsp.yaml`:

```yaml
# yaml-language-server: $schema=https://aka.ms/winget-manifest.version.1.6.0.schema.json
PackageIdentifier: ops4life.awsp
PackageVersion: {{VERSION}}
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.6.0
```

`packaging/winget/ops4life.awsp.installer.yaml`:

```yaml
# yaml-language-server: $schema=https://aka.ms/winget-manifest.installer.1.6.0.schema.json
PackageIdentifier: ops4life.awsp
PackageVersion: {{VERSION}}
InstallerType: inno
Scope: user
UpgradeBehavior: install
Installers:
  - Architecture: neutral
    InstallerUrl: https://github.com/ops4life/awsp/releases/download/v{{VERSION}}/awsp-{{VERSION}}-setup.exe
    InstallerSha256: {{SHA256}}
ManifestType: installer
ManifestVersion: 1.6.0
```

`packaging/winget/ops4life.awsp.locale.en-US.yaml`:

```yaml
# yaml-language-server: $schema=https://aka.ms/winget-manifest.defaultLocale.1.6.0.schema.json
PackageIdentifier: ops4life.awsp
PackageVersion: {{VERSION}}
PackageLocale: en-US
Publisher: ops4life
PublisherUrl: https://github.com/ops4life
PublisherSupportUrl: https://github.com/ops4life/awsp/issues
PackageName: awsp
PackageUrl: https://github.com/ops4life/awsp
License: MIT
LicenseUrl: https://github.com/ops4life/awsp/blob/main/LICENSE
ShortDescription: Lightweight AWS profile switcher with SSO auto-login for PowerShell.
Description: awsp is a PowerShell function that switches AWS profiles and logs in via AWS SSO when needed. The installer adds it to your PowerShell profile.
Moniker: awsp
Tags:
  - aws
  - sso
  - profile
  - powershell
ManifestType: defaultLocale
ManifestVersion: 1.6.0
```

(`.yamllint`/pre-commit may complain about `{{ }}` as a YAML flow mapping: a bare `{{VERSION}}` in the YAML above is parsed as a mapping key. Quote the placeholder, `"{{VERSION}}"`, in the **templates only** and have the renderer strip the quotes - or exclude `packaging/winget/` in `.yamllint` ignore. Pick the ignore: add `ignore: |\n  packaging/winget/` to `.yamllint` and keep the templates as written.)

- [ ] **Step 4: Extend `scripts/build-windows-packages.ps1`**

Add parameter `[string]$InstallerSha256` to the `param()` block, and replace the `# (Inno Setup and winget manifests are added in Task 9)` line with:

```powershell
  if ($Only -in 'all', 'inno') {
    $iscc = $null
    foreach ($c in (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source,
                   "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") {
      if ($c -and (Test-Path -LiteralPath $c)) { $iscc = $c; break }
    }
    if (-not $iscc) { throw 'Inno Setup (ISCC.exe) not found; install it with: choco install innosetup' }
    & $iscc "/DAppVersion=$Version" "/O$OutDir" (Join-Path $root 'packaging/windows/awsp.iss') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }
    $exe = Join-Path $OutDir "awsp-$Version-setup.exe"
    $InstallerSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    Set-Content -NoNewline -Encoding ASCII -LiteralPath "$exe.sha256" -Value ("$InstallerSha256  " + (Split-Path -Leaf $exe) + "`n")
  }

  if ($Only -in 'all', 'winget') {
    if (-not $InstallerSha256) { throw 'winget manifests need the installer hash (-InstallerSha256, or build inno first)' }
    $wdir = Join-Path $OutDir 'winget'
    New-Item -ItemType Directory -Force -Path $wdir | Out-Null
    foreach ($f in Get-ChildItem (Join-Path $root 'packaging/winget') -Filter '*.yaml') {
      (Get-Content -Raw $f.FullName).Replace('{{VERSION}}', $Version).Replace('{{SHA256}}', $InstallerSha256) |
        Set-Content -NoNewline -Encoding UTF8 (Join-Path $wdir $f.Name)
    }
  }
```

- [ ] **Step 5: Run tests** (**TEST**: winget tests pass; Inno test skipped locally). Commit:

```bash
git add packaging scripts tests .yamllint && git commit -m "feat: add Inno Setup installer and winget manifests"
```

### Task 10: Release workflow, publishing and docs

**Files:**
- Modify: `.github/workflows/release.yaml`
- Create: `.github/workflows/bump-windows-packages.yaml`
- Create: `scripts/publish-windows-packages.ps1`
- Modify: `.github/workflows/test.yaml` (packaging job)
- Modify: `README.md`, `docs/getting-started/installation.md`, `CLAUDE.md`, `docs/reference/repository-structure.md`

**Interfaces:**
- Consumes: `scripts/build-windows-packages.ps1` outputs.
- Produces: `scripts/publish-windows-packages.ps1 -Version <v> -Dir <dir containing awsp.<v>.nupkg and awsp-<v>-setup.exe>`; reads `CHOCO_API_KEY` and `WINGET_PKGS_TOKEN` from the environment and **skips with a notice (exit 0) when a secret is missing**.

- [ ] **Step 1: Write `scripts/publish-windows-packages.ps1`**

```powershell
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
```

(`wingetcreate update` only works once `ops4life.awsp` exists in winget-pkgs - the first submission is manual, see Step 5.)

- [ ] **Step 2: Release workflow** - in `.github/workflows/release.yaml`, add to the `release` job

```yaml
    outputs:
      published: ${{ steps.release.outputs.new_release_published }}
      version: ${{ steps.release.outputs.new_release_version }}
```

(directly under `runs-on:`), and append a second job:

```yaml
  windows-packages:
    name: Windows packages
    needs: release
    if: needs.release.outputs.published == 'true'
    runs-on: windows-latest
    env:
      CHOCO_API_KEY: ${{ secrets.CHOCO_API_KEY }}
      WINGET_PKGS_TOKEN: ${{ secrets.WINGET_PKGS_TOKEN }}
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      VERSION: ${{ needs.release.outputs.version }}
    steps:
      - name: Checkout release tag
        uses: actions/checkout@v7
        with:
          ref: v${{ needs.release.outputs.version }}
          persist-credentials: false

      - name: Install Inno Setup
        shell: pwsh
        run: choco install innosetup -y --no-progress

      - name: Build packages
        shell: pwsh
        run: scripts/build-windows-packages.ps1 -Version $env:VERSION

      - name: Upload to the release
        shell: pwsh
        run: |
          gh release upload "v$env:VERSION" "dist/awsp.$env:VERSION.nupkg" "dist/awsp-$env:VERSION-setup.exe" "dist/awsp-$env:VERSION-setup.exe.sha256" --clobber --repo $env:GITHUB_REPOSITORY

      - name: Publish (Chocolatey, winget)
        shell: pwsh
        run: scripts/publish-windows-packages.ps1 -Version $env:VERSION -Dir dist
```

`.github/workflows/bump-windows-packages.yaml` (manual re-publish, mirrors `bump-tap.yaml`):

```yaml
name: Publish Windows packages

on:
  workflow_dispatch:
    inputs:
      version:
        description: "Version to publish, e.g. 1.9.0 (default is the latest release)"
        required: false

jobs:
  publish:
    runs-on: windows-latest
    env:
      CHOCO_API_KEY: ${{ secrets.CHOCO_API_KEY }}
      WINGET_PKGS_TOKEN: ${{ secrets.WINGET_PKGS_TOKEN }}
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      INPUT_VERSION: ${{ inputs.version }}
    steps:
      - name: Checkout
        uses: actions/checkout@v7
        with:
          persist-credentials: false

      - name: Download release assets and publish
        shell: pwsh
        run: |
          $v = $env:INPUT_VERSION
          if (-not $v) { $v = (gh release view --repo $env:GITHUB_REPOSITORY --json tagName -q .tagName) }
          $v = $v.TrimStart('v')
          gh release download "v$v" --repo $env:GITHUB_REPOSITORY --pattern "awsp.$v.nupkg" --pattern "awsp-$v-setup.exe" --dir dist
          scripts/publish-windows-packages.ps1 -Version $v -Dir dist
```

- [ ] **Step 3: Package smoke test in PR CI** - add to `test.yaml`:

```yaml
  windows-packages:
    name: windows packages
    runs-on: windows-latest
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v7

      - name: Install Inno Setup
        shell: pwsh
        run: choco install innosetup -y --no-progress

      - name: Install Pester
        shell: pwsh
        run: |
          Set-PSRepository PSGallery -InstallationPolicy Trusted
          Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser

      - name: Build, install and uninstall the packages
        shell: pwsh
        run: |
          $c = New-PesterConfiguration
          $c.Run.Path = './tests/packaging.Tests.ps1'
          $c.Run.Exit = $true
          $c.Output.Verbosity = 'Detailed'
          Invoke-Pester -Configuration $c
```

(This is where the choco install/uninstall and the Inno silent install/uninstall tests actually execute.) Also add `scripts/publish-windows-packages.ps1` to the PSScriptAnalyzer path filter (it already matches `[\\/]scripts[\\/]`).

- [ ] **Step 4: Docs** - in `README.md` and `docs/getting-started/installation.md` extend the Windows rows:

```markdown
| Windows | [Chocolatey](https://chocolatey.org/) | `choco install awsp --params "/Profile"` |
| Windows | [winget](https://learn.microsoft.com/windows/package-manager/) | `winget install ops4life.awsp` |
```

and add one sentence after the install-table notes: `The Chocolatey package leaves your profile alone unless you pass /Profile (it then edits the all-users PowerShell profiles); otherwise add \`. "$env:ChocolateyInstall\lib\awsp\tools\awsp.ps1"\` to your \`$PROFILE\`. The winget installer adds the line to your user profile and removes it on uninstall.` Update `CLAUDE.md` and `docs/reference/repository-structure.md` with `packaging/`, `scripts/build-windows-packages.ps1`, `scripts/publish-windows-packages.ps1`, and a note that Chocolatey/winget publishing needs repo secrets `CHOCO_API_KEY` and `WINGET_PKGS_TOKEN`.

Do **not** claim the packages are live in the docs until the maintainer has completed Step 5; word the table rows as "once published" or leave them out until then (ask the user which).

- [ ] **Step 5: Hand the maintainer the manual checklist (do not perform these)** - print this in the final message:

1. Create a Chocolatey community account, copy the API key, add repo secret `CHOCO_API_KEY`. The first `choco push` enters moderation and may need follow-up edits.
2. Create a classic PAT with `public_repo` scope under the account that will submit PRs and add repo secret `WINGET_PKGS_TOKEN`.
3. Submit the first winget manifest manually: download `dist/winget/*.yaml` from a built release (or run `scripts/build-windows-packages.ps1 -Version <v>` on Windows), then `wingetcreate submit` / PR to `microsoft/winget-pkgs` (later releases are automated).
4. Re-run "Publish Windows packages" (workflow_dispatch) for the current release once the secrets exist.

- [ ] **Step 6: Lint and commit**

```bash
pre-commit run --all-files
git add .github scripts README.md CLAUDE.md docs && git commit -m "feat: publish Chocolatey and winget packages on release"
```

Expected: pre-commit (yamllint, gitleaks, whitespace) passes. Run the PSScriptAnalyzer docker command from Task 5 Step 8 with the new `scripts/*.ps1` added and fix findings.

- [ ] **Step 7: Ask the user before pushing/PR** (title `feat: add Chocolatey and winget packages for Windows`). After merge: `git checkout main && git pull origin main`.

---

## Self-Review

**Spec coverage**
- `bin/awsp.ps1` parity (flags, discovery, picker, switch, SSO login/verify, static-cred disabling, add/remove/modify, `-U` hint, auto-load) -> Tasks 1-4. Intentional gap: precmd hook (see Global Constraints).
- Completion -> Task 5. Windows CI (Pester on 5.1 + 7, PSScriptAnalyzer) -> Task 5.
- Version bump wiring -> Task 5 Step 6. Release zip + checksum -> Task 7. `install.ps1` (+ uninstall, hash check, idempotent profile edit) -> Tasks 6-7.
- Chocolatey -> Task 8. winget (Inno exe, manifests) -> Task 9. Publish automation, secrets, manual first-submission steps -> Task 10.
- Docs (README, installation, CLAUDE.md, repo structure) -> Tasks 7 and 10.
- Spec deviations made explicit: `awsp-profile.ps1` helper added (shared by three installers); the Chocolatey package embeds the files (no download/checksum); `-U` only prints guidance; `--` handling and 5-try cap on empty profile name added.

**Placeholder scan:** the only `TBD`-like item is the Inno `AppId` GUID, which Task 9 Step 2 tells the implementer to generate with the given command; the `# (...added in Task N)` comments are code anchors replaced by the named task.

**Type/name consistency:** `_awsp_config_section_name`, `_awsp_list_profiles`, `_awsp_pick`, `_awsp_aws_quiet`, `_awsp_is_sso_profile`, `_awsp_disable_static_creds`, `_awsp_autoload`, `_awsp_remove_section`, `_awsp_complete_words`, `$global:AWSP_VERSION`, `$global:_AWSP_SCRIPT`, marker `# awsp`, package id `ops4life.awsp`, installed layout `awsp.ps1 / awsp-profile.ps1 / completions\awsp.completion.ps1` are used identically across tasks.

**Known limits:** PowerShell 5.1 behavior, Inno Setup, Chocolatey and winget steps can only be executed in Windows CI (no PowerShell/Windows locally); locally only PowerShell 7 on Linux via Docker is available, so Task 5's CI run is the first real 5.1 check - expect to iterate on it.
