$ErrorActionPreference = 'Stop'
foreach ($file in (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\profile.ps1'),
                  (Join-Path $env:ProgramFiles 'PowerShell\7\profile.ps1')) {
  if (-not (Test-Path -LiteralPath $file)) { continue }
  $lines = [IO.File]::ReadAllLines($file)
  $others = @($lines | Where-Object { -not $_.TrimEnd().EndsWith('# awsp') })
  if ($others.Count -ne $lines.Count) { [IO.File]::WriteAllLines($file, [string[]]$others) }
}
