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
    $ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 turns child stderr into terminating errors under Stop
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try { & $script:HostExe -NoProfile -ExecutionPolicy Bypass -File $script:Installer *>&1 | Out-String }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
  }
}

Describe 'install.ps1' {
  BeforeEach {
    $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('awsp inst ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Dir | Out-Null
    $script:Zip = New-TestZip -Dir $script:Dir
    $script:Prefix = Join-Path $script:Dir 'prefix dir'
    $script:Prof = Join-Path $script:Dir 'profile.ps1'
    $script:Env = @{ AWSP_ARCHIVE = $script:Zip; PREFIX = $script:Prefix; AWSP_PROFILE_FILE = $script:Prof; AWSP_UNINSTALL = $null }
  }
  AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

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
