$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
. (Join-Path $PSScriptRoot 'codex-tools.ps1')
. (Join-Path $PSScriptRoot 'usage-reader.ps1')

Write-Host '=============================================' -ForegroundColor DarkGray
Write-Host ' Codex 双账号额度 v0.3.3 - 读取测试' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor DarkGray
Write-Host ''

$codex = Find-CodexCommand
if ([string]::IsNullOrWhiteSpace($codex)) {
  throw '未找到 Codex CLI。请先运行 first-run-setup.bat。'
}
Write-Host ('Codex: ' + $codex) -ForegroundColor DarkGray
Write-Host ''

$data = Get-CodexUsageAllProfiles -ConfigPath (Join-Path $PSScriptRoot 'profiles.json') -CodexPath $codex
foreach ($p in @($data.profiles)) {
  Write-Host ('[' + $p.label + ']') -ForegroundColor Yellow
  if (-not $p.ok) {
    Write-Host ('读取失败: ' + $p.error) -ForegroundColor Red
    Write-Host ''
    continue
  }
  Write-Host ('套餐: ' + $p.planType)
  if ($null -ne $p.individualLimit) {
    Write-Host ('月度额度: 剩余 ' + $p.individualLimit.remainingPercent + '% | ' + $p.individualLimit.used + ' / ' + $p.individualLimit.limit)
  }
  if ($null -ne $p.fiveHour) {
    Write-Host ('5小时: 剩余 ' + $p.fiveHour.remainingPercent + '% | 重置 ' + $p.fiveHour.resetsAt)
  } else {
    Write-Host '5小时: 当前账号未返回此窗口' -ForegroundColor DarkYellow
  }
  if ($null -ne $p.weekly) {
    Write-Host ('每周: 剩余 ' + $p.weekly.remainingPercent + '% | 重置 ' + $p.weekly.resetsAt)
  } else {
    Write-Host '每周: 当前账号未返回此窗口' -ForegroundColor DarkYellow
  }
  Write-Host ''
}
