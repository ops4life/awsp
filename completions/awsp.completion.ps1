# PowerShell tab completion for awsp: flags and profile names.
# Loaded by awsp.ps1; safe to dot-source on its own after awsp.ps1.

$script:_AwspFlags = @(
  '-h', '--help', '-V', '--version', '-l', '--list', '-c', '--current', '-u', '--unset',
  '-U', '--upgrade', '-a', '--add', '-r', '--remove', '-m', '--modify', '-L', '--login',
  '-v', '--verify', '--no-verify', '--json', '-q', '--quiet'
)

function _awsp_complete_words([string]$word) {
  $candidates = @()
  if ($word -like '-*') {
    $candidates = $script:_AwspFlags | Where-Object { $_ -clike "$word*" }
  } elseif (Get-Command _awsp_list_profiles -ErrorAction SilentlyContinue) {
    $hasAws = [bool](Get-Command aws -ErrorAction SilentlyContinue)
    $candidates = @(_awsp_list_profiles $hasAws) | Where-Object { $_ -like "$word*" }
  }
  foreach ($c in $candidates) {
    $text = $c
    if ($c -match '\s') { $text = "'" + ($c -replace "'", "''") + "'" }
    [System.Management.Automation.CompletionResult]::new($text, $c, 'ParameterValue', $c)
  }
}

# Native-style completer (works for argument positions of plain functions) ...
Register-ArgumentCompleter -Native -CommandName awsp -ScriptBlock {
  param($wordToComplete, $commandAst, $cursorPosition)
  _awsp_complete_words $wordToComplete
}
# ... and the regular one.
Register-ArgumentCompleter -CommandName awsp -ScriptBlock {
  param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)
  _awsp_complete_words $wordToComplete
}
