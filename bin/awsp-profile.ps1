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
  if ($ours.Count -gt 0) {
    [System.IO.File]::WriteAllLines($file, $others)
    $existing = $others
  }
  $dir = Split-Path -Parent $file
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (-not $exists) {
    [System.IO.File]::WriteAllLines($file, @($line), $utf8Bom)
  } else {
    $prefix = ''
    $raw = [System.IO.File]::ReadAllText($file)
    if ($raw.Length -gt 0 -and -not $raw.EndsWith("`n")) { $prefix = [Environment]::NewLine }
    [System.IO.File]::AppendAllText($file, $prefix + $line + [Environment]::NewLine)
  }
}
