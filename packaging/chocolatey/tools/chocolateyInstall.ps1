$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script = Join-Path $toolsDir 'awsp.ps1'

$pp = Get-PackageParameters
if ($pp.ContainsKey('Profile')) {
  # Same marker and line format as bin/awsp-profile.ps1; kept inline so the package has at most 3 scripts.
  $line = "if (Test-Path -LiteralPath '$($script -replace "'", "''")') { . '$($script -replace "'", "''")' } # awsp"
  $targets = @(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\profile.ps1')
  $pf = Join-Path $env:ProgramFiles 'PowerShell\7'
  if (Test-Path -LiteralPath $pf) { $targets += Join-Path $pf 'profile.ps1' }
  foreach ($file in $targets) {
    $others = @()
    if (Test-Path -LiteralPath $file) { $others = @([IO.File]::ReadAllLines($file) | Where-Object { -not $_.TrimEnd().EndsWith('# awsp') }) }
    [IO.File]::WriteAllLines($file, [string[]]($others + $line))
  }
  Write-Host 'awsp was added to the all-users PowerShell profiles. Restart PowerShell.'
} else {
  Write-Host 'awsp installed. Add this line to your PowerShell profile ($PROFILE):'
  Write-Host "  . '$script'"
  Write-Host 'Or reinstall with: choco install awsp --params "/Profile"'
}
