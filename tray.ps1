$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogDir = Join-Path $script:Root 'logs'
$script:TrayLog = Join-Path $script:LogDir 'tray.log'
$script:WorkerLog = Join-Path $script:LogDir 'worker.log'
$script:CachePath = Join-Path $script:LogDir 'usage-result.json'
$script:UiSettingsPath = Join-Path $script:Root 'ui-settings.json'
$script:WorkerProcess = $null
$script:RefreshPending = $false
$script:RefreshSilent = $false
$script:LastData = $null
$script:Exiting = $false
$script:Mutex = $null
$script:AppContext = $null
$script:Popup = $null
$script:Ball = $null
$script:NotifyIcon = $null
$script:ContentPanel = $null
$script:StatusLabel = $null
$script:RefreshButton = $null
$script:BallPersonalLabel = $null
$script:BallWorkLabel = $null
$script:BallAccent = $null
$script:BallMouseDown = $null
$script:BallOrigin = $null
$script:BallDragged = $false
$script:UiSettings = $null
$script:Theme = @{}

if (-not (Test-Path -LiteralPath $script:LogDir)) {
  New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
}

function Write-TrayLog {
  param([string]$Message)
  try {
    $line = ('[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $script:TrayLog -Value $line -Encoding UTF8
  } catch {}
}

function Show-FatalError {
  param([string]$Message)
  Write-TrayLog ('FATAL: ' + $Message)
  try {
    [System.Windows.Forms.MessageBox]::Show(
      ($Message + "`r`n`r`n日志：" + $script:TrayLog),
      'Codex 双账号额度 - 启动失败',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
  } catch {}
}

try {
  Write-TrayLog '===== v0.3.8 tray starting ====='
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [System.Windows.Forms.Application]::EnableVisualStyles()

  $createdNew = $false
  $script:Mutex = New-Object System.Threading.Mutex($true, 'CodexDualUsageTray', [ref]$createdNew)
  if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
      'Codex 双账号额度已经在运行。请检查桌面悬浮球或任务栏右下角图标。',
      'Codex 双账号额度',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
  }

  $script:Theme = @{
    PopupBack = [System.Drawing.Color]::FromArgb(8,16,25)
    HeaderBack = [System.Drawing.Color]::FromArgb(12,27,43)
    CardBack = [System.Drawing.Color]::FromArgb(15,31,48)
    CardBorder = [System.Drawing.Color]::FromArgb(42,83,118)
    TextPrimary = [System.Drawing.Color]::FromArgb(235,243,251)
    TextMuted = [System.Drawing.Color]::FromArgb(124,153,181)
    Cyan = [System.Drawing.Color]::FromArgb(0,214,255)
    CyanSoft = [System.Drawing.Color]::FromArgb(111,228,255)
    Danger = [System.Drawing.Color]::FromArgb(255,92,92)
    Warning = [System.Drawing.Color]::FromArgb(255,177,66)
    Good = [System.Drawing.Color]::FromArgb(0,208,132)
    Track = [System.Drawing.Color]::FromArgb(35,56,76)
    ButtonBack = [System.Drawing.Color]::FromArgb(20,42,65)
    ButtonBorder = [System.Drawing.Color]::FromArgb(62,120,168)
    BallBack = [System.Drawing.Color]::FromArgb(11,25,40)
  }
  $script:BallAccent = $script:Theme.Cyan

  function New-UiFont {
    param(
      [string]$FamilyName,
      [single]$Size,
      [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )

    try {
      $ctor = [System.Drawing.Font].GetConstructor([Type[]]@(
        [string],
        [single],
        [System.Drawing.FontStyle],
        [System.Drawing.GraphicsUnit]
      ))
      if ($null -eq $ctor) { throw '找不到 System.Drawing.Font 的目标构造函数。' }
      return [System.Drawing.Font]$ctor.Invoke(@(
        [string]$FamilyName,
        [single]$Size,
        [System.Drawing.FontStyle]$Style,
        [System.Drawing.GraphicsUnit]::Point
      ))
    } catch {
      Write-TrayLog ('Font fallback: ' + $_.Exception.Message)
      return [System.Drawing.SystemFonts]::MessageBoxFont
    }
  }

  function Get-DefaultUiSettings {
    return [ordered]@{
      ballX = $null
      ballY = $null
      panelX = $null
      panelY = $null
      panelWidth = 430
      panelHeight = 640
      topMost = $true
      ballVisible = $true
    }
  }

  function Load-UiSettings {
    $settings = Get-DefaultUiSettings
    if (Test-Path -LiteralPath $script:UiSettingsPath) {
      try {
        $loaded = Get-Content -LiteralPath $script:UiSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @('ballX','ballY','panelX','panelY','panelWidth','panelHeight','topMost','ballVisible')) {
          if ($loaded.PSObject.Properties.Name -contains $key) {
            $settings[$key] = $loaded.$key
          }
        }
      } catch {
        Write-TrayLog ('UI settings load warning: ' + $_.Exception.Message)
      }
    }
    return $settings
  }

  function Save-UiSettings {
    try {
      if ($null -ne $script:Ball) {
        $script:UiSettings.ballX = $script:Ball.Left
        $script:UiSettings.ballY = $script:Ball.Top
        $script:UiSettings.ballVisible = $script:Ball.Visible
      }
      if ($null -ne $script:Popup) {
        $script:UiSettings.panelX = $script:Popup.Left
        $script:UiSettings.panelY = $script:Popup.Top
        $script:UiSettings.panelWidth = $script:Popup.Width
        $script:UiSettings.panelHeight = $script:Popup.Height
        $script:UiSettings.topMost = $script:Popup.TopMost
      }
      ([pscustomobject]$script:UiSettings) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:UiSettingsPath -Encoding UTF8
    } catch {
      Write-TrayLog ('UI settings save warning: ' + $_.Exception.Message)
    }
  }

  function Clamp-Location {
    param(
      [int]$X,
      [int]$Y,
      [int]$Width,
      [int]$Height
    )
    $point = New-Object System.Drawing.Point -ArgumentList $X,$Y
    $area = [System.Windows.Forms.Screen]::FromPoint($point).WorkingArea
    $maxX = [Math]::Max($area.Left, $area.Right - $Width)
    $maxY = [Math]::Max($area.Top, $area.Bottom - $Height)
    $safeX = [Math]::Max($area.Left, [Math]::Min($maxX, $X))
    $safeY = [Math]::Max($area.Top, [Math]::Min($maxY, $Y))
    return (New-Object System.Drawing.Point -ArgumentList $safeX,$safeY)
  }

  function Get-DefaultBallLocation {
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    return (New-Object System.Drawing.Point -ArgumentList ($area.Right - 118),($area.Bottom - 180))
  }

  function Get-DefaultPanelLocation {
    param([int]$Width,[int]$Height)
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $area.Right - $Width - 24
    $y = [Math]::Max($area.Top + 24, $area.Bottom - $Height - 24)
    return (New-Object System.Drawing.Point -ArgumentList $x,$y)
  }

  function Format-Percent {
    param($Value)
    if ($null -eq $Value) { return '—' }
    try { return ('{0:0}%' -f [double]$Value) } catch { return '—' }
  }

  function Get-ResetText {
    param([string]$Iso)
    if ([string]::IsNullOrWhiteSpace($Iso)) { return '暂无重置时间' }
    try {
      $target = [DateTimeOffset]::Parse($Iso).ToLocalTime()
      $span = $target - [DateTimeOffset]::Now
      if ($span.TotalSeconds -le 0) { return '即将重置' }
      if ($span.TotalDays -ge 1) { return ('{0}天 {1}小时 后重置' -f [Math]::Floor($span.TotalDays), $span.Hours) }
      if ($span.TotalHours -ge 1) { return ('{0}小时 {1}分钟 后重置' -f [Math]::Floor($span.TotalHours), $span.Minutes) }
      return ('{0}分钟 后重置' -f [Math]::Max(1, [Math]::Floor($span.TotalMinutes)))
    } catch { return '暂无重置时间' }
  }

  function Get-BarColor {
    param($Remaining)
    if ($null -eq $Remaining) { return $script:Theme.Track }
    $n = [double]$Remaining
    if ($n -le 15) { return $script:Theme.Danger }
    if ($n -le 35) { return $script:Theme.Warning }
    return $script:Theme.Good
  }

  function Get-ProfileMinimum {
    param($Profile)
    if ($null -eq $Profile -or -not $Profile.ok) { return $null }
    $values = @()
    foreach ($window in @($Profile.fiveHour,$Profile.weekly)) {
      if ($null -ne $window -and $null -ne $window.remainingPercent) {
        $values += [double]$window.remainingPercent
      }
    }
    if ($null -ne $Profile.individualLimit -and $null -ne $Profile.individualLimit.remainingPercent) {
      $limitIsMeaningful = $true
      if ($null -ne $Profile.individualLimit.limit) {
        try { $limitIsMeaningful = ([double]$Profile.individualLimit.limit -gt 0) } catch {}
      }
      if ($limitIsMeaningful) {
        $values += [double]$Profile.individualLimit.remainingPercent
      }
    }
    if ($values.Count -eq 0) { return $null }
    return [double](($values | Measure-Object -Minimum).Minimum)
  }

  function Update-BallSummary {
    param($Data)
    if ($null -eq $script:BallPersonalLabel -or $null -eq $script:BallWorkLabel) { return }

    $profiles = @($Data.profiles)
    $personal = $null
    $work = $null
    if ($profiles.Count -gt 0) { $personal = Get-ProfileMinimum $profiles[0] }
    if ($profiles.Count -gt 1) { $work = Get-ProfileMinimum $profiles[1] }

    $pText = if ($null -eq $personal) { '--' } else { ('{0:0}%' -f $personal) }
    $wText = if ($null -eq $work) { '--' } else { ('{0:0}%' -f $work) }
    $script:BallPersonalLabel.Text = 'P ' + $pText
    $script:BallWorkLabel.Text = 'W ' + $wText

    $all = @()
    if ($null -ne $personal) { $all += $personal }
    if ($null -ne $work) { $all += $work }
    if ($all.Count -eq 0) {
      $script:BallAccent = $script:Theme.Cyan
    } else {
      $min = [double](($all | Measure-Object -Minimum).Minimum)
      $script:BallAccent = Get-BarColor $min
    }
    try { $script:Ball.Invalidate() } catch {}
  }

  function Clear-Content {
    $script:ContentPanel.SuspendLayout()
    try {
      while ($script:ContentPanel.Controls.Count -gt 0) {
        $control = $script:ContentPanel.Controls[0]
        $script:ContentPanel.Controls.RemoveAt(0)
        try { $control.Dispose() } catch {}
      }
    } finally {
      $script:ContentPanel.ResumeLayout($true)
    }
  }

  function Add-QuotaRow {
    param(
      [System.Windows.Forms.Control]$Parent,
      [string]$Title,
      $Window,
      [int]$Y,
      [string]$Detail = ''
    )

    $rowWidth = [Math]::Max(300, $Parent.ClientSize.Width - 28)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point -ArgumentList 14,$Y
    $titleLabel.Font = New-UiFont -FamilyName 'Segoe UI Semibold' -Size ([single]9.3) -Style ([System.Drawing.FontStyle]::Regular)
    $titleLabel.ForeColor = $script:Theme.TextPrimary
    $Parent.Controls.Add($titleLabel)

    $pct = New-Object System.Windows.Forms.Label
    $pct.AutoSize = $false
    $pct.Size = New-Object System.Drawing.Size -ArgumentList 84,22
    $pct.Location = New-Object System.Drawing.Point -ArgumentList ($Parent.ClientSize.Width - 98),($Y-3)
    $pct.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $pct.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $pct.Font = New-UiFont -FamilyName 'Segoe UI Semibold' -Size ([single]10.5) -Style ([System.Drawing.FontStyle]::Regular)
    $pct.ForeColor = $script:Theme.CyanSoft
    $Parent.Controls.Add($pct)

    $track = New-Object System.Windows.Forms.Panel
    $track.Location = New-Object System.Drawing.Point -ArgumentList 14,($Y+27)
    $track.Size = New-Object System.Drawing.Size -ArgumentList $rowWidth,7
    $track.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $track.BackColor = $script:Theme.Track
    $Parent.Controls.Add($track)

    $fill = New-Object System.Windows.Forms.Panel
    $fill.Location = New-Object System.Drawing.Point -ArgumentList 0,0
    $fill.Height = 7
    $track.Controls.Add($fill)

    $reset = New-Object System.Windows.Forms.Label
    $reset.AutoSize = $false
    $reset.Size = New-Object System.Drawing.Size -ArgumentList $rowWidth,18
    $reset.Location = New-Object System.Drawing.Point -ArgumentList 14,($Y+39)
    $reset.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $reset.ForeColor = $script:Theme.TextMuted
    $reset.Font = New-UiFont -FamilyName 'Microsoft YaHei UI' -Size ([single]8.1) -Style ([System.Drawing.FontStyle]::Regular)
    $Parent.Controls.Add($reset)

    if ($null -eq $Window) {
      $pct.Text = '—'
      $fill.Width = 0
      $track.Tag = [double]0
      $reset.Text = '当前账号未返回此额度窗口'
    } else {
      $remaining = $Window.remainingPercent
      $pct.Text = Format-Percent $remaining
      $safe = 0.0
      if ($null -ne $remaining) {
        $safe = [Math]::Max(0,[Math]::Min(100,[double]$remaining))
      }
      $track.Tag = [double]$safe
      $fill.Width = [int][Math]::Round($track.ClientSize.Width * $safe / 100)
      $fill.BackColor = Get-BarColor $remaining
      $resetText = Get-ResetText ([string]$Window.resetsAt)
      if ([string]::IsNullOrWhiteSpace($Detail)) { $reset.Text = $resetText }
      else { $reset.Text = $Detail + ' · ' + $resetText }
    }

    $track.Add_SizeChanged({
      param($sender,$eventArgs)
      try {
        if ($sender.Controls.Count -gt 0) {
          $ratio = [double]$sender.Tag
          $sender.Controls[0].Width = [int][Math]::Round($sender.ClientSize.Width * $ratio / 100)
        }
      } catch {}
    })
  }

  function Add-AccountCard {
    param($Profile,[int]$Top)

    $hasMonthly = $null -ne $Profile.individualLimit
    $height = if ($hasMonthly) { 226 } else { 168 }
    $cardWidth = [Math]::Max(340, $script:ContentPanel.ClientSize.Width - 24)

    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point -ArgumentList 12,$Top
    $card.Size = New-Object System.Drawing.Size -ArgumentList $cardWidth,$height
    $card.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $card.BackColor = $script:Theme.CardBack
    $card.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $card.Add_Paint({
      param($sender,$eventArgs)
      $rect = New-Object System.Drawing.Rectangle -ArgumentList 0,0,($sender.Width - 1),($sender.Height - 1)
      $pen = New-Object System.Drawing.Pen -ArgumentList $script:Theme.CardBorder,([single]1.0)
      $eventArgs.Graphics.DrawRectangle($pen,$rect)
      $pen.Dispose()
    })
    $script:ContentPanel.Controls.Add($card)

    $name = New-Object System.Windows.Forms.Label
    $name.AutoSize = $true
    $name.Location = New-Object System.Drawing.Point -ArgumentList 13,10
    $name.Font = New-UiFont -FamilyName 'Segoe UI Semibold' -Size ([single]10.4) -Style ([System.Drawing.FontStyle]::Regular)
    $name.ForeColor = $script:Theme.TextPrimary
    $name.Text = [string]$Profile.label
    $card.Controls.Add($name)

    $plan = New-Object System.Windows.Forms.Label
    $plan.AutoSize = $false
    $plan.Size = New-Object System.Drawing.Size -ArgumentList 170,22
    $plan.Location = New-Object System.Drawing.Point -ArgumentList ($card.ClientSize.Width - 184),7
    $plan.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $plan.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $plan.ForeColor = $script:Theme.TextMuted
    $plan.Font = New-UiFont -FamilyName 'Consolas' -Size ([single]8.5) -Style ([System.Drawing.FontStyle]::Regular)
    $plan.Text = if ($Profile.ok) { [string]$Profile.planType } else { '读取失败' }
    $card.Controls.Add($plan)

    if (-not $Profile.ok) {
      $err = New-Object System.Windows.Forms.Label
      $err.AutoSize = $false
      $err.Location = New-Object System.Drawing.Point -ArgumentList 14,43
      $err.Size = New-Object System.Drawing.Size -ArgumentList ($card.ClientSize.Width - 28),105
      $err.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
      $err.ForeColor = $script:Theme.Danger
      $err.Font = New-UiFont -FamilyName 'Microsoft YaHei UI' -Size ([single]8.5) -Style ([System.Drawing.FontStyle]::Regular)
      $err.Text = ([string]$Profile.error) + "`r`n`r`n右键悬浮球或托盘图标可以重新登录此账号。"
      $card.Controls.Add($err)
      return $height
    }

    if ($hasMonthly) {
      $detail = ''
      if ($null -ne $Profile.individualLimit.used -and $null -ne $Profile.individualLimit.limit) {
        $detail = ('已使用 {0} / {1}' -f $Profile.individualLimit.used,$Profile.individualLimit.limit)
      }
      $monthlyTitle = if ([string]$Profile.planType -match 'business|team|enterprise|edu') { '工作空间每月额度上限' } else { '月度额度上限' }
      Add-QuotaRow -Parent $card -Title $monthlyTitle -Window $Profile.individualLimit -Y 38 -Detail $detail
      Add-QuotaRow -Parent $card -Title '5 小时限额' -Window $Profile.fiveHour -Y 98
      Add-QuotaRow -Parent $card -Title '每周限额' -Window $Profile.weekly -Y 158
    } else {
      Add-QuotaRow -Parent $card -Title '5 小时限额' -Window $Profile.fiveHour -Y 38
      Add-QuotaRow -Parent $card -Title '每周限额' -Window $Profile.weekly -Y 98
    }
    return $height
  }

  function Render-Error {
    param([string]$Message)
    Clear-Content
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.Location = New-Object System.Drawing.Point -ArgumentList 16,24
    $label.Size = New-Object System.Drawing.Size -ArgumentList ([Math]::Max(320,$script:ContentPanel.ClientSize.Width - 32)),180
    $label.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $label.ForeColor = $script:Theme.Danger
    $label.Font = New-UiFont -FamilyName 'Microsoft YaHei UI' -Size ([single]9) -Style ([System.Drawing.FontStyle]::Regular)
    $label.Text = "读取额度失败：`r`n`r`n" + $Message + "`r`n`r`n程序会继续运行。你可以右键悬浮球重新登录或再次刷新。"
    $script:ContentPanel.Controls.Add($label)
    $script:StatusLabel.Text = '读取失败 · ' + (Get-Date).ToString('HH:mm:ss')
  }

  function Render-Data {
    param($Data)
    Clear-Content
    $profiles = @($Data.profiles)
    $top = 10
    foreach ($profile in $profiles) {
      $height = Add-AccountCard -Profile $profile -Top $top
      $top += $height + 10
    }
    if ($profiles.Count -eq 0) {
      Render-Error 'profiles.json 中没有账号配置。'
      return
    }
    $script:ContentPanel.AutoScrollMinSize = New-Object System.Drawing.Size -ArgumentList 0,($top + 10)
    $script:StatusLabel.Text = '更新：' + (Get-Date).ToString('HH:mm:ss')
    Update-BallSummary $Data

    $allRemaining = @()
    foreach ($profile in $profiles) {
      $minimum = Get-ProfileMinimum $profile
      if ($null -ne $minimum) { $allRemaining += [double]$minimum }
    }
    if ($allRemaining.Count -gt 0) {
      $min = [double](($allRemaining | Measure-Object -Minimum).Minimum)
      $text = 'Codex 额度 · 最低剩余 ' + (Format-Percent $min)
      if ($text.Length -gt 63) { $text = $text.Substring(0,63) }
      $script:NotifyIcon.Text = $text
    } else {
      $script:NotifyIcon.Text = 'Codex 双账号额度'
    }
  }

  function Show-Loading {
    Clear-Content
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.Location = New-Object System.Drawing.Point -ArgumentList 16,28
    $label.Size = New-Object System.Drawing.Size -ArgumentList ([Math]::Max(320,$script:ContentPanel.ClientSize.Width - 32)),90
    $label.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $label.ForeColor = $script:Theme.TextMuted
    $label.Font = New-UiFont -FamilyName 'Microsoft YaHei UI' -Size ([single]9) -Style ([System.Drawing.FontStyle]::Regular)
    $label.Text = "正在后台读取个人账号和工作账号额度…`r`n完成后悬浮球会自动更新。"
    $script:ContentPanel.Controls.Add($label)
  }

  function Start-Refresh {
    param([switch]$Silent)
    if ($script:RefreshPending) { return }
    $script:RefreshPending = $true
    $script:RefreshSilent = $Silent.IsPresent
    $script:RefreshButton.Enabled = $false
    $script:RefreshButton.Text = '读取中'
    if ($Silent.IsPresent) {
      $script:StatusLabel.Text = '后台刷新…'
    } else {
      $script:StatusLabel.Text = '正在读取…'
      if ($null -eq $script:LastData) { Show-Loading }
    }
    try { Remove-Item -LiteralPath $script:CachePath -Force -ErrorAction SilentlyContinue } catch {}

    try {
      $worker = Join-Path $script:Root 'usage-worker.ps1'
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
      if (-not (Test-Path -LiteralPath $psi.FileName)) { $psi.FileName = 'powershell.exe' }
      $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutputPath "{1}" -LogPath "{2}"' -f $worker,$script:CachePath,$script:WorkerLog)
      $psi.WorkingDirectory = $script:Root
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
      $script:WorkerProcess = New-Object System.Diagnostics.Process
      $script:WorkerProcess.StartInfo = $psi
      if (-not $script:WorkerProcess.Start()) { throw '无法启动后台额度读取进程。' }
      Write-TrayLog ('Refresh worker PID: ' + $script:WorkerProcess.Id)
    } catch {
      $script:RefreshPending = $false
      $script:RefreshButton.Enabled = $true
      $script:RefreshButton.Text = '刷新'
      if ($script:RefreshSilent -and $null -ne $script:LastData) {
        $script:StatusLabel.Text = '自动刷新失败 · 保留旧数据'
        Write-TrayLog ('Silent refresh start error: ' + $_.Exception.Message)
      } else {
        Render-Error $_.Exception.Message
      }
    }
  }

  function Finish-RefreshIfReady {
    if (-not $script:RefreshPending) { return }
    if ($null -eq $script:WorkerProcess) { return }
    if (-not $script:WorkerProcess.HasExited) { return }

    $exitCode = $script:WorkerProcess.ExitCode
    try { $script:WorkerProcess.Dispose() } catch {}
    $script:WorkerProcess = $null
    $script:RefreshPending = $false
    $script:RefreshButton.Enabled = $true
    $script:RefreshButton.Text = '刷新'

    try {
      if (-not (Test-Path -LiteralPath $script:CachePath)) {
        throw ('后台读取进程已结束，但没有生成结果文件。退出码：{0}。请查看 logs\worker.log。' -f $exitCode)
      }
      $payload = Get-Content -LiteralPath $script:CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
      if (-not $payload.ok) { throw ([string]$payload.error) }
      $script:LastData = $payload.data
      Render-Data $script:LastData
      Write-TrayLog 'Refresh result rendered.'
    } catch {
      Write-TrayLog ('Refresh render error: ' + $_.Exception.Message)
      if ($script:RefreshSilent -and $null -ne $script:LastData) {
        $script:StatusLabel.Text = '自动刷新失败 · 保留旧数据'
      } else {
        Render-Error $_.Exception.Message
      }
    }
  }

  function Toggle-Popup {
    if ($script:Popup.Visible) {
      $script:Popup.Hide()
      Save-UiSettings
    } else {
      $script:Popup.Show()
      $script:Popup.Activate()
    }
  }

  function Start-Login {
    param([string]$Account)
    $fileName = if ($Account -eq 'personal') { 'login-personal.bat' } else { 'login-work.bat' }
    $path = Join-Path $script:Root $fileName
    if (-not (Test-Path -LiteralPath $path)) {
      [System.Windows.Forms.MessageBox]::Show('未找到登录文件：' + $path,'Codex 双账号额度') | Out-Null
      return
    }
    Start-Process -FilePath $path -WorkingDirectory $script:Root | Out-Null
  }

  function Reset-UiPositions {
    $ballLocation = Get-DefaultBallLocation
    $script:Ball.Location = $ballLocation
    $panelLocation = Get-DefaultPanelLocation -Width $script:Popup.Width -Height $script:Popup.Height
    $script:Popup.Location = $panelLocation
    Save-UiSettings
  }

  function Exit-App {
    if ($script:Exiting) { return }
    $script:Exiting = $true
    Write-TrayLog 'Exiting tray.'
    Save-UiSettings
    try { $script:PollTimer.Stop() } catch {}
    try { $script:PeriodicTimer.Stop() } catch {}
    try { $script:InitialTimer.Stop() } catch {}
    try { if ($null -ne $script:WorkerProcess -and -not $script:WorkerProcess.HasExited) { $script:WorkerProcess.Kill() } } catch {}
    try { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() } catch {}
    try { $script:Popup.Hide(); $script:Popup.Dispose() } catch {}
    try { $script:Ball.Hide(); $script:Ball.Dispose() } catch {}
    try { if ($null -ne $script:Mutex) { $script:Mutex.ReleaseMutex() | Out-Null; $script:Mutex.Dispose() } } catch {}
    try { $script:AppContext.ExitThread() } catch {}
  }

  $script:UiSettings = Load-UiSettings

  $script:Popup = New-Object System.Windows.Forms.Form
  $script:Popup.Text = 'Codex 额度 · 个人 + 工作'
  $script:Popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::SizableToolWindow
  $script:Popup.ShowInTaskbar = $false
  $script:Popup.TopMost = [bool]$script:UiSettings.topMost
  $script:Popup.BackColor = $script:Theme.PopupBack
  $script:Popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $script:Popup.MinimumSize = New-Object System.Drawing.Size -ArgumentList 380,360
  $panelWidth = [Math]::Max(380,[int]$script:UiSettings.panelWidth)
  $panelHeight = [Math]::Max(360,[int]$script:UiSettings.panelHeight)
  $script:Popup.Size = New-Object System.Drawing.Size -ArgumentList $panelWidth,$panelHeight

  if ($null -ne $script:UiSettings.panelX -and $null -ne $script:UiSettings.panelY) {
    $popupPoint = Clamp-Location -X ([int]$script:UiSettings.panelX) -Y ([int]$script:UiSettings.panelY) -Width $panelWidth -Height $panelHeight
  } else {
    $popupPoint = Get-DefaultPanelLocation -Width $panelWidth -Height $panelHeight
  }
  $script:Popup.Location = $popupPoint

  $rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
  $rootLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
  $rootLayout.RowCount = 2
  $rootLayout.ColumnCount = 1
  $rootLayout.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0
  $rootLayout.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 0
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute),([single]62)))
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]100)))
  [void]$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]100)))
  $script:Popup.Controls.Add($rootLayout)

  $header = New-Object System.Windows.Forms.Panel
  $header.Dock = [System.Windows.Forms.DockStyle]::Fill
  $header.BackColor = $script:Theme.HeaderBack
  $rootLayout.Controls.Add($header,0,0)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = 'Codex Dual Usage  ·  FLOAT'
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point -ArgumentList 15,10
  $title.Font = New-UiFont -FamilyName 'Segoe UI Semibold' -Size ([single]11.4) -Style ([System.Drawing.FontStyle]::Regular)
  $title.ForeColor = $script:Theme.TextPrimary
  $header.Controls.Add($title)

  $script:StatusLabel = New-Object System.Windows.Forms.Label
  $script:StatusLabel.Text = '悬浮球已启动 · 等待首次读取'
  $script:StatusLabel.AutoSize = $true
  $script:StatusLabel.Location = New-Object System.Drawing.Point -ArgumentList 16,38
  $script:StatusLabel.ForeColor = $script:Theme.TextMuted
  $script:StatusLabel.Font = New-UiFont -FamilyName 'Segoe UI' -Size ([single]8.1) -Style ([System.Drawing.FontStyle]::Regular)
  $header.Controls.Add($script:StatusLabel)

  $script:RefreshButton = New-Object System.Windows.Forms.Button
  $script:RefreshButton.Text = '刷新'
  $script:RefreshButton.Size = New-Object System.Drawing.Size -ArgumentList 72,30
  $script:RefreshButton.Location = New-Object System.Drawing.Point -ArgumentList ($header.ClientSize.Width - 88),16
  $script:RefreshButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $script:RefreshButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $script:RefreshButton.BackColor = $script:Theme.ButtonBack
  $script:RefreshButton.ForeColor = $script:Theme.TextPrimary
  $script:RefreshButton.FlatAppearance.BorderColor = $script:Theme.ButtonBorder
  $script:RefreshButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(28,56,84)
  $script:RefreshButton.Add_Click({ Start-Refresh })
  $header.Controls.Add($script:RefreshButton)

  $script:ContentPanel = New-Object System.Windows.Forms.Panel
  $script:ContentPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
  $script:ContentPanel.AutoScroll = $true
  $script:ContentPanel.BackColor = $script:Theme.PopupBack
  $rootLayout.Controls.Add($script:ContentPanel,0,1)

  $script:Popup.Add_LocationChanged({
    if (-not $script:Exiting) {
      $script:UiSettings.panelX = $script:Popup.Left
      $script:UiSettings.panelY = $script:Popup.Top
    }
  })
  $script:Popup.Add_Resize({
    if (-not $script:Exiting -and $script:Popup.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
      $script:UiSettings.panelWidth = $script:Popup.Width
      $script:UiSettings.panelHeight = $script:Popup.Height
    }
  })
  $script:Popup.Add_ResizeEnd({ Save-UiSettings })
  $script:Popup.Add_FormClosing({
    param($sender,$eventArgs)
    if (-not $script:Exiting -and $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
      $eventArgs.Cancel = $true
      $script:Popup.Hide()
      Save-UiSettings
    }
  })

  $script:Ball = New-Object System.Windows.Forms.Form
  $script:Ball.Text = 'Codex Usage'
  $script:Ball.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $script:Ball.ShowInTaskbar = $false
  $script:Ball.TopMost = [bool]$script:UiSettings.topMost
  $script:Ball.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $script:Ball.Size = New-Object System.Drawing.Size -ArgumentList 92,92
  $script:Ball.BackColor = $script:Theme.BallBack
  $script:Ball.Opacity = 0.96

  if ($null -ne $script:UiSettings.ballX -and $null -ne $script:UiSettings.ballY) {
    $ballPoint = Clamp-Location -X ([int]$script:UiSettings.ballX) -Y ([int]$script:UiSettings.ballY) -Width 92 -Height 92
  } else {
    $ballPoint = Get-DefaultBallLocation
  }
  $script:Ball.Location = $ballPoint

  $setBallRegion = {
    try {
      $path = New-Object System.Drawing.Drawing2D.GraphicsPath
      $path.AddEllipse(0,0,($script:Ball.ClientSize.Width - 1),($script:Ball.ClientSize.Height - 1))
      $region = New-Object System.Drawing.Region($path)
      $script:Ball.Region = $region
      $path.Dispose()
    } catch {}
  }
  & $setBallRegion
  $script:Ball.Add_Resize($setBallRegion)
  $script:Ball.Add_Paint({
    param($sender,$eventArgs)
    try {
      $eventArgs.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $pen = New-Object System.Drawing.Pen -ArgumentList $script:BallAccent,([single]3.0)
      $eventArgs.Graphics.DrawEllipse($pen,2,2,($sender.ClientSize.Width - 5),($sender.ClientSize.Height - 5))
      $pen.Dispose()
    } catch {}
  })

  $script:BallPersonalLabel = New-Object System.Windows.Forms.Label
  $script:BallPersonalLabel.Text = 'P --'
  $script:BallPersonalLabel.AutoSize = $false
  $script:BallPersonalLabel.Size = New-Object System.Drawing.Size -ArgumentList 78,22
  $script:BallPersonalLabel.Location = New-Object System.Drawing.Point -ArgumentList 7,17
  $script:BallPersonalLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $script:BallPersonalLabel.ForeColor = $script:Theme.TextPrimary
  $script:BallPersonalLabel.BackColor = [System.Drawing.Color]::Transparent
  $script:BallPersonalLabel.Font = New-UiFont -FamilyName 'Consolas' -Size ([single]10) -Style ([System.Drawing.FontStyle]::Bold)
  $script:Ball.Controls.Add($script:BallPersonalLabel)

  $script:BallWorkLabel = New-Object System.Windows.Forms.Label
  $script:BallWorkLabel.Text = 'W --'
  $script:BallWorkLabel.AutoSize = $false
  $script:BallWorkLabel.Size = New-Object System.Drawing.Size -ArgumentList 78,22
  $script:BallWorkLabel.Location = New-Object System.Drawing.Point -ArgumentList 7,39
  $script:BallWorkLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $script:BallWorkLabel.ForeColor = $script:Theme.CyanSoft
  $script:BallWorkLabel.BackColor = [System.Drawing.Color]::Transparent
  $script:BallWorkLabel.Font = New-UiFont -FamilyName 'Consolas' -Size ([single]10) -Style ([System.Drawing.FontStyle]::Bold)
  $script:Ball.Controls.Add($script:BallWorkLabel)

  $ballCaption = New-Object System.Windows.Forms.Label
  $ballCaption.Text = 'CODEX'
  $ballCaption.AutoSize = $false
  $ballCaption.Size = New-Object System.Drawing.Size -ArgumentList 70,14
  $ballCaption.Location = New-Object System.Drawing.Point -ArgumentList 11,63
  $ballCaption.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $ballCaption.ForeColor = $script:Theme.TextMuted
  $ballCaption.BackColor = [System.Drawing.Color]::Transparent
  $ballCaption.Font = New-UiFont -FamilyName 'Segoe UI' -Size ([single]6.8) -Style ([System.Drawing.FontStyle]::Regular)
  $script:Ball.Controls.Add($ballCaption)

  $ballMouseDownHandler = {
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $script:BallMouseDown = [System.Windows.Forms.Cursor]::Position
      $script:BallOrigin = $script:Ball.Location
      $script:BallDragged = $false
    }
  }
  $ballMouseMoveHandler = {
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $null -ne $script:BallMouseDown) {
      $cursor = [System.Windows.Forms.Cursor]::Position
      $dx = $cursor.X - $script:BallMouseDown.X
      $dy = $cursor.Y - $script:BallMouseDown.Y
      if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 3) { $script:BallDragged = $true }
      if ($script:BallDragged) {
        $script:Ball.Location = New-Object System.Drawing.Point -ArgumentList ($script:BallOrigin.X + $dx),($script:BallOrigin.Y + $dy)
      }
    }
  }
  $ballMouseUpHandler = {
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      if ($script:BallDragged) {
        $safePoint = Clamp-Location -X $script:Ball.Left -Y $script:Ball.Top -Width $script:Ball.Width -Height $script:Ball.Height
        $script:Ball.Location = $safePoint
        Save-UiSettings
      } else {
        Toggle-Popup
      }
      $script:BallMouseDown = $null
      $script:BallOrigin = $null
      $script:BallDragged = $false
    }
  }

  foreach ($control in @($script:Ball,$script:BallPersonalLabel,$script:BallWorkLabel,$ballCaption)) {
    $control.Add_MouseDown($ballMouseDownHandler)
    $control.Add_MouseMove($ballMouseMoveHandler)
    $control.Add_MouseUp($ballMouseUpHandler)
  }

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $itemToggle = $menu.Items.Add('展开 / 收起额度面板')
  $itemRefresh = $menu.Items.Add('立即刷新')
  $itemBallVisible = $menu.Items.Add('显示悬浮球')
  $itemBallVisible.CheckOnClick = $true
  $itemBallVisible.Checked = [bool]$script:UiSettings.ballVisible
  $itemTopMost = $menu.Items.Add('始终置顶')
  $itemTopMost.CheckOnClick = $true
  $itemTopMost.Checked = [bool]$script:UiSettings.topMost
  $itemReset = $menu.Items.Add('重置界面位置')
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $loginMenu = New-Object System.Windows.Forms.ToolStripMenuItem
  $loginMenu.Text = '账号登录 / 切换'
  $itemPersonal = $loginMenu.DropDownItems.Add('个人账号')
  $itemWork = $loginMenu.DropDownItems.Add('工作账号')
  [void]$menu.Items.Add($loginMenu)
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $itemLogs = $menu.Items.Add('打开日志文件夹')
  $itemExit = $menu.Items.Add('退出')

  $itemToggle.Add_Click({ Toggle-Popup })
  $itemRefresh.Add_Click({ Start-Refresh })
  $itemBallVisible.Add_Click({
    $script:UiSettings.ballVisible = $itemBallVisible.Checked
    if ($itemBallVisible.Checked) { $script:Ball.Show() } else { $script:Ball.Hide() }
    Save-UiSettings
  })
  $itemTopMost.Add_Click({
    $script:UiSettings.topMost = $itemTopMost.Checked
    $script:Popup.TopMost = $itemTopMost.Checked
    $script:Ball.TopMost = $itemTopMost.Checked
    Save-UiSettings
  })
  $itemReset.Add_Click({ Reset-UiPositions })
  $itemPersonal.Add_Click({ Start-Login 'personal' })
  $itemWork.Add_Click({ Start-Login 'work' })
  $itemLogs.Add_Click({ Start-Process explorer.exe -ArgumentList $script:LogDir | Out-Null })
  $itemExit.Add_Click({ Exit-App })

  foreach ($control in @($script:Ball,$script:BallPersonalLabel,$script:BallWorkLabel,$ballCaption)) {
    $control.ContextMenuStrip = $menu
  }

  $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
  $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Information
  $script:NotifyIcon.Text = 'Codex 双账号额度'
  $script:NotifyIcon.ContextMenuStrip = $menu
  $script:NotifyIcon.Add_MouseClick({
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Popup }
  })
  $script:NotifyIcon.Visible = $true

  if ([bool]$script:UiSettings.ballVisible) { $script:Ball.Show() }

  $script:PollTimer = New-Object System.Windows.Forms.Timer
  $script:PollTimer.Interval = 350
  $script:PollTimer.Add_Tick({ Finish-RefreshIfReady })
  $script:PollTimer.Start()

  $script:PeriodicTimer = New-Object System.Windows.Forms.Timer
  $script:PeriodicTimer.Interval = 300000
  $script:PeriodicTimer.Add_Tick({ Start-Refresh -Silent })
  $script:PeriodicTimer.Start()

  $script:InitialTimer = New-Object System.Windows.Forms.Timer
  $script:InitialTimer.Interval = 700
  $script:InitialTimer.Add_Tick({
    $script:InitialTimer.Stop()
    Start-Refresh -Silent
  })
  $script:InitialTimer.Start()

  $script:AppContext = New-Object System.Windows.Forms.ApplicationContext
  Write-TrayLog 'Floating ball and tray icon are visible. Entering WinForms message loop.'
  [System.Windows.Forms.Application]::Run($script:AppContext)
  Write-TrayLog 'WinForms message loop ended.'
} catch {
  try {
    if ($null -ne $script:NotifyIcon) { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() }
  } catch {}
  try {
    if ($null -ne $script:Mutex) { $script:Mutex.ReleaseMutex() | Out-Null; $script:Mutex.Dispose() }
  } catch {}
  Show-FatalError $_.Exception.ToString()
  exit 1
}
