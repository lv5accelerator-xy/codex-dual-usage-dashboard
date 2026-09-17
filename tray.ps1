param([switch]$SmokeTest)

$ErrorActionPreference = 'Stop'

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogDir = Join-Path $script:Root 'logs'
$script:TrayLog = Join-Path $script:LogDir 'tray.log'
$script:WorkerLog = Join-Path $script:LogDir 'worker.log'
$script:CachePath = Join-Path $script:LogDir 'usage-result.json'
$script:UiSettingsPath = Join-Path $script:Root 'ui-settings.json'
$script:WorkerProcess = $null
$script:RefreshPending = $false
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
$script:BallMouseDown = $null
$script:BallOrigin = $null
$script:BallDragged = $false
$script:UiSettings = $null
$script:Theme = @{}
$script:Fonts = @{}
$script:BallCells = @{}
$script:ResetLabels = @()
$script:CardStates = @()
$script:RefreshError = ''
$script:RefreshStarted = $null
$script:UiScale = 1.0
. (Join-Path $script:Root 'ui-model.ps1')
. (Join-Path $script:Root 'ui-behavior.ps1')
$script:AlertState = @{}
$script:AlertBaselinePending = $true
$script:AlertStatePath = Join-Path $script:LogDir 'notification-state.json'
$script:MonitorExpanded = $true
$script:RestLocation = $null
$script:PointerLeftAt = $null
$script:CompactCells = @{}

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
  if ($SmokeTest) { [Console]::Error.WriteLine($Message); return }
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
  Write-TrayLog '===== v0.4.1 tray starting ====='
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  if (-not ('CodexUsage.Surface' -as [type])) {
    Add-Type -Path (Join-Path $script:Root 'ui-controls.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing
  }
  [CodexUsage.NativeDisplay]::EnableDpi()
  [System.Windows.Forms.Application]::EnableVisualStyles()
  $desktopGraphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
  try { $script:UiScale = $desktopGraphics.DpiX / 96.0 } finally { $desktopGraphics.Dispose() }
  $script:ToolTip = New-Object System.Windows.Forms.ToolTip
  $script:ToolTip.AutoPopDelay = 15000
  $script:ToolTip.InitialDelay = 400

  $createdNew = $false
  $script:Mutex = New-Object System.Threading.Mutex($true, $(if ($SmokeTest) { 'CodexDualUsageTraySmokeTest' } else { 'CodexDualUsageTray' }), [ref]$createdNew)
  if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
      'Codex 双账号额度已经在运行。请检查桌面悬浮面板或任务栏右下角图标。',
      'Codex 双账号额度',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
  }

  $script:Theme = @{
    PopupBack = [System.Drawing.ColorTranslator]::FromHtml('#16171B')
    HeaderBack = [System.Drawing.ColorTranslator]::FromHtml('#16171B')
    CardBack = [System.Drawing.ColorTranslator]::FromHtml('#202228')
    CardBorder = [System.Drawing.ColorTranslator]::FromHtml('#343740')
    TextPrimary = [System.Drawing.ColorTranslator]::FromHtml('#F0F1F4')
    TextMuted = [System.Drawing.ColorTranslator]::FromHtml('#A1A5B2')
    Danger = [System.Drawing.ColorTranslator]::FromHtml('#F08080')
    Warning = [System.Drawing.ColorTranslator]::FromHtml('#E5B66F')
    Good = [System.Drawing.ColorTranslator]::FromHtml('#8A9ED6')
    Track = [System.Drawing.ColorTranslator]::FromHtml('#30333C')
    ButtonBack = [System.Drawing.ColorTranslator]::FromHtml('#303540')
    ButtonBorder = [System.Drawing.ColorTranslator]::FromHtml('#454B59')
    BallBack = [System.Drawing.ColorTranslator]::FromHtml('#202228')
  }

  function U { param([double]$Value) return [int][Math]::Round($Value * $script:UiScale) }

  function New-UiFont {
    param([single]$Size = 10,[switch]$Bold)
    $key = "$Size/$($Bold.IsPresent)"
    if (-not $script:Fonts.ContainsKey($key)) {
      $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
      $ctor = [System.Drawing.Font].GetConstructor([Type[]]@([string],[single],[System.Drawing.FontStyle],[System.Drawing.GraphicsUnit]))
      $script:Fonts[$key] = [System.Drawing.Font]$ctor.Invoke(@('Microsoft YaHei UI',[single]$Size,$style,[System.Drawing.GraphicsUnit]::Point))
    }
    return $script:Fonts[$key]
  }

  function New-Label {
    param([string]$Text = '',[single]$Size = 10,[switch]$Muted,[switch]$Bold)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Dock = [System.Windows.Forms.DockStyle]::Fill
    $label.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $label.AutoEllipsis = $true
    $label.Font = New-UiFont -Size $Size -Bold:$Bold
    $label.ForeColor = if ($Muted) { $script:Theme.TextMuted } else { $script:Theme.TextPrimary }
    return $label
  }

  function New-Grid {
    param([int]$Columns = 1)
    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0
    $grid.Padding = New-Object System.Windows.Forms.Padding -ArgumentList 0
    $grid.ColumnCount = $Columns
    $grid.RowCount = 0
    return $grid
  }

  function Add-GridRow {
    param($Grid,[double]$Height)
    $Grid.RowCount++
    [void]$Grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute),([single](U $Height))))
  }

  function New-Button {
    param([string]$Text)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Dock = [System.Windows.Forms.DockStyle]::Fill
    $button.Font = New-UiFont -Size 9
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.BackColor = $script:Theme.ButtonBack
    $button.ForeColor = $script:Theme.TextPrimary
    $button.FlatAppearance.BorderColor = $script:Theme.ButtonBorder
    $button.FlatAppearance.MouseOverBackColor = $script:Theme.ButtonBorder
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0
    return $button
  }

  function Get-BarColor {
    param($Remaining)
    if ($null -eq $Remaining) { return $script:Theme.Track }
    if ([double]$Remaining -le 15) { return $script:Theme.Danger }
    if ([double]$Remaining -le 35) { return $script:Theme.Warning }
    return $script:Theme.Good
  }

  function Get-ValueColor {
    param($Remaining,[bool]$Stale = $false)
    if ($Stale -or $null -eq $Remaining) { return $script:Theme.TextMuted }
    if ([double]$Remaining -le 35) { return (Get-BarColor $Remaining) }
    return $script:Theme.TextPrimary
  }

  function Get-DefaultUiSettings {
    return [ordered]@{
      ballX = $null
      ballY = $null
      panelX = $null
      panelY = $null
      panelWidth = (U 440)
      panelHeight = (U 840)
      topMost = $true
      ballVisible = $true
      compactMode = $true
      edgeSnap = $true
      dockHorizontal = 'none'
      dockVertical = 'none'
      notificationsEnabled = $false
      notificationThresholds = @(20,10)
    }
  }

  function Load-UiSettings {
    $settings = Get-DefaultUiSettings
    if ($SmokeTest) { return $settings }
    if (Test-Path -LiteralPath $script:UiSettingsPath) {
      try {
        $loaded = Get-Content -LiteralPath $script:UiSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @('ballX','ballY','panelX','panelY','panelWidth','panelHeight','topMost','ballVisible','compactMode','edgeSnap','dockHorizontal','dockVertical','notificationsEnabled','notificationThresholds')) {
          if ($loaded.PSObject.Properties.Name -contains $key) {
            $settings[$key] = $loaded.$key
          }
        }
      } catch {
        Write-TrayLog ('UI settings load warning: ' + $_.Exception.Message)
      }
    }
    if ($settings.dockHorizontal -notin @('none','left','right')) { $settings.dockHorizontal = 'none' }
    if ($settings.dockVertical -notin @('none','top','bottom')) { $settings.dockVertical = 'none' }
    $levels = @($settings.notificationThresholds | Where-Object { $_ -match '^\d+$' -and [int]$_ -gt 0 -and [int]$_ -lt 100 } | ForEach-Object { [int]$_ } | Sort-Object -Descending -Unique)
    $settings.notificationThresholds = if ($levels.Count) { $levels } else { @(20,10) }
    return $settings
  }

  function Save-UiSettings {
    if ($SmokeTest) { return }
    try {
      if ($null -ne $script:Ball) {
        $point = if ($null -ne $script:RestLocation) { $script:RestLocation } else { $script:Ball.Location }
        $script:UiSettings.ballX = $point.X
        $script:UiSettings.ballY = $point.Y
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
    return (New-Object System.Drawing.Point -ArgumentList ($area.Right - (U 268)),($area.Bottom - (U 180)))
  }

  function Get-DefaultPanelLocation {
    param([int]$Width,[int]$Height)
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $area.Right - $Width - 24
    $y = [Math]::Max($area.Top + 24, $area.Bottom - $Height - 24)
    return (New-Object System.Drawing.Point -ArgumentList $x,$y)
  }

  function Remember-MonitorPosition {
    $x = $script:Ball.Left
    $y = $script:Ball.Top
    if ($script:UiSettings.compactMode -and $script:MonitorExpanded -and $script:UiSettings.dockVertical -eq 'bottom') {
      $y = $script:Ball.Bottom - (U 44)
    }
    $script:RestLocation = New-Object System.Drawing.Point -ArgumentList $x,$y
  }

  function Set-MonitorExpanded {
    param([bool]$Expanded)
    if (-not $script:UiSettings.compactMode) { $Expanded = $true }
    if ($null -eq $script:RestLocation) { Remember-MonitorPosition }
    $script:Ball.SuspendLayout()
    try {
      $script:MonitorExpanded = $Expanded
      $script:ExpandedGrid.Visible = $Expanded
      $script:CompactGrid.Visible = -not $Expanded
      $height = if ($Expanded) { 142 } else { 44 }
      $script:Ball.Padding = if ($Expanded) {
        New-Object System.Windows.Forms.Padding -ArgumentList (U 14),(U 10),(U 14),(U 10)
      } else { New-Object System.Windows.Forms.Padding -ArgumentList (U 12),(U 4),(U 12),(U 4) }
      $script:Ball.ClientSize = New-Object System.Drawing.Size -ArgumentList (U 244),(U $height)
      $x = $script:RestLocation.X
      $y = $script:RestLocation.Y
      if ($Expanded -and $script:UiSettings.compactMode -and $script:UiSettings.dockVertical -eq 'bottom') { $y -= U 98 }
      $script:Ball.Location = Clamp-Location -X $x -Y $y -Width $script:Ball.Width -Height $script:Ball.Height
    } finally { $script:Ball.ResumeLayout($true) }
  }

  function Snap-Monitor {
    $area = [System.Windows.Forms.Screen]::FromRectangle($script:Ball.Bounds).WorkingArea
    $position = Get-SnappedPosition -X $script:Ball.Left -Y $script:Ball.Top -Width $script:Ball.Width -Height $script:Ball.Height -Area $area -Distance (U 20) -Enabled ([bool]$script:UiSettings.edgeSnap)
    $script:Ball.Location = New-Object System.Drawing.Point -ArgumentList $position.x,$position.y
    $script:UiSettings.dockHorizontal = $position.horizontal
    $script:UiSettings.dockVertical = $position.vertical
    Remember-MonitorPosition
  }

  function Update-MonitorHover {
    if (-not $script:UiSettings.compactMode -or -not $script:Ball.Visible -or $null -ne $script:BallMouseDown -or $script:MonitorMenu.Visible) { return }
    $bounds = $script:Ball.Bounds
    $inside = $bounds.Contains([System.Windows.Forms.Cursor]::Position)
    if ($inside) {
      $script:PointerLeftAt = $null
      if (-not $script:MonitorExpanded) { Set-MonitorExpanded $true }
    } elseif ($script:MonitorExpanded -and -not $script:Popup.Visible) {
      if ($null -eq $script:PointerLeftAt) { $script:PointerLeftAt = [DateTimeOffset]::Now }
      if (([DateTimeOffset]::Now - $script:PointerLeftAt).TotalMilliseconds -ge 450) { Set-MonitorExpanded $false }
    }
  }

  function Load-AlertState {
    if ($SmokeTest -or -not (Test-Path -LiteralPath $script:AlertStatePath)) { return }
    try {
      $loaded = Get-Content -LiteralPath $script:AlertStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($property in $loaded.PSObject.Properties) {
        $entry = $property.Value
        # Keep the fired-threshold ledger, but establish a fresh baseline per
        # account/window on the first successful sample after a restart.
        $entry.value = $null
        $script:AlertState[$property.Name] = $entry
      }
    } catch { Write-TrayLog ('Notification state load warning: ' + $_.Exception.Message) }
  }

  function Process-QuotaNotifications {
    param($Data)
    try {
      $alerts = @(Get-QuotaAlerts -Data $Data -State $script:AlertState -Thresholds $script:UiSettings.notificationThresholds -Enabled ([bool]$script:UiSettings.notificationsEnabled) -Baseline $script:AlertBaselinePending)
      $script:AlertBaselinePending = $false
      if (-not $SmokeTest) {
        # Persist the deduplication ledger before requesting a Windows notification.
        $temporary = $script:AlertStatePath + '.tmp'
        $script:AlertState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $script:AlertStatePath -Force
        if ($alerts.Count -gt 0) {
          $lines = @($alerts | ForEach-Object { '{0} · {1}剩余 {2}' -f $_.label,$_.title,(Format-Percent $_.remaining) })
          $script:NotifyIcon.ShowBalloonTip(8000,'Codex 低额度提醒',($lines -join "`r`n"),[System.Windows.Forms.ToolTipIcon]::Warning)
        }
      }
    } catch { Write-TrayLog ('Notification warning: ' + $_.Exception.Message) }
  }

  function Clear-Content {
    $script:ResetLabels = @()
    $script:CardStates = @()
    $script:ToolTip.RemoveAll()
    while ($script:ContentPanel.Controls.Count -gt 0) {
      $control = $script:ContentPanel.Controls[0]
      $script:ContentPanel.Controls.RemoveAt(0)
      $control.Dispose()
    }
  }

  function Add-QuotaRow {
    param($Parent,[string]$Title,$Window,[int]$Row,[switch]$Primary,[string]$Detail = '')
    $grid = New-Grid -Columns 2
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]60)))
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]40)))
    Add-GridRow $grid $(if ($Primary) { 48 } else { 30 })
    Add-GridRow $grid 6
    Add-GridRow $grid 28
    $titleLabel = New-Label -Text $Title -Size 10
    $grid.Controls.Add($titleLabel,0,0)
    $remaining = if ($null -ne $Window) { $Window.remainingPercent } else { $null }
    $pct = New-Label -Text (Format-Percent $remaining) -Size $(if ($Primary) { 23 } else { 15 }) -Bold
    $pct.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $pct.ForeColor = Get-ValueColor $remaining
    $grid.Controls.Add($pct,1,0)
    $bar = New-Object CodexUsage.QuotaBar
    $bar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bar.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0
    $bar.Value = if ($null -eq $remaining) { 0 } else { [double]$remaining }
    $bar.FillColor = Get-BarColor $remaining
    $grid.Controls.Add($bar,0,1)
    $grid.SetColumnSpan($bar,2)
    $reset = New-Label -Size 9 -Muted
    $reset.Tag = [pscustomobject]@{ window = $Window; detail = $Detail }
    $script:ResetLabels += $reset
    $grid.Controls.Add($reset,0,2)
    $grid.SetColumnSpan($reset,2)
    $Parent.Controls.Add($grid,0,$Row)
    $Parent.SetColumnSpan($grid,2)
  }

  function Add-AccountCard {
    param($Profile)
    $hasMonthly = Test-MeaningfulLimit $Profile.individualLimit
    $card = New-Object CodexUsage.Surface
    $card.Radius = U 12
    $card.BackColor = $script:Theme.CardBack
    $card.BorderColor = $script:Theme.CardBorder
    $card.Padding = New-Object System.Windows.Forms.Padding -ArgumentList (U 16)
    $card.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0,0,0,(U 12)
    $card.Height = if (-not $Profile.ok) { U 206 } elseif ($hasMonthly) { U 366 } else { U 284 }
    $grid = New-Grid -Columns 2
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]60)))
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]40)))
    Add-GridRow $grid 36
    $name = New-Label -Text ([string]$Profile.label) -Size 11 -Bold
    $grid.Controls.Add($name,0,0)
    $plan = New-Label -Text ([string]$Profile.planType) -Size 9 -Muted
    if ([string]::IsNullOrWhiteSpace($plan.Text) -or $plan.Text -eq 'unknown') { $plan.Text = '账号' }
    $plan.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $grid.Controls.Add($plan,1,0)
    $card.Controls.Add($grid)
    if ($Profile.ok) {
      Add-GridRow $grid 100
      Add-QuotaRow $grid '5 小时 · 剩余' $Profile.fiveHour 1 -Primary
      $row = 2
      if ($hasMonthly) {
        Add-GridRow $grid 82
        $detail = ''
        if ($null -ne $Profile.individualLimit.used -and $null -ne $Profile.individualLimit.limit) {
          $detail = '已用 {0} / {1}' -f $Profile.individualLimit.used,$Profile.individualLimit.limit
        }
        Add-QuotaRow $grid '工作空间 / 月度' $Profile.individualLimit $row -Detail $detail
        $row++
      }
      Add-GridRow $grid 82
      Add-QuotaRow $grid '每周 · 剩余' $Profile.weekly $row
      $row++
    } else {
      Add-GridRow $grid 104
      $errorLabel = New-Label -Text "暂时无法读取额度。`r`n请重试，或重新登录这个账号。" -Size 10 -Muted
      $grid.Controls.Add($errorLabel,0,1)
      $grid.SetColumnSpan($errorLabel,2)
      $script:ToolTip.SetToolTip($errorLabel,[string]$Profile.error)
      $row = 2
    }
    Add-GridRow $grid 32
    $state = New-Label -Size 9 -Muted
    $grid.Controls.Add($state,0,$row)
    $script:CardStates += [pscustomobject]@{ label = $state; profile = $Profile }
    $login = New-Button '重新登录'
    $login.Tag = [string]$Profile.id
    $login.AccessibleName = [string]$Profile.label + '：重新登录'
    $login.Add_Click({ param($sender,$eventArgs) Start-Login ([string]$sender.Tag) })
    $grid.Controls.Add($login,1,$row)
    foreach ($control in @(Get-ControlTree $card)) {
      $control.Add_MouseWheel({ param($sender,$eventArgs)
        Move-VerticalScroll $eventArgs.Delta
        if ($eventArgs -is [System.Windows.Forms.HandledMouseEventArgs]) { $eventArgs.Handled = $true }
      })
    }
    $script:ContentPanel.Controls.Add($card)
  }

  function Update-CardWidths {
    if ($null -eq $script:ContentPanel -or $null -eq $script:ScrollBar -or $script:LayingOutCards) { return }
    $script:LayingOutCards = $true
    try {
      $panel = $script:ContentPanel
      $width = [Math]::Max(1, $panel.ClientSize.Width - $panel.Padding.Horizontal)
      $totalHeight = $panel.Padding.Vertical
      foreach ($card in $panel.Controls) { $totalHeight += $card.Height + $card.Margin.Bottom }
      $maxScroll = [Math]::Max(0,$totalHeight - $panel.ClientSize.Height)
      # Own the vertical range explicitly: WinForms AutoScroll can retain a
      # horizontal range when the native scrollbar appears during a resize.
      $script:ScrollBar.Value = [Math]::Min($script:ScrollBar.Value,$maxScroll)
      $script:ScrollBar.LargeChange = [Math]::Max(1,$panel.ClientSize.Height)
      $script:ScrollBar.Maximum = [Math]::Max(0,$totalHeight - 1)
      $script:ScrollBar.SmallChange = U 36
      $script:ScrollBar.Visible = $maxScroll -gt 0
      $top = $panel.Padding.Top - $script:ScrollBar.Value
      foreach ($card in $panel.Controls) {
        $card.Width = $width
        $card.Location = New-Object System.Drawing.Point -ArgumentList $panel.Padding.Left,$top
        $top += $card.Height + $card.Margin.Bottom
      }
    } finally { $script:LayingOutCards = $false }
  }

  function Move-VerticalScroll {
    param([int]$Delta)
    $max = [Math]::Max(0,$script:ScrollBar.Maximum - $script:ScrollBar.LargeChange + 1)
    $next = $script:ScrollBar.Value - [int]($Delta / 120) * (U 72)
    $script:ScrollBar.Value = [Math]::Max(0,[Math]::Min($max,$next))
  }

  function Update-BallSummary {
    param($Data)
    foreach ($id in @('personal','work')) {
      $profile = Get-DisplayProfile $Data $id
      $cells = $script:BallCells[$id]
      if ($null -eq $cells) { continue }
      $pair = Get-QuotaPair $profile
      $stale = (Test-ProfileStale $profile) -or -not [string]::IsNullOrEmpty($script:RefreshError)
      $cells.five.Text = Format-Percent $pair.fiveHour
      $cells.long.Text = Format-Percent $pair.longTerm
      $cells.five.ForeColor = Get-ValueColor $pair.fiveHour $stale
      $cells.long.ForeColor = Get-ValueColor $pair.longTerm $stale
      $cells.name.ForeColor = if ($stale -and ($null -ne $Data -or -not [string]::IsNullOrEmpty($script:RefreshError))) { $script:Theme.Warning } else { $script:Theme.TextMuted }
      $tip = '长周期显示每周与有效月度额度中，剩余比例较低的一项。'
      $tip += "`r`n当前来源：" + $pair.source
      if ($null -ne $profile.weekly) { $tip += "`r`n每周剩余：" + (Format-Percent $profile.weekly.remainingPercent) }
      if (Test-MeaningfulLimit $profile.individualLimit) { $tip += "`r`n工作空间 / 月度剩余：" + (Format-Percent $profile.individualLimit.remainingPercent) }
      if ($stale -and ($null -ne $Data -or -not [string]::IsNullOrEmpty($script:RefreshError))) { $tip += "`r`n数据未更新，请刷新后确认。" }
      $script:ToolTip.SetToolTip($cells.long,$tip)
      $script:ToolTip.SetToolTip($cells.five,'5 小时窗口剩余额度。' + "`r`n" + (Get-ResetText ([string]$profile.fiveHour.resetsAt)))
      $script:ToolTip.SetToolTip($cells.name,([string]$profile.refreshError))
      if ($script:CompactCells.ContainsKey($id)) {
        $values = @(@($pair.fiveHour,$pair.longTerm) | Where-Object { $null -ne $_ })
        $minimum = if ($values.Count) { ($values | Measure-Object -Minimum).Minimum } else { $null }
        $label = $script:CompactCells[$id]
        $account = if ($id -eq 'personal') { '个人' } else { '工作' }
        $mark = if ($stale -and ($null -ne $Data -or -not [string]::IsNullOrEmpty($script:RefreshError))) { ' ! ' } else { ' ' }
        $label.Text = $account + $mark + (Format-Percent $minimum)
        $label.ForeColor = if ($stale -and ($null -ne $Data -or -not [string]::IsNullOrEmpty($script:RefreshError))) { $script:Theme.Warning } else { Get-ValueColor $minimum }
        $script:ToolTip.SetToolTip($label,($account + ' · 最低剩余额度' + "`r`n5 小时：" + (Format-Percent $pair.fiveHour) + "`r`n" + $tip))
      }
    }
  }

  function Update-Status {
    $problems = @()
    foreach ($profile in @($script:LastData.profiles)) {
      if ($null -ne $profile -and (Test-ProfileStale $profile)) { $problems += [string]$profile.label }
    }
    $warning = $problems.Count -gt 0 -or -not [string]::IsNullOrEmpty($script:RefreshError)
    if ($script:RefreshPending) {
      $text = '正在更新 · 保留上次数据'
      $compact = '正在更新…'
    } elseif ($warning) {
      $text = if ($problems.Count -gt 0) { ($problems -join '、') + '未更新 · 请重试' } else { '刷新失败 · 显示上次数据' }
      $compact = if ($problems.Count -eq 1) { $problems[0].Replace('账号','') + '未更新' } else { '数据未更新 · 请重试' }
    } elseif ($null -eq $script:LastData) {
      $text = '等待首次读取 · 每 5 分钟自动更新'
      $compact = '等待首次读取'
    } else {
      try { $stamp = ([DateTimeOffset]::Parse($script:LastData.fetchedAt)).ToLocalTime().ToString('HH:mm') } catch { $stamp = '--:--' }
      $text = '更新于 ' + $stamp + ' · 每 5 分钟自动刷新'
      $compact = '更新于 ' + $stamp
    }
    $script:StatusLabel.Text = $text
    $script:BallStatus.Text = $compact
    $color = if ($warning) { $script:Theme.Warning } else { $script:Theme.TextMuted }
    $script:StatusLabel.ForeColor = $color
    $script:BallStatus.ForeColor = $color
    $script:ToolTip.SetToolTip($script:StatusLabel, $text + "`r`n" + $script:RefreshError)
    $script:ToolTip.SetToolTip($script:BallStatus, $text + "`r`n" + $script:RefreshError)
    foreach ($entry in $script:CardStates) {
      $stale = (Test-ProfileStale $entry.profile) -or -not [string]::IsNullOrEmpty($script:RefreshError)
      $loading = $null -eq $script:LastData -and [string]::IsNullOrEmpty($script:RefreshError)
      $entry.label.Text = if ($loading) { '等待读取…' } elseif ($stale) { '数据未更新' } else { '已连接 · 数据已更新' }
      if ($loading) { $stale = $false }
      $entry.label.ForeColor = if ($stale) { $script:Theme.Warning } else { $script:Theme.TextMuted }
      $script:ToolTip.SetToolTip($entry.label,([string]$entry.profile.refreshError))
    }
    foreach ($label in $script:ResetLabels) {
      $window = $label.Tag.window
      if ($null -eq $script:LastData -and [string]::IsNullOrEmpty($script:RefreshError)) { $label.Text = '等待读取…' }
      elseif ($null -eq $window -or $null -eq $window.remainingPercent) { $label.Text = '未提供此额度' }
      else { $label.Text = Get-ResetText ([string]$window.resetsAt) }
      $tip = $label.Text
      if (-not [string]::IsNullOrEmpty($label.Tag.detail)) { $tip = $label.Tag.detail + "`r`n" + $tip }
      try {
        if ($window.resetsAt) { $tip += "`r`n" + ([DateTimeOffset]::Parse($window.resetsAt)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz') }
      } catch {}
      $script:ToolTip.SetToolTip($label,$tip)
    }
    Update-BallSummary $script:LastData
    if ($null -ne $script:NotifyIcon) { $script:NotifyIcon.Text = 'Codex 额度 · ' + $compact }
  }

  function Render-Data {
    param($Data)
    $scroll = $script:ScrollBar.Value
    $script:ContentPanel.SuspendLayout()
    try {
      Clear-Content
      foreach ($profile in @($Data.profiles)) { if ($null -ne $profile) { Add-AccountCard $profile } }
      Update-CardWidths
    } finally { $script:ContentPanel.ResumeLayout($true) }
    $maxScroll = [Math]::Max(0,$script:ScrollBar.Maximum - $script:ScrollBar.LargeChange + 1)
    $script:ScrollBar.Value = [Math]::Min($scroll,$maxScroll)
    Update-CardWidths
    Update-Status
  }

  function Show-Loading {
    $config = Get-Content -LiteralPath (Join-Path $script:Root 'profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $pending = @()
    foreach ($profile in $config.profiles) {
      $pending += [pscustomobject]@{ id = $profile.id; label = $profile.label; ok = $true; planType = '等待读取' }
    }
    Render-Data ([pscustomobject]@{ profiles = $pending })
  }

  function Render-Error {
    param([string]$Message)
    $script:RefreshError = $Message
    if ($null -eq $script:LastData) {
      $config = Get-Content -LiteralPath (Join-Path $script:Root 'profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $failed = @()
      foreach ($profile in $config.profiles) {
        $failed += [pscustomobject]@{ id = $profile.id; label = $profile.label; ok = $false; error = $Message }
      }
      Render-Data ([pscustomobject]@{ profiles = $failed })
    }
    Update-Status
  }

  function Start-Refresh {
    param([switch]$Silent)
    if ($script:RefreshPending) { return }
    $script:RefreshPending = $true
    $script:RefreshStarted = [DateTimeOffset]::Now
    $script:RefreshButton.Enabled = $false
    $script:RefreshButton.Text = '更新中'
    if ($null -eq $script:LastData) { Show-Loading }
    Update-Status
    try {
      Remove-Item -LiteralPath $script:CachePath -Force -ErrorAction SilentlyContinue
      $worker = Join-Path $script:Root 'usage-worker.ps1'
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = Join-Path $PSHOME 'powershell.exe'
      if (-not (Test-Path -LiteralPath $psi.FileName)) { $psi.FileName = 'powershell.exe' }
      $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutputPath "{1}" -LogPath "{2}"' -f $worker,$script:CachePath,$script:WorkerLog)
      $psi.WorkingDirectory = $script:Root
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $script:WorkerProcess = New-Object System.Diagnostics.Process
      $script:WorkerProcess.StartInfo = $psi
      if (-not $script:WorkerProcess.Start()) { throw '无法启动后台读取进程。' }
      Write-TrayLog ('Refresh worker PID: ' + $script:WorkerProcess.Id)
    } catch {
      if ($null -ne $script:WorkerProcess) { $script:WorkerProcess.Dispose(); $script:WorkerProcess = $null }
      $script:RefreshPending = $false
      $script:RefreshButton.Enabled = $true
      $script:RefreshButton.Text = '刷新'
      Write-TrayLog ('Refresh start error: ' + $_.Exception.Message)
      Render-Error $_.Exception.Message
    }
  }

  function Finish-RefreshIfReady {
    if (-not $script:RefreshPending -or $null -eq $script:WorkerProcess) { return }
    if (-not $script:WorkerProcess.HasExited) {
      if (([DateTimeOffset]::Now - $script:RefreshStarted).TotalSeconds -lt 150) { return }
      try { $script:WorkerProcess.Kill() } catch {}
      $script:WorkerProcess.Dispose()
      $script:WorkerProcess = $null
      $script:RefreshPending = $false
      $script:RefreshButton.Enabled = $true
      $script:RefreshButton.Text = '刷新'
      Render-Error '读取超时，请重试。'
      return
    }
    $script:WorkerProcess.Dispose()
    $script:WorkerProcess = $null
    $script:RefreshPending = $false
    $script:RefreshButton.Enabled = $true
    $script:RefreshButton.Text = '刷新'
    try {
      if (-not (Test-Path -LiteralPath $script:CachePath)) { throw '后台未返回数据，请重试或查看日志。' }
      $payload = Get-Content -LiteralPath $script:CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
      if (-not $payload.ok) { throw ([string]$payload.error) }
      if (@($payload.data.profiles).Count -eq 0) { throw '未配置账号，请检查 profiles.json。' }
      $script:LastData = Merge-DisplayData -Previous $script:LastData -Incoming $payload.data
      $script:RefreshError = ''
      Process-QuotaNotifications $payload.data
      Render-Data $script:LastData
      Write-TrayLog 'Refresh result rendered.'
    } catch {
      Write-TrayLog ('Refresh error: ' + $_.Exception.Message)
      Render-Error $_.Exception.Message
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
    if ($Account -notin @('personal','work')) { return }
    $script:AlertBaselinePending = $true
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
    $script:UiSettings.dockHorizontal = 'none'
    $script:UiSettings.dockVertical = 'none'
    Remember-MonitorPosition
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
    try { $script:StatusTimer.Stop() } catch {}
    try { $script:HoverTimer.Stop() } catch {}
    try { if ($null -ne $script:WorkerProcess -and -not $script:WorkerProcess.HasExited) { $script:WorkerProcess.Kill() } } catch {}
    try { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() } catch {}
    try { $script:Popup.Hide(); $script:Popup.Dispose() } catch {}
    try { $script:Ball.Hide(); $script:Ball.Dispose() } catch {}
    try { if ($null -ne $script:Mutex) { $script:Mutex.ReleaseMutex() | Out-Null; $script:Mutex.Dispose() } } catch {}
    try { $script:ToolTip.Dispose() } catch {}
    foreach ($font in $script:Fonts.Values) { try { $font.Dispose() } catch {} }
    try { $script:AppContext.ExitThread() } catch {}
  }

  $script:UiSettings = Load-UiSettings
  Load-AlertState
  $script:Popup = New-Object System.Windows.Forms.Form
  $script:Popup.Text = 'Codex 额度'
  $script:Popup.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $script:Popup.Font = New-UiFont
  $script:Popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::SizableToolWindow
  $script:Popup.ShowInTaskbar = $false
  $script:Popup.TopMost = [bool]$script:UiSettings.topMost
  $script:Popup.BackColor = $script:Theme.PopupBack
  $script:Popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $script:Popup.MinimumSize = New-Object System.Drawing.Size -ArgumentList (U 380),(U 360)
  $panelWidth = [Math]::Max((U 380),[int]$script:UiSettings.panelWidth)
  $panelHeight = [Math]::Max((U 360),[int]$script:UiSettings.panelHeight)
  $screenPoint = New-Object System.Drawing.Point -ArgumentList ([int]$script:UiSettings.panelX),([int]$script:UiSettings.panelY)
  $workingArea = [System.Windows.Forms.Screen]::FromPoint($screenPoint).WorkingArea
  $panelWidth = [Math]::Min($panelWidth,$workingArea.Width)
  $panelHeight = [Math]::Min($panelHeight,$workingArea.Height)
  $script:Popup.Size = New-Object System.Drawing.Size -ArgumentList $panelWidth,$panelHeight
  if ($null -ne $script:UiSettings.panelX -and $null -ne $script:UiSettings.panelY) {
    $popupPoint = Clamp-Location -X ([int]$script:UiSettings.panelX) -Y ([int]$script:UiSettings.panelY) -Width $panelWidth -Height $panelHeight
  } else { $popupPoint = Get-DefaultPanelLocation -Width $panelWidth -Height $panelHeight }
  $script:Popup.Location = $popupPoint

  $rootLayout = New-Grid
  Add-GridRow $rootLayout 76
  $rootLayout.RowCount++
  [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]100)))
  Add-GridRow $rootLayout 36
  $script:Popup.Controls.Add($rootLayout)
  $header = New-Grid -Columns 2
  $header.Padding = New-Object System.Windows.Forms.Padding -ArgumentList (U 20),(U 12),(U 20),(U 12)
  [void]$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]100)))
  [void]$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute),([single](U 72))))
  Add-GridRow $header 30
  Add-GridRow $header 22
  $title = New-Label -Text 'Codex 额度' -Size 15 -Bold
  $subtitle = New-Label -Text '双账号使用概览 · 所有数值均为剩余' -Size 9 -Muted
  $header.Controls.Add($title,0,0)
  $header.Controls.Add($subtitle,0,1)
  $script:RefreshButton = New-Button '刷新'
  $script:RefreshButton.Add_Click({ Start-Refresh })
  $header.Controls.Add($script:RefreshButton,1,0)
  $rootLayout.Controls.Add($header,0,0)

  $script:ContentPanel = New-Object System.Windows.Forms.Panel
  $script:ContentPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
  $script:ContentPanel.AutoScroll = $false
  $script:ContentPanel.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0
  $script:ContentPanel.Padding = New-Object System.Windows.Forms.Padding -ArgumentList (U 16),0,(U 16),0
  $script:ContentPanel.Add_SizeChanged({ Update-CardWidths })
  $viewport = New-Grid -Columns 2
  [void]$viewport.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]100)))
  [void]$viewport.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute),([single][System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth)))
  $viewport.RowCount = 1
  [void]$viewport.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]100)))
  $script:ScrollBar = New-Object System.Windows.Forms.VScrollBar
  $script:ScrollBar.Dock = [System.Windows.Forms.DockStyle]::Fill
  $script:ScrollBar.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0
  $script:ScrollBar.AccessibleName = '额度面板垂直滚动'
  $script:ScrollBar.Add_ValueChanged({ Update-CardWidths })
  $script:ContentPanel.Add_MouseWheel({ param($sender,$eventArgs) Move-VerticalScroll $eventArgs.Delta })
  $viewport.Controls.Add($script:ContentPanel,0,0)
  $viewport.Controls.Add($script:ScrollBar,1,0)
  $rootLayout.Controls.Add($viewport,0,1)
  $script:StatusLabel = New-Label -Size 9 -Muted
  $script:StatusLabel.Padding = New-Object System.Windows.Forms.Padding -ArgumentList (U 20),0,(U 20),0
  $rootLayout.Controls.Add($script:StatusLabel,0,2)

  $script:Popup.Add_ResizeEnd({ Save-UiSettings })
  $script:Popup.Add_FormClosing({
    param($sender,$eventArgs)
    if (-not $script:Exiting -and $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
      $eventArgs.Cancel = $true
      $script:Popup.Hide()
      Save-UiSettings
    }
  })

  $script:Ball = New-Object CodexUsage.FloatingForm
  $script:Ball.Text = 'Codex 额度悬浮面板'
  $script:Ball.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $script:Ball.Radius = U 16
  $script:Ball.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $script:Ball.ShowInTaskbar = $false
  $script:Ball.TopMost = [bool]$script:UiSettings.topMost
  $script:Ball.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $script:Ball.ClientSize = New-Object System.Drawing.Size -ArgumentList (U 244),(U 142)
  $script:Ball.BackColor = $script:Theme.BallBack
  $script:Ball.Padding = New-Object System.Windows.Forms.Padding -ArgumentList (U 14),(U 10),(U 14),(U 10)
  if ($null -ne $script:UiSettings.ballX -and $null -ne $script:UiSettings.ballY) {
    $ballPoint = Clamp-Location -X ([int]$script:UiSettings.ballX) -Y ([int]$script:UiSettings.ballY) -Width $script:Ball.Width -Height $(if ($script:UiSettings.compactMode) { U 44 } else { $script:Ball.Height })
  } else { $ballPoint = Get-DefaultBallLocation }
  $script:Ball.Location = $ballPoint
  $script:RestLocation = $ballPoint
  $ballGrid = New-Grid -Columns 3
  [void]$ballGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute),([single](U 56))))
  foreach ($unused in 1..2) {
    [void]$ballGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]50)))
  }
  foreach ($height in @(24,34,34,30)) { Add-GridRow $ballGrid $height }
  $column = 0
  foreach ($text in @('剩余','5小时','长周期')) {
    $caption = New-Label -Text $text -Size 9 -Muted
    if ($column -gt 0) { $caption.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight }
    $ballGrid.Controls.Add($caption,$column,0)
    $column++
  }
  $row = 1
  foreach ($id in @('personal','work')) {
    $name = New-Label -Text $(if ($id -eq 'personal') { '个人' } else { '工作' }) -Size 10 -Muted
    $five = New-Label -Text '—' -Size 15 -Bold
    $long = New-Label -Text '—' -Size 15 -Bold
    $five.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $long.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $ballGrid.Controls.Add($name,0,$row)
    $ballGrid.Controls.Add($five,1,$row)
    $ballGrid.Controls.Add($long,2,$row)
    $script:BallCells[$id] = @{ name = $name; five = $five; long = $long }
    $row++
  }
  $script:BallStatus = New-Label -Text '等待首次读取' -Size 9 -Muted
  $ballGrid.Controls.Add($script:BallStatus,0,3)
  $ballGrid.SetColumnSpan($script:BallStatus,3)
  $script:Ball.Controls.Add($ballGrid)
  $script:ExpandedGrid = $ballGrid
  $script:CompactGrid = New-Grid -Columns 2
  foreach ($unused in 1..2) {
    [void]$script:CompactGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent),([single]50)))
  }
  Add-GridRow $script:CompactGrid 36
  $index = 0
  foreach ($id in @('personal','work')) {
    $label = New-Label -Text $(if ($id -eq 'personal') { '个人 —' } else { '工作 —' }) -Size 10 -Bold
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:CompactCells[$id] = $label
    $script:CompactGrid.Controls.Add($label,$index,0)
    $index++
  }
  $script:CompactGrid.Visible = $false
  $script:Ball.Controls.Add($script:CompactGrid)

  function Get-ControlTree {
    param($Control)
    $Control
    foreach ($child in $Control.Controls) { Get-ControlTree $child }
  }
  $script:BallControls = @(Get-ControlTree $script:Ball)

  $ballMouseDownHandler = {
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $sender.Capture = $true
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
      if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt (U 4)) { $script:BallDragged = $true }
      if ($script:BallDragged) {
        $script:Ball.Location = New-Object System.Drawing.Point -ArgumentList ($script:BallOrigin.X + $dx),($script:BallOrigin.Y + $dy)
      }
    }
  }
  $ballMouseUpHandler = {
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      if ($script:BallDragged) {
        Snap-Monitor
        Save-UiSettings
      } else {
        Toggle-Popup
      }
      $script:BallMouseDown = $null
      $script:BallOrigin = $null
      $script:BallDragged = $false
      $sender.Capture = $false
    }
  }

  foreach ($control in $script:BallControls) {
    $control.Add_MouseDown($ballMouseDownHandler)
    $control.Add_MouseMove($ballMouseMoveHandler)
    $control.Add_MouseUp($ballMouseUpHandler)
  }

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $script:MonitorMenu = $menu
  $itemCompact = $menu.Items.Add('紧凑模式（悬停展开）')
  $itemCompact.CheckOnClick = $true
  $itemCompact.Checked = [bool]$script:UiSettings.compactMode
  $itemCompact.Add_Click({
    $script:UiSettings.compactMode = $itemCompact.Checked
    Remember-MonitorPosition
    Set-MonitorExpanded (-not $itemCompact.Checked)
    Remember-MonitorPosition
    Save-UiSettings
  })
  $itemSnap = $menu.Items.Add('贴边吸附')
  $itemSnap.CheckOnClick = $true
  $itemSnap.Checked = [bool]$script:UiSettings.edgeSnap
  $itemSnap.Add_Click({
    $script:UiSettings.edgeSnap = $itemSnap.Checked
    Snap-Monitor
    Save-UiSettings
  })
  $notificationsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
  $notificationsMenu.Text = '低额度通知'
  $itemNotifications = $notificationsMenu.DropDownItems.Add('启用通知')
  $itemNotifications.CheckOnClick = $true
  $itemNotifications.Checked = [bool]$script:UiSettings.notificationsEnabled
  $itemNotifications.Add_Click({
    $script:UiSettings.notificationsEnabled = $itemNotifications.Checked
    $script:AlertBaselinePending = $true
    foreach ($entry in $script:AlertState.Values) { $entry.value = $null }
    Save-UiSettings
  })
  [void]$notificationsMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $script:ThresholdItems = @()
  foreach ($preset in @(@{ text = '剩余 20% / 10%'; levels = @(20,10) },@{ text = '仅剩余 10%'; levels = @(10) },@{ text = '剩余 30% / 15%'; levels = @(30,15) })) {
    $item = $notificationsMenu.DropDownItems.Add($preset.text)
    $item.Tag = $preset.levels
    $item.Checked = (($script:UiSettings.notificationThresholds -join ',') -eq ($preset.levels -join ','))
    $item.Add_Click({
      param($sender,$eventArgs)
      $script:UiSettings.notificationThresholds = @($sender.Tag)
      foreach ($choice in $script:ThresholdItems) { $choice.Checked = $choice -eq $sender }
      $script:AlertBaselinePending = $true
      foreach ($entry in $script:AlertState.Values) { $entry.value = $null }
      Save-UiSettings
    })
    $script:ThresholdItems += $item
  }
  [void]$menu.Items.Add($notificationsMenu)
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  $itemToggle = $menu.Items.Add('展开 / 收起额度面板')
  $itemRefresh = $menu.Items.Add('立即刷新')
  $itemBallVisible = $menu.Items.Add('显示悬浮面板')
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

  foreach ($control in $script:BallControls) {
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
  $script:NotifyIcon.Visible = -not $SmokeTest

  Set-MonitorExpanded (-not [bool]$script:UiSettings.compactMode)
  $script:NotifyIcon.Add_BalloonTipClicked({ $script:Popup.Show(); $script:Popup.Activate() })

  if ([bool]$script:UiSettings.ballVisible -and -not $SmokeTest) { $script:Ball.Show() }

  if ($SmokeTest) {
    Set-MonitorExpanded $true
    . (Join-Path $script:Root 'tests\ui-smoke.ps1')
    Exit-App
    return
  }

  Show-Loading
  $script:HoverTimer = New-Object System.Windows.Forms.Timer
  $script:HoverTimer.Interval = 150
  $script:HoverTimer.Add_Tick({ Update-MonitorHover })
  $script:HoverTimer.Start()
  $script:StatusTimer = New-Object System.Windows.Forms.Timer
  $script:StatusTimer.Interval = 30000
  $script:StatusTimer.Add_Tick({ Update-Status })
  $script:StatusTimer.Start()

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
  Show-FatalError ($_.Exception.ToString() + "`r`n" + $_.ScriptStackTrace)
  exit 1
}
