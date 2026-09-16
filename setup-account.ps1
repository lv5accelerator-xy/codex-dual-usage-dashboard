param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('personal', 'work')]
  [string]$Account,
  [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

. (Join-Path $PSScriptRoot 'codex-tools.ps1')

$label = if ($Account -eq 'personal') { '个人账号' } else { '工作账号' }
$folderName = if ($Account -eq 'personal') { '.codex-personal' } else { '.codex-work' }
$homeDir = Join-Path $env:USERPROFILE $folderName
$authPath = Join-Path $homeDir 'auth.json'
$configPath = Join-Path $homeDir 'config.toml'

function Pause-IfNeeded {
  if (-not $NoPause) {
    Write-Host ''
    [void](Read-Host '按 Enter 键关闭此窗口')
  }
}

function Ensure-FileCredentialStore {
  New-Item -ItemType Directory -Force -Path $homeDir | Out-Null

  $line = 'cli_auth_credentials_store = "file"'
  $text = ''
  if (Test-Path $configPath) {
    $text = [System.IO.File]::ReadAllText($configPath)
  }

  if ($text -match '(?m)^\s*cli_auth_credentials_store\s*=.*$') {
    $text = [System.Text.RegularExpressions.Regex]::Replace(
      $text,
      '(?m)^\s*cli_auth_credentials_store\s*=.*$',
      $line
    )
  } else {
    if (-not [string]::IsNullOrWhiteSpace($text) -and -not $text.EndsWith("`n")) {
      $text += "`r`n"
    }
    $text += $line + "`r`n"
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($configPath, $text, $utf8NoBom)
}

try {
  Write-Host '=============================================' -ForegroundColor DarkGray
  Write-Host (" Codex 双账号额度 - 登录 {0}" -f $label) -ForegroundColor Cyan
  Write-Host '=============================================' -ForegroundColor DarkGray
  Write-Host ''

  if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    throw '无法读取 USERPROFILE，无法创建独立的 Codex 账号目录。'
  }

  $codexCommand = Find-CodexCommand
  if ([string]::IsNullOrWhiteSpace($codexCommand)) {
    $codexCommand = Install-CodexCli
  }

  Ensure-FileCredentialStore
  $env:CODEX_HOME = $homeDir

  Write-Host ("独立账号目录：{0}" -f $homeDir) -ForegroundColor DarkGray
  Write-Host ("Codex：{0}" -f $codexCommand) -ForegroundColor DarkGray
  Write-Host ''

  if (Test-Path $authPath) {
    Write-Host ("检测到【{0}】已有登录信息。" -f $label) -ForegroundColor Yellow
    $answer = Read-Host '是否重新登录/切换账号？输入 Y 继续，其他键取消'
    if ($answer -notmatch '^(?i)y(es)?$') {
      Write-Host '已保留现有登录信息，没有做任何修改。' -ForegroundColor Green
      Pause-IfNeeded
      exit 0
    }

    Write-Host '正在清除这个独立 profile 的旧登录状态…' -ForegroundColor DarkGray
    try {
      & $codexCommand logout | Out-Host
    } catch {
      Write-Host '旧登录状态清理失败，将继续尝试重新登录。' -ForegroundColor Yellow
    }
  }

  Write-Host ("正在登录【{0}】…" -f $label) -ForegroundColor Cyan
  if ($Account -eq 'personal') {
    Write-Host '浏览器打开后，请确认授权的是你的个人 ChatGPT 账号。' -ForegroundColor Yellow
  } else {
    Write-Host '浏览器打开后，请确认授权的是你的工作 ChatGPT 账号 / 工作空间。' -ForegroundColor Yellow
  }
  Write-Host '如果浏览器自动进入了另一个账号，请先在浏览器中切换账号，再完成授权。' -ForegroundColor Yellow
  Write-Host ''

  & $codexCommand login | Out-Host
  $loginExitCode = $LASTEXITCODE
  if ($null -ne $loginExitCode -and $loginExitCode -ne 0) {
    throw ("Codex 登录命令返回错误代码 {0}。" -f $loginExitCode)
  }

  Write-Host ''
  if (Test-Path $authPath) {
    Write-Host ("【{0}】登录成功。" -f $label) -ForegroundColor Green
  } else {
    Write-Host '登录命令已完成，但暂未发现 auth.json。' -ForegroundColor Yellow
    Write-Host '你仍可以启动看板验证；若显示“未连接”，再运行一次此登录程序。' -ForegroundColor Yellow
  }
  Write-Host ("CODEX_HOME = {0}" -f $homeDir) -ForegroundColor DarkGray

  Pause-IfNeeded
  exit 0
} catch {
  Write-Host ''
  Write-Host '登录没有完成。' -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host ''
  Write-Host '这个窗口会保留，不会再直接闪退。请把上面的报错截图发给我即可。' -ForegroundColor Yellow
  Pause-IfNeeded
  exit 1
}
