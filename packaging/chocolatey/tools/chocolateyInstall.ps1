$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script = Join-Path $toolsDir 'awsp.ps1'

$pp = Get-PackageParameters
if ($pp.ContainsKey('Profile')) {
  & (Join-Path $toolsDir 'awsp-profile.ps1') -Action Add -ScriptPath $script -AllUsers
  Write-Host 'awsp was added to the all-users PowerShell profiles. Restart PowerShell.'
} else {
  Write-Host 'awsp installed. Add this line to your PowerShell profile ($PROFILE):'
  Write-Host "  . '$script'"
  Write-Host 'Or reinstall with: choco install awsp --params "/Profile"'
}
