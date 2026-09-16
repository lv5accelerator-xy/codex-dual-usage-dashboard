param(
  [Parameter(Mandatory = $true)][string]$OutputPath,
  [Parameter(Mandatory = $true)][string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Write-WorkerLog {
  param([string]$Message)
  try {
    $line = ('[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
  } catch {}
}

try {
  $root = Split-Path -Parent $MyInvocation.MyCommand.Path
  $logDir = Split-Path -Parent $LogPath
  if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

  Write-WorkerLog 'Worker started.'
  . (Join-Path $root 'codex-tools.ps1')
  . (Join-Path $root 'usage-reader.ps1')

  $codexPath = Find-CodexCommand
  if ([string]::IsNullOrWhiteSpace([string]$codexPath)) {
    throw '未找到 Codex CLI。请先运行 first-run-setup.bat 完成安装和账号登录。'
  }
  Write-WorkerLog ('Codex path: ' + $codexPath)

  $configPath = Join-Path $root 'profiles.json'
  $data = Get-CodexUsageAllProfiles -ConfigPath $configPath -CodexPath $codexPath
  $payload = [pscustomobject]@{
    ok = $true
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    data = $data
  }
  $json = $payload | ConvertTo-Json -Depth 30
  Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
  Write-WorkerLog 'Worker completed successfully.'
  exit 0
} catch {
  $msg = $_.Exception.Message
  $detail = $_.ScriptStackTrace
  Write-WorkerLog ('ERROR: ' + $msg)
  if (-not [string]::IsNullOrWhiteSpace($detail)) { Write-WorkerLog $detail }
  try {
    $payload = [pscustomobject]@{
      ok = $false
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      error = $msg
      detail = $detail
    }
    $json = $payload | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
  } catch {}
  exit 1
}
