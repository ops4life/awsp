BeforeAll {
  $script:Repo = Split-Path -Parent $PSScriptRoot
  $script:Hook = Join-Path $script:Repo 'bin/awsp-profile.ps1'
}

Describe 'awsp-profile.ps1' {
  BeforeEach {
    $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('awsp hook ' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Dir | Out-Null
    $script:Prof = Join-Path $script:Dir 'profile.ps1'
    $script:Target = Join-Path $script:Dir 'awsp.ps1'
  }

  AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

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
    $repoScript = Join-Path $script:Repo 'bin/awsp.ps1'
    & $script:Hook -Action Add -ScriptPath $repoScript -ProfileFile $script:Prof
    $hostExe = (Get-Process -Id $PID).Path
    $out = & $hostExe -NoProfile -Command ". '$($script:Prof)'; awsp --version"
    ($out -join "`n") | Should -Match 'awsp version'
  }

  It 'writes a BOM-prefixed profile when the path is non-ASCII (5.1 safe)' {
    $uni = Join-Path $script:Dir ('caf' + [char]0x00E9 + '/awsp.ps1')
    & $script:Hook -Action Add -ScriptPath $uni -ProfileFile $script:Prof
    $bytes = [System.IO.File]::ReadAllBytes($script:Prof)
    $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
  }

  It 'appends on its own line when the profile lacks a trailing newline' {
    [System.IO.File]::WriteAllText($script:Prof, 'Set-Alias a b')
    & $script:Hook -Action Add -ScriptPath $script:Target -ProfileFile $script:Prof
    $lines = @(Get-Content -LiteralPath $script:Prof)
    $lines.Count | Should -Be 2
    $lines[0] | Should -Be 'Set-Alias a b'
  }

  It 'preserves a UTF-16LE profile (5.1 "> $PROFILE" style) when adding and removing' {
    $enc = New-Object System.Text.UnicodeEncoding($false, $true)
    $orig = 'Write-Host "caf' + [char]0x00E9 + '"'
    [System.IO.File]::WriteAllText($script:Prof, $orig + [Environment]::NewLine, $enc)
    & $script:Hook -Action Add -ScriptPath $script:Target -ProfileFile $script:Prof
    $bytes = [System.IO.File]::ReadAllBytes($script:Prof)
    $bytes[0..1] | Should -Be @(0xFF, 0xFE)
    $lines = @(Get-Content -LiteralPath $script:Prof)
    $lines[0] | Should -Be $orig
    @($lines | Where-Object { $_ -match '# awsp$' }).Count | Should -Be 1
    & $script:Hook -Action Remove -ScriptPath $script:Target -ProfileFile $script:Prof
    ([System.IO.File]::ReadAllBytes($script:Prof))[0..1] | Should -Be @(0xFF, 0xFE)
    @(Get-Content -LiteralPath $script:Prof) | Should -Be @($orig)
  }

  It 'keeps a UTF-8 BOM and non-ASCII content when removing' {
    $enc = New-Object System.Text.UTF8Encoding $true
    $orig = '# caf' + [char]0x00E9
    [System.IO.File]::WriteAllText($script:Prof, $orig + [Environment]::NewLine, $enc)
    & $script:Hook -Action Add -ScriptPath $script:Target -ProfileFile $script:Prof
    & $script:Hook -Action Remove -ScriptPath $script:Target -ProfileFile $script:Prof
    ([System.IO.File]::ReadAllBytes($script:Prof))[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    @(Get-Content -LiteralPath $script:Prof) | Should -Be @($orig)
  }

  It 'targets both PowerShell editions for the current user' {
    $docs = Join-Path $script:Dir 'Documents'
    New-Item -ItemType Directory -Force -Path $docs | Out-Null
    $saved = $env:SystemRoot
    $env:SystemRoot = $script:Dir
    try { & $script:Hook -Action Add -ScriptPath $script:Target -DocumentsDir $docs }
    finally { $env:SystemRoot = $saved }
    Test-Path (Join-Path $docs 'WindowsPowerShell/profile.ps1') | Should -BeTrue
    Test-Path (Join-Path $docs 'PowerShell/profile.ps1') | Should -BeTrue
  }
}
