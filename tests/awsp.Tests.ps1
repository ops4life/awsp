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

# APPEND-TESTS-ABOVE
}
