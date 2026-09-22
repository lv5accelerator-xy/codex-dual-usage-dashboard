$ErrorActionPreference = 'Stop'

function Assert-CodexTools([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw ('Codex tools test: ' + $Message) }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'codex-tools.ps1')

$sample = '[CmdletBinding()]' + [Environment]::NewLine + 'param()' + [Environment]::NewLine + "Write-Output 'ok'"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($sample)
$decoded = Convert-WebResponseContentToText $bytes
Assert-CodexTools ($decoded -eq $sample) 'UTF-8 byte[] response must decode to installer script text.'

$stringDecoded = Convert-WebResponseContentToText $sample
Assert-CodexTools ($stringDecoded -eq $sample) 'String response must pass through unchanged.'

Assert-CodexTools (-not ($decoded -match '^\s*91\s+67\s+109')) 'Decoded installer must not become decimal byte values.'

Write-Output 'Codex tools tests passed.'
