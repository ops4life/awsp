# Discovery-time probes (used by -Skip); Pester evaluates -Skip while discovering tests.
$hasChoco = [bool](Get-Command choco -ErrorAction SilentlyContinue)
$isccPath = $null
foreach ($c in (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source,
               "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") {
  if ($c -and (Test-Path -LiteralPath $c)) { $isccPath = $c; break }
}
$hasIscc = [bool]$isccPath

BeforeAll {
  $script:Repo = Split-Path -Parent $PSScriptRoot
  $script:Build = Join-Path $script:Repo 'scripts/build-windows-packages.ps1'
  $script:Out = Join-Path ([System.IO.Path]::GetTempPath()) ('awsp pkg ' + [guid]::NewGuid().ToString('N'))
}
AfterAll { Remove-Item -LiteralPath $script:Out -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Chocolatey package' {
  It 'nuspec is well-formed with the expected id' {
    $xml = [xml](Get-Content -Raw (Join-Path $script:Repo 'packaging/chocolatey/awsp.nuspec'))
    $xml.package.metadata.id | Should -Be 'awsp'
    $xml.package.metadata.licenseUrl | Should -Match 'github.com/ops4life/awsp'
  }

  It 'builds a nupkg containing the PowerShell files' -Skip:(-not $hasChoco) {
    & $script:Build -Version 0.0.1 -OutDir $script:Out -Only chocolatey
    $nupkg = Join-Path $script:Out 'awsp.0.0.1.nupkg'
    Test-Path $nupkg | Should -BeTrue
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkg)
    try { $names = $zip.Entries.FullName } finally { $zip.Dispose() }   # an open handle would lock the nupkg on Windows
    $names | Should -Contain 'tools/awsp.ps1'
    $names | Should -Contain 'tools/awsp-profile.ps1'
    $names | Should -Contain 'tools/completions/awsp.completion.ps1'
  }

  It 'installs and uninstalls with choco' -Skip:(-not $hasChoco) {
    & $script:Build -Version 0.0.1 -OutDir $script:Out -Only chocolatey
    choco install awsp --version 0.0.1 -s $script:Out -y --no-progress | Out-Null
    $LASTEXITCODE | Should -Be 0
    Test-Path (Join-Path $env:ChocolateyInstall 'lib/awsp/tools/awsp.ps1') | Should -BeTrue
    choco uninstall awsp -y --no-progress | Out-Null
    Test-Path (Join-Path $env:ChocolateyInstall 'lib/awsp') | Should -BeFalse
  }
}

Describe 'Inno Setup installer' {
  It 'builds, silently installs, loads in PowerShell, and uninstalls cleanly' -Skip:(-not $hasIscc) {
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
