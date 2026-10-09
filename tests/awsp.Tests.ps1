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

# APPEND-TESTS-ABOVE
}
