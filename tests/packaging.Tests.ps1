# Discovery-time probes (used by -Skip); Pester evaluates -Skip while discovering tests.
$hasChoco = [bool](Get-Command choco -ErrorAction SilentlyContinue)

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
    $names = [System.IO.Compression.ZipFile]::OpenRead($nupkg).Entries.FullName
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
