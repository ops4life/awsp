# Builds Windows packages into -OutDir (default ./dist):
#   awsp.<version>.nupkg                  Chocolatey package (needs choco)
#   awsp-<version>-setup.exe (+ .sha256)  Inno Setup installer for winget (needs ISCC)
#   winget/*.yaml                         winget manifests rendered for this version
# Usage: scripts/build-windows-packages.ps1 -Version 1.9.0 [-OutDir dist] [-Only chocolatey|inno|winget]
param(
  [Parameter(Mandatory)][string]$Version,
  [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'),
  [ValidateSet('all', 'chocolatey', 'inno', 'winget')][string]$Only = 'all',
  [string]$InstallerSha256
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
      (Get-Content -Raw $f.FullName).Replace('__VERSION__', $Version).Replace('__SHA256__', $InstallerSha256) |
        Set-Content -NoNewline -Encoding UTF8 (Join-Path $wdir $f.Name)
    }
  }
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
