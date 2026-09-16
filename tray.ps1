$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogDir = Join-Path $script:Root 'logs'
$script:TrayLog = Join-Path $script:LogDir 'tray.log'
$script:WorkerLog = Join-Path $script:LogDir 'worker.log'
$script:CachePath = Join-Path $script:LogDir 'usage-result.json'
$script:WorkerProcess = $null
$script:RefreshPending = $false
$script:LastData = $null
$script:Exiting = $false
$script:Mutex = $null
$script:AppContext = $null
$script:Popup = $null
$script:NotifyIcon = $null
$script:ContentPanel = $null
$script:StatusLabel = $null
$script:RefreshButton = $null
$script:Theme = @{}

if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }

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
  Write-TrayLog '===== v0.3.4 tray starting ====='
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [System.Windows.Forms.Application]::EnableVisualStyles()

  $createdNew = $false
  $script:Mutex = New-Object System.Threading.Mutex($true, 'CodexDualUsageTrayV034', [ref]$createdNew)
  if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
      'Codex 双账号额度已经在运行。请检查任务栏右下角的隐藏图标。',
      'Codex 双账号额度',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
  }

  $script:Theme = @{
    PopupBack = [System.Drawing.Color]::FromArgb(10,18,28)
    HeaderBack = [System.Drawing.Color]::FromArgb(14,27,42)
    CardBack = [System.Drawing.Color]::FromArgb(16,30,46)
    CardBorder = [System.Drawing.Color]::FromArgb(42,78,110)
    TextPrimary = [System.Drawing.Color]::FromArgb(232,240,248)
    TextMuted = [System.Drawing.Color]::FromArgb(129,155,181)
    Cyan = [System.Drawing.Color]::FromArgb(0,214,255)
    CyanSoft = [System.Drawing.Color]::FromArgb(111,228,255)
    Danger = [System.Drawing.Color]::FromArgb(255,92,92)
    Warning = [System.Drawing.Color]::FromArgb(255,177,66)
    Good = [System.Drawing.Color]::FromArgb(0,208,132)
    Track = [System.Drawing.Color]::FromArgb(35,56,76)
    ButtonBack = [System.Drawing.Color]::FromArgb(20,42,65)
    ButtonBorder = [System.Drawing.Color]::FromArgb(62,120,168)
  }

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

  function Clear-Content {
    while ($script:ContentPanel.Controls.Count -gt 0) {
      $c = $script:ContentPanel.Controls[0]
      $script:ContentPanel.Controls.RemoveAt(0)
      try { $c.Dispose() } catch {}
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

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point -ArgumentList 14,$Y
    $titleLabel.Font = New-UiFont -FamilyName 'Segoe UI Semibold' -Size ([single]9.3) -Style ([System.Drawing.FontStyle]::Regular)
    $titleLabel.ForeColor = $script:Theme.TextPrimary
    $Parent.Controls.Add($titleLabel)

    $pct = New-Object System.Windows.Forms.Label
    $pct.AutoSize = $false
    $pct.Size = New-Object System.Drawing.Size -ArgumentList 78,22
    $pct.Location = New-Object System.Drawing.Point -ArgumentList 276,($Y-3)
    $pct.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $pct.Font = New-UiFont -FamilyName 'Segoe UI Semibold' -Size ([single]10.5) -Style ([System.Drawing.FontStyle]::Regular)
    $pct.ForeColor = $script:Theme.CyanSoft
    $Parent.Controls.Add($pct)

    $track = New-Object System.Windows.Forms.Panel
    $track.Location = New-Object System.Drawing.Point -ArgumentList 14,($Y+27)
    $track.Size = New-Object System.Drawing.Size -ArgumentList 340,7
    $track.BackColor = $script:Theme.Track
    $Parent.Controls.Add($track)

    $fill = New-Object System.Windows.Forms.Panel
    $fill.Location = New-Object System.Drawing.Point -ArgumentList 0,0
    $fill.Height = 7
    $track.Controls.Add($fill)

    $reset = New-Object System.Windows.Forms.Label
    $reset.AutoSize = $false
    $reset.Size = New-Object System.Drawing.Size -ArgumentList 340,18
    $reset.Location = New-Object System.Drawing.Point -ArgumentList 14,($Y+39)
    $reset.ForeColor = $script:Theme.TextMuted
    $reset.Font = New-UiFont -FamilyName 'Microsoft YaHei UI' -Size ([single]8.1) -Style ([System.Drawing.FontStyle]::Regular)
    $Parent.Controls.Add($reset)

    if ($null -eq $Window) {
      $pct.Text = '—'
      $fill.Width = 0
      $reset.Text = '当前账号未返回此额度窗口'
      return
    }

    $remaining = $Window.remainingPercent
    $pct.Text = Format-Percent $remaining
    if ($null -ne $remaining) {
      $safe = [Math]::Max(0,[Math]::Min(100,[double]$remaining))
      $fill.Width = [int][Math]::Round(340 * $safe / 100)
    } else { $fill.Width = 0 }
    $fill.BackColor = Get-BarColor $remaining
    $resetText = Get-ResetText ([string]$Window.resetsAt)
    if ([string]::IsNullOrWhiteSpace($Detail)) { $reset.Text = $resetText }
    else { $reset.Text = $Detail + ' · ' + $resetText }
  }

  function Add-AccountCard {
    param($Profile,[int]$Top)

    $hasMonthly = $null -ne $Profile.individualLimit
    $height = if ($hasMonthly) { 226 } else { 168 }

    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point -ArgumentList 12,$Top
    $card.Size = New-Object System.Drawing.Size -ArgumentList 370,$height
    $card.BackColor = $script:Theme.CardBack
    $card.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $card.Add_Paint({
      param($sender,$e)
      $rect = New-Object System.Drawing.Rectangle -ArgumentList 0,0,($sender.Width - 1),($sender.Height - 1)
      $pen = New-Object System.Drawing.Pen($script:Theme.CardBorder,1)
      $e.Graphics.DrawRectangle($pen,$rect)
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
    $plan.Location = New-Object System.Drawing.Point -ArgumentList 184,7
    $plan.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $plan.ForeColor = $script:Theme.TextMuted
    $plan.Font = New-UiFont -FamilyName 'Consolas' -Size ([single]8.5) -Style ([System.Drawing.FontStyle]::Regular)
    $plan.Text = if ($Profile.ok) { [string]$Profile.planType } else { '读取失败' }
    $card.Controls.Add($plan)

    if (-not $Profile.ok) {
      $err = New-Object System.Windows.Forms.Label
      $err.AutoSize = $false
      $err.Location = New-Object System.Drawing.Point -ArgumentList 14,43
      $err.Size = New-Object System.Drawing.Size -ArgumentList 340,105
      $err.ForeColor = $script:Theme.Danger
      $err.Font = New-UiFont -FamilyName 'Microsoft YaHei UI' -Size ([single]8.5) -Style ([System.Drawing.FontStyle]::Regular)
      $err.Text = ([string]$Profile.error) + "`r`n`r`n右键托盘图标可以重新登录此账号。"
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
    $label.Size = New-Object System.Drawing.Size -ArgumentList 360,180
    $label.ForeColor = $script:Theme.Danger
    $label.Font = New-UiFont -FamilyName 'Microsoft YaHei UI' -Size ([single]9) -Style ([System.Drawing.FontStyle]::Regular)
    $label.Text = "读取额度失败：`r`n`r`n" + $Message + "`r`n`r`n托盘不会退出。你可以右键图标重新登录或再次刷新。"
    $script:ContentPanel.Controls.Add($label)
    $script:StatusLabel.Text = '读取失败 · ' + (Get-Date).ToString('HH:mm:ss')
  }

  function Render-Data {
    param($Data)
    Clear-Content
    $profiles = @($Data.profiles)
    $top = 6
    foreach ($profile in $profiles) {
      $h = Add-AccountCard -Profile $profile -Top $top
      $top += $h + 10
    }
    if ($profiles.Count -eq 0) {
      Render-Error 'profiles.json 中没有账号配置。'
      return
    }
    $script:StatusLabel.Text = '更新：' + (Get-Date).ToString('HH:mm:ss')
    try { $script:ContentPanel.AutoScrollPosition = New-Object System.Drawing.Point -ArgumentList 0,0 } catch {}

    $allRemaining = @()
    foreach ($p in $profiles) {
      if (-not $p.ok) { continue }
      foreach ($w in @($p.individualLimit,$p.fiveHour,$p.weekly)) {
        if ($null -ne $w -and $null -ne $w.remainingPercent) { $allRemaining += [double]$w.remainingPercent }
      }
    }
    $totalHeight = [Math]::Max(460, [Math]::Min(760, $top + 74))
    $script:Popup.ClientSize = New-Object System.Drawing.Size -ArgumentList 408,$totalHeight

    if ($allRemaining.Count -gt 0) {
      $min = ($allRemaining | Measure-Object -Minimum).Minimum
      $text = 'Codex Dual Usage · 最低剩余 ' + (Format-Percent $min)
      if ($text.Length -gt 63) { $text = $text.Substring(0,63) }
      $script:NotifyIcon.Text = $text
    } else { $script:NotifyIcon.Text = 'Codex 双账号额度' }
  }

  function Show-Loading {
    Clear-Content
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.Location = New-Object System.Drawing.Point -ArgumentList 16,28
    $label.Size = New-Object System.Drawing.Size -ArgumentList 360,90
    $label.ForeColor = $script:Theme.TextMuted
    $label.Font = New-UiFont -FamilyName 'Microsoft YaHei UI' -Size ([single]9) -Style ([System.Drawing.FontStyle]::Regular)
    $label.Text = "正在后台读取个人账号和工作账号额度…`r`n托盘现在已经正常运行，不会因为读取失败而退出。"
    $script:ContentPanel.Controls.Add($label)
  }

  function Start-Refresh {
    if ($script:RefreshPending) { return }
    $script:RefreshPending = $true
    $script:RefreshButton.Enabled = $false
    $script:RefreshButton.Text = '读取中'
    $script:StatusLabel.Text = '正在读取…'
    Show-Loading
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
      Render-Error $_.Exception.Message
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
      if (-not $payload.ok) {
        throw ([string]$payload.error)
      }
      $script:LastData = $payload.data
      Render-Data $script:LastData
      Write-TrayLog 'Refresh result rendered.'
    } catch {
      Write-TrayLog ('Refresh render error: ' + $_.Exception.Message)
      Render-Error $_.Exception.Message
    }
  }

  function Position-Popup {
    $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $x = $screen.Right - $script:Popup.Width - 12
    $y = $screen.Bottom - $script:Popup.Height - 12
    $script:Popup.Location = New-Object System.Drawing.Point -ArgumentList $x,$y
  }

  function Show-Popup {
    Position-Popup
    if (-not $script:Popup.Visible) { $script:Popup.Show() }
    try { $script:ContentPanel.AutoScrollPosition = New-Object System.Drawing.Point -ArgumentList 0,0 } catch {}
    $script:Popup.Activate()
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

  function Exit-App {
    if ($script:Exiting) { return }
    $script:Exiting = $true
    Write-TrayLog 'Exiting tray.'
    try { $script:PollTimer.Stop() } catch {}
    try { $script:PeriodicTimer.Stop() } catch {}
    try { if ($null -ne $script:WorkerProcess -and -not $script:WorkerProcess.HasExited) { $script:WorkerProcess.Kill() } } catch {}
    try { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() } catch {}
    try { $script:Popup.Hide(); $script:Popup.Dispose() } catch {}
    try { if ($null -ne $script:Mutex) { $script:Mutex.ReleaseMutex() | Out-Null; $script:Mutex.Dispose() } } catch {}
    try { $script:AppContext.ExitThread() } catch {}
  }

  Write-TrayLog 'Creating popup UI.'

  $script:Popup = New-Object System.Windows.Forms.Form
  $script:Popup.Text = 'Codex 额度 · 个人 + 工作'
  $script:Popup.ClientSize = New-Object System.Drawing.Size -ArgumentList 408,620
  $script:Popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
  $script:Popup.ShowInTaskbar = $false
  $script:Popup.TopMost = $true
  $script:Popup.BackColor = $script:Theme.PopupBack
  $script:Popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual

  $header = New-Object System.Windows.Forms.Panel
  $header.Dock = [System.Windows.Forms.DockStyle]::Top
  $header.Height = 58
  $header.BackColor = $script:Theme.HeaderBack
  $script:Popup.Controls.Add($header)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = 'Codex 双账号额度  ·  Tech View'
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point -ArgumentList 14,8
  $title.Font = New-UiFont -FamilyName 'Segoe UI Semibold' -Size ([single]11.4) -Style ([System.Drawing.FontStyle]::Regular)
  $title.ForeColor = $script:Theme.TextPrimary
  $header.Controls.Add($title)

  $script:StatusLabel = New-Object System.Windows.Forms.Label
  $script:StatusLabel.Text = '托盘已启动 · 等待首次读取'
  $script:StatusLabel.AutoSize = $true
  $script:StatusLabel.Location = New-Object System.Drawing.Point -ArgumentList 15,34
  $script:StatusLabel.ForeColor = $script:Theme.TextMuted
  $script:StatusLabel.Font = New-UiFont -FamilyName 'Segoe UI' -Size ([single]8.1) -Style ([System.Drawing.FontStyle]::Regular)
  $header.Controls.Add($script:StatusLabel)

  $script:RefreshButton = New-Object System.Windows.Forms.Button
  $script:RefreshButton.Text = '刷新'
  $script:RefreshButton.Size = New-Object System.Drawing.Size -ArgumentList 70,30
  $script:RefreshButton.Location = New-Object System.Drawing.Point -ArgumentList 322,13
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
  $script:Popup.Controls.Add($script:ContentPanel)
  $header.BringToFront()

  $script:Popup.Add_FormClosing({
    param($sender,$e)
    if (-not $script:Exiting -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
      $e.Cancel = $true
      $script:Popup.Hide()
    }
  })

  Write-TrayLog 'Popup UI created.'

  $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
  $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Information
  $script:NotifyIcon.Text = 'Codex 双账号额度'

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $itemShow = $menu.Items.Add('显示额度窗口')
  $itemRefresh = $menu.Items.Add('刷新额度')
  $loginMenu = New-Object System.Windows.Forms.ToolStripMenuItem
  $loginMenu.Text = '账号登录 / 切换'
  $itemPersonal = $loginMenu.DropDownItems.Add('个人账号')
  $itemWork = $loginMenu.DropDownItems.Add('工作账号')
  [void]$menu.Items.Add($loginMenu)
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $itemLogs = $menu.Items.Add('打开日志文件夹')
  $itemExit = $menu.Items.Add('退出')

  $itemShow.Add_Click({ Show-Popup })
  $itemRefresh.Add_Click({ Show-Popup; Start-Refresh })
  $itemPersonal.Add_Click({ Start-Login 'personal' })
  $itemWork.Add_Click({ Start-Login 'work' })
  $itemLogs.Add_Click({ Start-Process explorer.exe -ArgumentList $script:LogDir | Out-Null })
  $itemExit.Add_Click({ Exit-App })
  $script:NotifyIcon.ContextMenuStrip = $menu
  $script:NotifyIcon.Add_MouseClick({
    param($sender,$e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      if ($script:Popup.Visible) { $script:Popup.Hide() } else { Show-Popup }
    }
  })
  $script:NotifyIcon.Visible = $true
  Write-TrayLog 'NotifyIcon is visible.'

  $script:PollTimer = New-Object System.Windows.Forms.Timer
  $script:PollTimer.Interval = 350
  $script:PollTimer.Add_Tick({ Finish-RefreshIfReady })
  $script:PollTimer.Start()

  $script:PeriodicTimer = New-Object System.Windows.Forms.Timer
  $script:PeriodicTimer.Interval = 300000
  $script:PeriodicTimer.Add_Tick({ Start-Refresh })
  $script:PeriodicTimer.Start()

  $script:InitialTimer = New-Object System.Windows.Forms.Timer
  $script:InitialTimer.Interval = 700
  $script:InitialTimer.Add_Tick({
    $script:InitialTimer.Stop()
    Show-Popup
    Start-Refresh
    try {
      $script:NotifyIcon.ShowBalloonTip(1800,'Codex 双账号额度','托盘已启动。左键图标可随时查看。',[System.Windows.Forms.ToolTipIcon]::Info)
    } catch {}
  })
  $script:InitialTimer.Start()

  $script:AppContext = New-Object System.Windows.Forms.ApplicationContext
  Write-TrayLog 'Entering WinForms message loop.'
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
