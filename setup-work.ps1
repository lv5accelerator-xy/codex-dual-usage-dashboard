param([switch]$NoPause)
& (Join-Path $PSScriptRoot 'setup-account.ps1') -Account work -NoPause:$NoPause
