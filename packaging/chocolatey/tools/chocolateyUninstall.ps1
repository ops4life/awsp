$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
& (Join-Path $toolsDir 'awsp-profile.ps1') -Action Remove -ScriptPath (Join-Path $toolsDir 'awsp.ps1') -AllUsers
