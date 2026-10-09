# Feeds scripted answers to awsp's interactive prompts.
function Set-AwspInput {
  param([string[]]$Lines)
  $global:AwspTestInputs = New-Object System.Collections.Queue
  foreach ($l in $Lines) { $global:AwspTestInputs.Enqueue($l) }
}

function _awsp_read {
  param([string]$prompt)
  if ($global:AwspTestInputs -and $global:AwspTestInputs.Count -gt 0) { return $global:AwspTestInputs.Dequeue() }
  return ''
}

function Write-ConfigProfile {
  param([string]$Name, [switch]$Sso)
  $lines = @("[profile $Name]")
  if ($Sso) {
    $lines += 'sso_start_url = https://example.awsapps.com/start', 'sso_region = us-east-1',
      'sso_account_id = 123456789012', 'sso_role_name = Admin'
  } else {
    $lines += 'region = us-east-1'
  }
  Add-Content -LiteralPath (Join-Path (Join-Path $env:USERPROFILE '.aws') 'config') -Value $lines
}

function Write-CredsProfile {
  param([string]$Name)
  Add-Content -LiteralPath (Join-Path (Join-Path $env:USERPROFILE '.aws') 'credentials') `
    -Value @("[$Name]", 'aws_access_key_id = AKIAFAKE', 'aws_secret_access_key = fakesecret')
}
