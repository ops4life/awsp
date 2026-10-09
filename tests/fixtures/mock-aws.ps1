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
