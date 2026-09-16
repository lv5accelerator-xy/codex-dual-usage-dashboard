$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
. (Join-Path $PSScriptRoot 'codex-tools.ps1')
try {
  $existing = Find-CodexCommand
  if (-not [string]::IsNullOrWhiteSpace($existing)) {
    Write-Host ('Codex CLI 已安装: ' + $existing) -ForegroundColor Green
    & $existing --version | Out-Host
  } else {
    $installed = Install-CodexCli
    & $installed --version | Out-Host
  }
  Write-Host ''
  Write-Host '完成。现在可以双击 first-run-setup.bat 登录两个账号。' -ForegroundColor Green
} catch {
  Write-Host ''
  Write-Host ('安装失败: ' + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
