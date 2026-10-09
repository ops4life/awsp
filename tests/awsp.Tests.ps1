BeforeAll {
  $script:Repo = Split-Path -Parent $PSScriptRoot
  $script:AwspPs1 = Join-Path $script:Repo 'bin/awsp.ps1'
  $script:MockAws = Join-Path $PSScriptRoot 'fixtures/mock-aws.ps1'
  $script:Helpers = Join-Path $PSScriptRoot 'fixtures/test-helpers.ps1'
}

Describe 'awsp' {

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

  It 'arguments after a quoted double-dash are treated as the profile name' {
    $out = awsp '--' '--weird' *>&1 | Out-String
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
    @(@(Get-Content -LiteralPath $env:MOCK_AWS_LOG -ErrorAction SilentlyContinue) -match '^sts ').Count | Should -Be 0
  }

  It 'auto-logs in via SSO when the STS identity check fails' {
    $env:MOCK_AWS_STS_FAIL = '1'
    awsp dev --quiet *>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0
    @(@(Get-Content -LiteralPath $env:MOCK_AWS_LOG) -match '^sso login').Count | Should -BeGreaterThan 0
  }

  It 'fails with exit 1 when SSO login fails' {
    $env:MOCK_AWS_STS_FAIL = '1'; $env:MOCK_AWS_SSO_LOGIN_EXIT = '1'
    $out = awsp dev --quiet *>&1 | Out-String
    $LASTEXITCODE | Should -Be 1
    $out | Should -Match 'SSO login failed'
  }

  It '--login forces aws sso login' {
    awsp dev --login --no-verify --quiet *>&1 | Out-Null
    @(@(Get-Content -LiteralPath $env:MOCK_AWS_LOG) -match '^sso login --profile dev$').Count | Should -Be 1
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
    @($creds | Where-Object { $_ -eq 'aws_access_key_id = AKIAFAKE' }).Count | Should -Be 1   # [other] untouched
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
    $optLine = '(?m)^\s+(-[A-Za-z], )?(--[\w-]+|-[A-Za-z])'
    $flags = { param($t) [regex]::Matches($t, $optLine) | ForEach-Object { $_.Groups[1].Value.Trim(', '), $_.Groups[2].Value } | Where-Object { $_ } | Sort-Object -Unique }
    $shFlags = & $flags $usage
    $psFlags = & $flags (awsp --help *>&1 | Out-String)
    ($psFlags -join ',') | Should -Be ($shFlags -join ',')
    @($shFlags).Count | Should -BeGreaterThan 15
  }
}

Describe 'completion through the real completion engine' {
  It 'completes flags and profile names via TabExpansion2' {
    Write-ConfigProfile -Name 'prodx'
    $hostExe = (Get-Process -Id $PID).Path
    $cmd = ". '$($script:AwspPs1)'; " +
      "(TabExpansion2 'awsp --j' 8).CompletionMatches.CompletionText -join ','; " +
      "(TabExpansion2 'awsp pro' 8).CompletionMatches.CompletionText -join ','"
    $env:PATH = Join-Path $script:TestHome 'empty'
    $out = @(& $hostExe -NoProfile -Command $cmd)
    $out[0] | Should -Be '--json'
    $out[1] | Should -Match 'prodx'
  }
}

# APPEND-TESTS-ABOVE
}
