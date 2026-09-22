$ErrorActionPreference = 'Stop'

function Convert-WebResponseContentToText {
  param([Parameter(Mandatory = $true)]$Content)

  if ($Content -is [byte[]]) {
    return [System.Text.Encoding]::UTF8.GetString([byte[]]$Content)
  }

  if ($Content -is [System.IO.Stream]) {
    $reader = New-Object System.IO.StreamReader -ArgumentList $Content,[System.Text.Encoding]::UTF8,$true,4096,$true
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
  }

  return [string]$Content
}

function Test-CodexCandidate {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    & $Path --version 2>$null | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Find-CodexCommand {
  foreach ($name in @('codex.exe', 'codex.cmd', 'codex')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
      return [string]$cmd.Source
    }
  }

  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe')
  }
  if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
    $candidates += (Join-Path $env:APPDATA 'npm\codex.cmd')
    $candidates += (Join-Path $env:APPDATA 'npm\codex.exe')
  }
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $candidates += (Join-Path $env:USERPROFILE '.codex\packages\standalone\current\bin\codex.exe')
    $candidates += (Join-Path $env:USERPROFILE '.codex\packages\standalone\current\codex.exe')
  }

  foreach ($candidate in $candidates) {
    if (Test-CodexCandidate $candidate) { return $candidate }
  }

  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    foreach ($extRoot in @(
      (Join-Path $env:USERPROFILE '.vscode\extensions'),
      (Join-Path $env:USERPROFILE '.cursor\extensions')
    )) {
      if (-not (Test-Path -LiteralPath $extRoot -PathType Container)) { continue }
      $patterns = @(
        'openai.chatgpt-*\bin\*\codex.exe',
        'openai.chatgpt-*\bin\codex.exe',
        'openai.codex-*\bin\*\codex.exe',
        'openai.codex-*\bin\codex.exe'
      )
      foreach ($pattern in $patterns) {
        $match = Get-ChildItem -Path (Join-Path $extRoot $pattern) -File -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending |
          Select-Object -First 1
        if ($null -ne $match -and (Test-CodexCandidate $match.FullName)) {
          return [string]$match.FullName
        }
      }
    }
  }

  return $null
}

function Install-CodexCli {
  param([switch]$SkipPrompt)

  if (-not $SkipPrompt) {
    Write-Host ''
    Write-Host '未找到 Codex CLI。' -ForegroundColor Yellow
    Write-Host '新版可以使用 OpenAI 官方 Windows 安装器自动安装。' -ForegroundColor Yellow
    Write-Host '官方安装地址: https://chatgpt.com/codex/install.ps1' -ForegroundColor DarkGray
    $answer = Read-Host '输入 Y 自动安装，其他键取消'
    if ($answer -notmatch '^(?i)y(es)?$') {
      throw '已取消 Codex CLI 安装。'
    }
  }

  Write-Host ''
  Write-Host '正在安装 Codex CLI…' -ForegroundColor Cyan
  Write-Host '下载来源: OpenAI 官方安装器' -ForegroundColor DarkGray

  $oldNonInteractive = $env:CODEX_NON_INTERACTIVE
  $hadCodexHome = Test-Path Env:CODEX_HOME
  $oldCodexHome = $env:CODEX_HOME
  try {
    $env:CODEX_NON_INTERACTIVE = '1'
    if ($hadCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }

    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri 'https://chatgpt.com/codex/install.ps1' -TimeoutSec 60
      $installerScript = Convert-WebResponseContentToText $response.Content
      if ([string]::IsNullOrWhiteSpace($installerScript)) { throw 'OpenAI 官方安装器返回了空内容。' }
      Invoke-Expression $installerScript
    } catch {
      Write-Host ''
      Write-Host ('OpenAI 官方安装器执行失败: ' + $_.Exception.Message) -ForegroundColor Yellow
      $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($null -eq $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1 }
      if ($null -eq $npm) { throw }
      Write-Host '检测到 npm，正在改用 npm 安装 @openai/codex…' -ForegroundColor Cyan
      & $npm.Source install -g '@openai/codex' | Out-Host
      if ($LASTEXITCODE -ne 0) {
        throw ('npm 安装 Codex CLI 失败，错误码 ' + $LASTEXITCODE)
      }
    }
  } finally {
    if ($null -eq $oldNonInteractive) { Remove-Item Env:CODEX_NON_INTERACTIVE -ErrorAction SilentlyContinue }
    else { $env:CODEX_NON_INTERACTIVE = $oldNonInteractive }
    if ($hadCodexHome) { $env:CODEX_HOME = $oldCodexHome }
    else { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
  }

  $codex = Find-CodexCommand
  if ([string]::IsNullOrWhiteSpace($codex)) {
    throw '安装程序已结束，但仍未找到 codex.exe。请关闭后重新打开 first-run-setup.bat。'
  }

  Write-Host ('Codex CLI 已就绪: ' + $codex) -ForegroundColor Green
  return $codex
}
