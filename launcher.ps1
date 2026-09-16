$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Join-Path $root 'logs'
$startupLog = Join-Path $logDir 'startup.log'
$errorLog = Join-Path $logDir 'startup-error.log'
$outputLog = Join-Path $logDir 'startup-output.log'

if (-not (Test-Path -LiteralPath $logDir)) {
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

function Write-StartupLog {
  param([string]$Message)
  try {
    $line = ('[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $startupLog -Value $line -Encoding UTF8
  } catch {}
}

function Show-LaunchError {
  param([string]$Message)
  try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
      $Message,
      'Codex Dual Usage - Startup Error',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
  } catch {}
}

try {
  Write-StartupLog '===== launcher v0.3.5 starting ====='

  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $ps)) { $ps = 'powershell.exe' }

  $tray = Join-Path $root 'tray.ps1'
  if (-not (Test-Path -LiteralPath $tray)) {
    throw ('tray.ps1 not found: ' + $tray)
  }

  Remove-Item -LiteralPath $errorLog -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $outputLog -Force -ErrorAction SilentlyContinue

  $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "' + $tray + '"'
  $process = Start-Process `
    -FilePath $ps `
    -ArgumentList $arguments `
    -WorkingDirectory $root `
    -WindowStyle Hidden `
    -RedirectStandardError $errorLog `
    -RedirectStandardOutput $outputLog `
    -PassThru

  Write-StartupLog ('tray process created. PID=' + $process.Id)
  Start-Sleep -Milliseconds 1800

  if ($process.HasExited) {
    $stderr = ''
    $stdout = ''
    try { if (Test-Path -LiteralPath $errorLog) { $stderr = Get-Content -LiteralPath $errorLog -Raw -ErrorAction SilentlyContinue } } catch {}
    try { if (Test-Path -LiteralPath $outputLog) { $stdout = Get-Content -LiteralPath $outputLog -Raw -ErrorAction SilentlyContinue } } catch {}

    $detail = ('Tray exited during startup. Exit code: {0}' -f $process.ExitCode)
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { $detail += "`r`n`r`n" + $stderr.Trim() }
    elseif (-not [string]::IsNullOrWhiteSpace($stdout)) { $detail += "`r`n`r`n" + $stdout.Trim() }
    $detail += "`r`n`r`nSee logs\startup-error.log and logs\tray.log."

    Write-StartupLog $detail
    Show-LaunchError $detail
    exit 1
  }

  Write-StartupLog 'tray process survived startup check.'
  exit 0
} catch {
  $message = $_.Exception.ToString()
  Write-StartupLog ('FATAL: ' + $message)
  try { Set-Content -LiteralPath $errorLog -Value $message -Encoding UTF8 } catch {}
  Show-LaunchError ($message + "`r`n`r`nSee logs\startup-error.log.")
  exit 1
}
