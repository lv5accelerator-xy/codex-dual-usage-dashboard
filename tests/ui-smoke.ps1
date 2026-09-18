# Dot-sourced only by tray.ps1 -SmokeTest, after constructing the real WinForms controls.
# No account access, network I/O, saved UI changes, or refresh worker is used.
function Assert-Ui([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw ('UI smoke test: ' + $Message) }
}
$fixtureTime = [DateTimeOffset]::Now.ToString('o')
$resetTime = [DateTimeOffset]::Now.AddHours(2).ToString('o')
$sample = [pscustomobject]@{
  fetchedAt = $fixtureTime
  profiles = @(
    [pscustomobject]@{
      id = 'personal'; label = '个人账号'; ok = $true; planType = 'Pro'; fetchedAt = $fixtureTime
      fiveHour = [pscustomobject]@{ remainingPercent = 100; resetsAt = $resetTime }
      weekly = [pscustomobject]@{ remainingPercent = 95; resetsAt = $resetTime }
      individualLimit = $null
    },
    [pscustomobject]@{
      id = 'work'; label = '工作账号'; ok = $true; planType = 'Business'; fetchedAt = $fixtureTime
      fiveHour = [pscustomobject]@{ remainingPercent = 49; resetsAt = $resetTime }
      weekly = [pscustomobject]@{ remainingPercent = 21; resetsAt = $resetTime }
      individualLimit = [pscustomobject]@{ remainingPercent = 68; limit = 100; used = 32; resetsAt = $resetTime }
    }
  )
}
$script:LastData = Merge-DisplayData $null $sample
$script:Popup.Show()
$script:Ball.Show()
Render-Data $script:LastData
[System.Windows.Forms.Application]::DoEvents()
Assert-Ui ($script:ContentPanel.Controls.Count -eq 2) 'Both account cards must render.'
Assert-Ui ($script:BallCells.personal.five.Text -eq '100%') 'Personal 5-hour summary must be visible.'
Assert-Ui ($script:BallCells.work.long.Text -eq '21%') 'Work summary must use the limiting long-term quota.'
Assert-Ui ($script:ResetLabels.Count -eq 5) 'All five meaningful quota windows must render.'
foreach ($width in @(620,440,380,620,440)) {
  $script:Popup.Width = U $width
  $script:Popup.Height = U 840
  [System.Windows.Forms.Application]::DoEvents()
  Assert-Ui (-not $script:ContentPanel.HorizontalScroll.Visible) 'Resizing must never introduce horizontal scrolling.'
  foreach ($card in $script:ContentPanel.Controls) {
    Assert-Ui ($card.Width -le $script:ContentPanel.ClientSize.Width) 'Cards must fit resized content.'
    $grid = $card.Controls[0]
    foreach ($child in $grid.Controls) {
      Assert-Ui ($child.Bottom -le $grid.ClientSize.Height) 'Rows must fit inside the account card.'
      Assert-Ui ($child.Right -le $grid.ClientSize.Width) 'Columns must fit inside the account card.'
    }
  }
}
$script:ScrollBar.Value = [Math]::Max(0,$script:ScrollBar.Maximum - $script:ScrollBar.LargeChange + 1)
[System.Windows.Forms.Application]::DoEvents()
$lastCard = $script:ContentPanel.Controls[$script:ContentPanel.Controls.Count - 1]
Assert-Ui ($lastCard.Bottom -le $script:ContentPanel.ClientSize.Height) 'Vertical scroll must reveal the last account actions.'
$script:ScrollBar.Value = 0
$script:Popup.Width = U 440
$script:Popup.Height = U 840
[System.Windows.Forms.Application]::DoEvents()
$outputDir = Join-Path $script:Root 'artifacts'
[void](New-Item -ItemType Directory -Force -Path $outputDir)
foreach ($entry in @(@{ form = $script:Popup; name = 'detail.png' },@{ form = $script:Ball; name = 'floating.png' })) {
  $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $entry.form.Width,$entry.form.Height
  try {
    $bounds = New-Object System.Drawing.Rectangle -ArgumentList 0,0,$entry.form.Width,$entry.form.Height
    $entry.form.DrawToBitmap($bitmap,$bounds)
    $bitmap.Save((Join-Path $outputDir $entry.name),[System.Drawing.Imaging.ImageFormat]::Png)
  } finally { $bitmap.Dispose() }
}
$setupPreview = Show-AccountSettings -PreviewTest
$setupPreview.Show()
[System.Windows.Forms.Application]::DoEvents()
Assert-Ui ($script:SetupRows.Count -eq 2) 'Setup page exposes both account slots.'
Assert-Ui ($script:SetupRows[0].name.MaxLength -eq 12) 'Names have a bounded readable length.'
$setupBitmap = New-Object System.Drawing.Bitmap -ArgumentList $setupPreview.Width,$setupPreview.Height
try {
  $setupPreview.DrawToBitmap($setupBitmap,(New-Object System.Drawing.Rectangle -ArgumentList 0,0,$setupPreview.Width,$setupPreview.Height))
  $setupBitmap.Save((Join-Path $outputDir 'account-setup.png'),[System.Drawing.Imaging.ImageFormat]::Png)
} finally { $setupBitmap.Dispose() }
# Exercise the real Save button against isolated files, never the user's settings.
$originalDataRoot = $script:DataRoot
$originalProfiles = $script:ProfileConfig
$saveFixture = Join-Path $outputDir ('账号保存 test ' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $saveFixture | Out-Null
try {
  $script:DataRoot = $saveFixture
  $profilePath = Join-Path $saveFixture 'profiles.json'
  Save-ProfilePreferences $originalProfiles $profilePath
  $script:SetupRows[0].name.Text = '开发账号'
  $script:SetupRows[1].enabled.Checked = $false
  $setupPreview.Controls['saveAccounts'].PerformClick()
  $saved = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-Ui ($saved.profiles[0].label -eq '开发账号') 'Real Save button persists custom names.'
  Assert-Ui (-not $saved.profiles[1].enabled) 'Real Save button persists disabled account.'
  Assert-Ui ($saved.profiles[0].codexHome -eq $originalProfiles.profiles[0].codexHome) 'Saving preserves the account home.'
  $backup = Get-Content -LiteralPath ($profilePath + '.bak') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-Ui ($backup.profiles[0].label -eq '个人') 'Atomic save preserves previous settings in backup.'
  $saved.profiles[0].label = '第二次保存'
  Save-ProfilePreferences $saved $profilePath
  $reloaded = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-Ui ($reloaded.profiles[0].label -eq '第二次保存') 'Repeated save succeeds with an existing backup.'
  Assert-Ui (@(Get-ChildItem -LiteralPath $saveFixture -Filter '*.tmp').Count -eq 0) 'Successful saves leave no temporary files.'
} finally {
  $script:DataRoot = $originalDataRoot
  $script:ProfileConfig = $originalProfiles
  $setupPreview.Close(); $setupPreview.Dispose()
  Apply-ProfileLayout
  Render-Data $script:LastData
  Remove-Item -LiteralPath $saveFixture -Recurse -Force
}
# DPI and geometry contracts without requiring multiple physical monitors.
$dpiFixture = New-Object CodexUsage.DpiForm
$dpiFixture.ClientSize = New-Object System.Drawing.Size -ArgumentList 200,100
$dpiChild = New-Object System.Windows.Forms.Label
$dpiChild.SetBounds(10,10,100,20)
$dpiFixture.Controls.Add($dpiChild)
$dpiBounds = New-Object System.Drawing.Rectangle -ArgumentList 20,20,400,200
$dpiFixture.ApplyDpi(192,$dpiBounds)
Assert-Ui ($dpiFixture.DisplayDpi -eq 192 -and $dpiChild.Width -eq 200) 'DPI transition scales child geometry.'
$dpiFixture.ApplyDpi(96,(New-Object System.Drawing.Rectangle -ArgumentList 20,20,200,100))
Assert-Ui ($dpiChild.Width -eq 100) 'DPI roundtrip restores geometry.'
$dpiFixture.Dispose()
$monitorFixture = New-Object System.Drawing.Rectangle -ArgumentList -1920,0,1920,1080
$fullscreenFixture = New-Object System.Drawing.Rectangle -ArgumentList -1920,0,1920,1080
Assert-Ui ([CodexUsage.DesktopIntegration]::IsFullScreen($fullscreenFixture,$monitorFixture)) 'Negative-coordinate full-screen monitor is detected.'
$smallFixture = New-Object System.Drawing.Rectangle -ArgumentList -1800,20,1000,700
Assert-Ui (-not [CodexUsage.DesktopIntegration]::IsFullScreen($smallFixture,$monitorFixture)) 'Normal window is not treated as full screen.'
$offscreenFixture = New-Object System.Drawing.Rectangle -ArgumentList 3000,2000,320,64
$clamped = [CodexUsage.DesktopIntegration]::Clamp($offscreenFixture,$monitorFixture)
Assert-Ui ($monitorFixture.Contains($clamped)) 'Disconnected-display window is moved into working area.'
Assert-Ui ([CodexUsage.DesktopIntegration]::StartupCommand('C:\Program Files\CodexUsage.exe') -eq '"C:\Program Files\CodexUsage.exe"') 'Startup path with spaces is quoted.'
# Compact presentation and anchor geometry use real native controls.
Assert-Ui (-not $script:UiSettings.notificationsEnabled) 'Notifications must be off by default.'
Set-MonitorExpanded $false
[System.Windows.Forms.Application]::DoEvents()
Assert-Ui ($script:Ball.Height -eq (U 64)) 'Compact mode must be a narrow strip.'
Assert-Ui ([Math]::Abs($script:Ball.Opacity - 0.8) -lt 0.01) 'Compact mode starts at 20 percent transparency.'
$script:OpacitySlider.Value = 45
Assert-Ui ($script:UiSettings.compactOpacity -eq 55) 'Slider updates the persisted opacity preference.'
Assert-Ui ([Math]::Abs($script:Ball.Opacity - 0.55) -lt 0.01) 'Slider applies opacity to the live compact window.'
Set-MonitorExpanded $true
Assert-Ui ($script:Ball.Opacity -eq 1) 'Expanded monitor restores full readability.'
Set-MonitorExpanded $false
Assert-Ui ([Math]::Abs($script:Ball.Opacity - 0.55) -lt 0.01) 'Collapsing restores the selected opacity.'
$script:OpacitySlider.Value = 0
Assert-Ui ($script:Ball.Opacity -eq 1) 'Zero transparency is fully opaque.'
$script:OpacitySlider.Value = 60
Assert-Ui ([Math]::Abs($script:Ball.Opacity - 0.4) -lt 0.01) 'Maximum transparency keeps the compact window visible.'
$script:OpacitySlider.Value = 20
Assert-Ui ($script:RefreshIntervalMs -eq 60000) 'Automatic refresh runs every minute.'

Assert-Ui ($script:CompactGrid.Visible -and -not $script:ExpandedGrid.Visible) 'Only the compact grid should be visible.'
Assert-Ui ($script:CompactCells.personal.Text -eq '个人 100% / 95%') 'Compact mode shows independent 5-hour and total percentages.'
Assert-Ui ($script:CompactCells.work.Text -eq '工作 49% / 21%') 'Compact mode preserves independent account values.'
$bitmap = New-Object System.Drawing.Bitmap -ArgumentList $script:Ball.Width,$script:Ball.Height
try {
  $bounds = New-Object System.Drawing.Rectangle -ArgumentList 0,0,$script:Ball.Width,$script:Ball.Height
  $script:Ball.DrawToBitmap($bitmap,$bounds)
  $bitmap.Save((Join-Path $outputDir 'compact.png'),[System.Drawing.Imaging.ImageFormat]::Png)
} finally { $bitmap.Dispose() }
Assert-Ui ($script:CompactCells.personal.FiveText -eq '100%') 'Native compact control exposes 5-hour text.'
$script:ProfileConfig.profiles[1].enabled = $false
Apply-ProfileLayout
Assert-Ui (-not $script:CompactCells.work.Visible) 'Disabled account is hidden.'
Assert-Ui ($script:Ball.Width -eq (B 220)) 'Single-account window shrinks.'
Set-MonitorExpanded $true
Assert-Ui ($script:Ball.Height -eq (B 108)) 'Single-account expanded window has no empty account row.'
$script:ProfileConfig.profiles[0].label = '开发'
Update-BallSummary $script:LastData
Assert-Ui ($script:CompactCells.personal.AccountName -eq '开发') 'Custom name reaches compact native control.'
$script:ProfileConfig.profiles[0].label = '个人'
$script:ProfileConfig.profiles[1].enabled = $true
Apply-ProfileLayout
Set-MonitorExpanded $false
Update-BallSummary $script:LastData
$savedFive = $script:LastData.profiles[1].fiveHour.remainingPercent
$script:LastData.profiles[1].fiveHour.remainingPercent = 0
Update-BallSummary $script:LastData
Assert-Ui ($script:CompactCells.work.Text -eq '工作 0% / 21%') 'Zero 5-hour quota keeps the independent total visible.'
Assert-Ui ($script:CompactCells.work.FiveColor -ne $script:CompactCells.work.LongColor) 'Exhausted 5h and available long-term quota use different colors.'
Assert-Ui ($script:CompactRecovery.work.Text -match '恢复') 'Exhausted account shows recovery in the compact window.'
[System.Windows.Forms.Application]::DoEvents()
$bitmap = New-Object System.Drawing.Bitmap -ArgumentList $script:Ball.Width,$script:Ball.Height
try {
  $bounds = New-Object System.Drawing.Rectangle -ArgumentList 0,0,$script:Ball.Width,$script:Ball.Height
  $script:Ball.DrawToBitmap($bitmap,$bounds)
  $bitmap.Save((Join-Path $outputDir 'compact-exhausted.png'),[System.Drawing.Imaging.ImageFormat]::Png)
} finally { $bitmap.Dispose() }
$script:LastData.profiles[1].fiveHour.remainingPercent = $savedFive
Update-BallSummary $script:LastData
$area = [System.Windows.Forms.Screen]::FromRectangle($script:Ball.Bounds).WorkingArea
$script:Ball.Location = New-Object System.Drawing.Point -ArgumentList ($area.Right - $script:Ball.Width - (U 8)),($area.Bottom - $script:Ball.Height - (U 8))
Snap-Monitor
Assert-Ui ($script:Ball.Right -eq $area.Right -and $script:Ball.Bottom -eq $area.Bottom) 'Drop near a corner must snap to the working area.'
$rest = $script:RestLocation
Set-MonitorExpanded $true
Assert-Ui ($script:Ball.Bottom -eq $area.Bottom) 'Bottom-docked hover expansion must grow upward.'
Set-MonitorExpanded $false
Assert-Ui ($script:Ball.Location -eq $rest) 'Collapsing must restore the exact resting position.'
$script:Popup.Hide()
$cursorBefore = [System.Windows.Forms.Cursor]::Position
try {
  [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point -ArgumentList ($script:Ball.Left + (U 20)),($script:Ball.Top + (U 20))
  Update-MonitorHover
  Assert-Ui $script:MonitorExpanded 'Hover must expand the compact strip.'
  [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point -ArgumentList ($area.Left + 2),($area.Top + 2)
  $script:PointerLeftAt = [DateTimeOffset]::Now.AddSeconds(-1)
  Update-MonitorHover
  Assert-Ui (-not $script:MonitorExpanded) 'Leaving the strip must collapse it after the delay.'
  $script:BallMouseDown = New-Object System.Drawing.Point -ArgumentList 0,0
  [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point -ArgumentList ($script:Ball.Left + (U 20)),($script:Ball.Top + (U 20))
  Update-MonitorHover
  Assert-Ui (-not $script:MonitorExpanded) 'Hover must not resize the window during a drag.'
} finally {
  $script:BallMouseDown = $null
  [System.Windows.Forms.Cursor]::Position = $cursorBefore
}
$itemCompact.PerformClick()
Assert-Ui ($script:MonitorExpanded -and -not $script:UiSettings.compactMode) 'Disabling compact mode keeps the full panel open.'
$itemCompact.PerformClick()
Assert-Ui (-not $script:MonitorExpanded -and $script:UiSettings.compactMode) 'Re-enabling compact mode restores the narrow strip.'
$itemNotifications.PerformClick()
Assert-Ui ($script:UiSettings.notificationsEnabled -and $script:AlertBaselinePending) 'Enabling alerts requires a new baseline.'
$script:ThresholdItems[1].PerformClick()
Assert-Ui (($script:UiSettings.notificationThresholds -join ',') -eq '10') 'Notification threshold presets must update settings.'
Assert-Ui (@($script:ThresholdItems | Where-Object { $_.Checked }).Count -eq 1) 'Exactly one notification preset is selected.'
$itemNotifications.PerformClick()
$script:Popup.Show()
Set-MonitorExpanded $true

Render-Error 'Fixture: offline'
Assert-Ui ($script:ContentPanel.Controls.Count -eq 2) 'Failed refresh must keep the existing cards.'
Assert-Ui ($script:BallCells.personal.five.Text -eq '100%') 'Failed refresh must keep last successful data.'
Assert-Ui ($script:BallStatus.Text -match '未更新') 'Floating panel must mark stale data.'
Assert-Ui ($script:CompactCells.personal.Text -match '!') 'Compact mode must also mark retained data as stale.'
$script:RefreshError = ''
$sample.profiles[1] = [pscustomobject]@{ id = 'work'; label = '工作账号'; ok = $false; error = 'Fixture: login expired' }
$script:LastData = Merge-DisplayData $script:LastData $sample
Render-Data $script:LastData
Assert-Ui ($script:BallStatus.Text -eq '工作未更新') 'One-account failure must be identified.'
Assert-Ui ($script:BallCells.work.long.Text -eq '21%') 'One-account failure must preserve its last quota.'
$script:LastData = $null
Render-Error 'Fixture: first read failed'
Assert-Ui ($script:ContentPanel.Controls.Count -eq 2) 'First-read failure must retain account login actions.'
$script:RefreshError = ''
Show-Loading
Assert-Ui ($script:ContentPanel.Controls.Count -eq 2) 'Initial loading must retain stable account layout.'
Write-Output 'Windows UI smoke test passed; fixture screenshots saved to artifacts/.'

if ($env:CODEX_USAGE_CLIENT_VERSION) {
  Assert-Ui ($script:DataRoot -ne $script:Root) 'EXE mode must separate user data from versioned application files.'
  @{ state = 'ready'; version = '99.0.0'; message = 'Fixture update ready' } | ConvertTo-Json | Set-Content $script:ClientStatusPath -Encoding UTF8
  Update-ClientStatus
  Assert-Ui $script:RestartUpdateItem.Available 'Downloaded update exposes the restart action.'
  Assert-Ui (-not $script:CheckUpdateItem.Enabled) 'Ready updates cannot start overlapping checks.'
  @{ state = 'error'; version = '99.0.0'; message = 'Fixture offline' } | ConvertTo-Json | Set-Content $script:ClientStatusPath -Encoding UTF8
  Update-ClientStatus
  Assert-Ui (-not $script:RestartUpdateItem.Available) 'Failed checks cannot expose installation actions.'
  Assert-Ui $script:CheckUpdateItem.Enabled 'Failed checks allow manual retry.'
  Remove-Item $script:ClientStatusPath -Force
}

# Accelerated lifetime regression: 180 refreshes (three hours of refresh cycles),
# status/hover callbacks, and a real WinForms message pump. No forced GC in app.
if (-not $env:CODEX_USAGE_CLIENT_VERSION) {
  function Get-MemorySample {
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    try {
      return [pscustomobject]@{ managed = [GC]::GetTotalMemory($false); private = $process.PrivateMemorySize64; handles = $process.HandleCount }
    } finally { $process.Dispose() }
  }
  $measurements = @()
  for ($cycle = 0; $cycle -lt 4; $cycle++) {
    for ($refresh = 0; $refresh -lt 60; $refresh++) {
      Render-Data $sample
      for ($tick = 0; $tick -lt 10; $tick++) { Update-Status; Update-MonitorHover }
      [System.Windows.Forms.Application]::DoEvents()
    }
    $measurement = Get-MemorySample
    $measurements += $measurement
    Write-Output ('MEMORY batch={0} managedMB={1:N1} privateMB={2:N1} handles={3}' -f $cycle,($measurement.managed/1MB),($measurement.private/1MB),$measurement.handles)
  }
  $growth = $measurements[3].managed - $measurements[0].managed
  Assert-Ui ($growth -lt 32MB) ('Retained managed heap grew by ' + [Math]::Round($growth/1MB,1) + ' MB after warmup.')
  Assert-Ui (($measurements[3].handles - $measurements[0].handles) -lt 100) 'Repeated refreshes must not leak process handles.'
}
