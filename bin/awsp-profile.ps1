# Adds/removes the line that loads awsp from PowerShell profile files.
# Shared by install.ps1, the Inno Setup (winget) installer and the Chocolatey package.
# ASCII-only source (Windows PowerShell 5.1 reads BOM-less files as ANSI).
param(
  [Parameter(Mandatory)][ValidateSet('Add', 'Remove')][string]$Action,
  [Parameter(Mandatory)][string]$ScriptPath,
  [string]$ProfileFile,
  [string]$DocumentsDir,
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
  $docs = $DocumentsDir
  if (-not $docs) { $docs = [Environment]::GetFolderPath('MyDocuments') }
  $desktop = Join-Path (Join-Path $docs 'WindowsPowerShell') 'profile.ps1'
  $core = Join-Path (Join-Path $docs 'PowerShell') 'profile.ps1'
  $t = @($desktop, $core)
  if ($Action -eq 'Remove') { return $t }
  # Add: always the running edition; the other one when that PowerShell is present
  # (installing pwsh does not create Documents\PowerShell, so check for the install itself).
  $runningCore = ($PSVersionTable.PSEdition -eq 'Core')
  $hasDesktop = [bool]$env:SystemRoot   # Windows PowerShell ships with every Windows
  $hasCore = $runningCore -or (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'PowerShell\7')) -or
    [bool](Get-Command pwsh -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath (Split-Path -Parent $core))
  $result = @()
  if ($hasDesktop -or -not $runningCore) { $result += $desktop }
  if ($hasCore) { $result += $core }
  return $result
}

# Reads a text file keeping its encoding (UTF-16/UTF-8 BOM, else BOM-less UTF-8).
function Read-Text([string]$path) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $enc = New-Object System.Text.UTF8Encoding $false
  $skip = 0
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $enc = New-Object System.Text.UTF8Encoding $true; $skip = 3
  } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $enc = New-Object System.Text.UnicodeEncoding($false, $true); $skip = 2
  } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    $enc = New-Object System.Text.UnicodeEncoding($true, $true); $skip = 2
  }
  return [pscustomobject]@{ Text = $enc.GetString($bytes, $skip, $bytes.Length - $skip); Encoding = $enc }
}

$quoted = "'" + ($ScriptPath -replace "'", "''") + "'"
$line = "if (Test-Path -LiteralPath $quoted) { . $quoted } $marker"
$nl = [Environment]::NewLine

foreach ($file in Get-Targets) {
  $exists = Test-Path -LiteralPath $file -PathType Leaf
  $enc = New-Object System.Text.UTF8Encoding $true   # new files get a BOM (5.1 safe for non-ASCII paths)
  $lines = @()
  if ($exists) {
    $r = Read-Text $file
    $enc = $r.Encoding
    if ($r.Text.Length -gt 0) {
      $lines = @($r.Text -split "\r?\n")
      if ($lines[-1] -eq '') { $lines = @($lines[0..($lines.Count - 2)] | Where-Object { $true }) }
    }
  }
  $others = @($lines | Where-Object { -not $_.TrimEnd().EndsWith($marker) })
  $ours = @($lines | Where-Object { $_.TrimEnd().EndsWith($marker) })

  if ($Action -eq 'Remove') {
    if ($ours.Count -gt 0) {
      $body = ''
      if ($others.Count -gt 0) { $body = ($others -join $nl) + $nl }
      [System.IO.File]::WriteAllText($file, $body, $enc)
    }
    continue
  }

  if ($ours.Count -eq 1 -and $ours[0] -ceq $line) { continue }
  $dir = Split-Path -Parent $file
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($file, ((@($others) + $line) -join $nl) + $nl, $enc)
}
