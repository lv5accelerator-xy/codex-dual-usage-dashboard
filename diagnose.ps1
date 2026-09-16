$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
. (Join-Path $PSScriptRoot 'codex-tools.ps1')

Write-Host '=============================================' -ForegroundColor DarkGray
Write-Host ' Codex 双账号额度 v0.3.3 - 环境诊断' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor DarkGray
Write-Host ''
Write-Host ('Windows: ' + [Environment]::OSVersion.VersionString)
Write-Host ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
Write-Host '[INFO] v0.3.3 不再需要 Node.js。' -ForegroundColor Cyan

$codex = Find-CodexCommand
if (-not [string]::IsNullOrWhiteSpace($codex)) {
  Write-Host ('[OK] Codex: ' + $codex) -ForegroundColor Green
  try { & $codex --version | Out-Host } catch {}
} else {
  Write-Host '[MISSING] Codex CLI' -ForegroundColor Red
}

Write-Host ''
foreach ($item in @(
  @{ Label='个人账号'; Path=(Join-Path $env:USERPROFILE '.codex-personal\auth.json') },
  @{ Label='工作账号'; Path=(Join-Path $env:USERPROFILE '.codex-work\auth.json') }
)) {
  if (Test-Path -LiteralPath $item.Path -PathType Leaf) {
    Write-Host ('[OK] ' + $item.Label + ' 登录文件存在') -ForegroundColor Green
  } else {
    Write-Host ('[MISSING] ' + $item.Label + ' 登录文件') -ForegroundColor Yellow
  }
}

Write-Host ''
Write-Host '说明：本诊断只检查路径、版本和登录文件是否存在，不会显示 token。' -ForegroundColor DarkGray
