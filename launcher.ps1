$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Join-Path $root 'logs'
$startupLog = Join-Path $logDir 'startup.log'
$errorLog = Join-Path $logDir 'startup-error.log'
$trayLog = Join-Path $logDir 'tray.log'

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

function Normalize-PowerShellFiles {
  $utf8Bom = New-Object System.Text.UTF8Encoding($true)

  foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File) {
    try {
      if ($file.Name -ieq 'launcher.ps1') { continue }

      $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)

      if ($file.Name -ieq 'tray.ps1') {
        $text = $text.Replace('===== v0.3.4 tray starting =====','===== v0.3.7 tray starting =====')
        $text = $text.Replace('===== v0.3.5 tray starting =====','===== v0.3.7 tray starting =====')
        $text = $text.Replace('===== v0.3.6 tray starting =====','===== v0.3.7 tray starting =====')
        $text = $text.Replace('CodexDualUsageTrayV034','CodexDualUsageTray')

        # v0.3.7 layout fix: the scrollable quota area must start below the
        # 58px header. Dock=Fill let the first account card render under the
        # header, which is why the upper half of the Personal card was hidden.
        if ($text -notmatch 'LayoutFixV037') {
          $layoutPattern = '(?ms)^  \$script:ContentPanel = New-Object System\.Windows\.Forms\.Panel\r?\n  \$script:ContentPanel\.Dock = \[System\.Windows\.Forms\.DockStyle\]::Fill\r?\n  \$script:ContentPanel\.AutoScroll = \$true\r?\n  \$script:ContentPanel\.BackColor = \$script:Theme\.PopupBack\r?\n  \$script:Popup\.Controls\.Add\(\$script:ContentPanel\)\r?\n  \$header\.BringToFront\(\)'
          $layoutReplacement = @'
  # LayoutFixV037: keep quota cards physically below the fixed header.
  $script:ContentPanel = New-Object System.Windows.Forms.Panel
  $script:ContentPanel.AutoScroll = $true
  $script:ContentPanel.BackColor = $script:Theme.PopupBack
  $script:ContentPanel.Location = New-Object System.Drawing.Point -ArgumentList 0,58
  $script:ContentPanel.Size = New-Object System.Drawing.Size -ArgumentList 408,562
  $script:ContentPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $script:Popup.Controls.Add($script:ContentPanel)
  $header.BringToFront()
'@
          $patched = [regex]::Replace($text, $layoutPattern, $layoutReplacement)
          if ($patched -eq $text) {
            Write-StartupLog 'layout patch warning: target ContentPanel block was not found.'
          } else {
            $text = $patched
            Write-StartupLog 'v0.3.7 ContentPanel layout patch applied.'
          }
        }

        # Leave enough client height for the header plus both account cards.
        $text = $text.Replace(
          '$totalHeight = [Math]::Max(460, [Math]::Min(760, $top + 74))',
          '$totalHeight = [Math]::Max(520, [Math]::Min(760, $top + 100))'
        )
      }

      [System.IO.File]::WriteAllText($file.FullName, $text, $utf8Bom)
    } catch {
      Write-StartupLog ('normalize warning for ' + $file.Name + ': ' + $_.Exception.Message)
    }
  }
}

function Test-TraySyntax {
  param([string]$Path)

  $tokens = $null
  $parseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

  if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message })
    throw ('tray.ps1 syntax check failed: ' + ($messages -join ' | '))
  }
}

try {
  Write-StartupLog '===== launcher v0.3.7 starting ====='

  Normalize-PowerShellFiles
  Write-StartupLog 'PowerShell source encoding and compatibility fixes applied.'

  $tray = Join-Path $root 'tray.ps1'
  if (-not (Test-Path -LiteralPath $tray)) {
    throw ('tray.ps1 not found: ' + $tray)
  }

  Test-TraySyntax -Path $tray
  Write-StartupLog 'tray.ps1 syntax check passed.'

  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $ps)) { $ps = 'powershell.exe' }

  Remove-Item -LiteralPath $errorLog -Force -ErrorAction SilentlyContinue

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ps
  $psi.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "' + $tray + '"'
  $psi.WorkingDirectory = $root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi

  if (-not $process.Start()) {
    throw 'Failed to start tray process.'
  }

  Write-StartupLog ('tray process created. PID=' + $process.Id)
  Start-Sleep -Milliseconds 1800

  if ($process.HasExited) {
    $detail = ('Tray exited during startup. Exit code: {0}' -f $process.ExitCode)

    if (Test-Path -LiteralPath $trayLog) {
      try {
        $tail = @(Get-Content -LiteralPath $trayLog -Tail 12 -ErrorAction SilentlyContinue)
        if ($tail.Count -gt 0) {
          $detail += "`r`n`r`nLast tray log lines:`r`n" + ($tail -join "`r`n")
        }
      } catch {}
    }

    $detail += "`r`n`r`nSee logs\startup.log and logs\tray.log."
    throw $detail
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
