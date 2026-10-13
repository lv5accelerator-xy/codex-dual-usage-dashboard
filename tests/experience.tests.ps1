# Native integration fixtures: no real accounts, display changes or system sleep.
$experienceSettings = $script:UiSettings
$experienceData = $script:LastData
$experienceDpi = $script:Ball.DisplayDpi
$experienceSettingsPath = $script:UiSettingsPath
$experienceCachePath = $script:CachePath
$experienceReadRevision = $script:ReadRevision
$experienceReadId = $script:ReadId
$experienceProgressRevision = $script:LastProgressRevision
$fixtureSettingsPath = Join-Path $outputDir 'experience-settings.json'
$fixtureCachePath = Join-Path $outputDir 'experience-progress.json'
try {
  Set-MonitorExpanded $false
  Assert-Ui $script:UiSettings.clearMode 'Clear mode is enabled on first run.'
  Assert-Ui ($script:Ball.Opacity -eq 1) 'Clear mode keeps the entire monitor readable.'
  $script:OpacitySlider.Value = 60
  Assert-Ui ($script:Ball.Opacity -eq 1 -and -not $script:OpacitySlider.Enabled) 'Stored transparency cannot dim clear mode.'
  $itemClear.PerformClick()
  Assert-Ui (-not $script:UiSettings.clearMode -and $script:OpacitySlider.Enabled -and [Math]::Abs($script:Ball.Opacity - 0.4) -lt 0.01) 'Disabling clear mode restores the selected transparency.'
  $itemClear.PerformClick()
  foreach ($size in @('small','medium','large')) {
    $script:MonitorSizeItems[$size].PerformClick()
    Assert-Ui ($script:UiSettings.monitorSize -eq $size) 'Size menu updates the selected setting.'
    Assert-Ui (@($script:MonitorSizeItems.Values | Where-Object { $_.Checked }).Count -eq 1) 'Only one monitor size is selected.'
    Assert-Ui ($script:Ball.Width -eq (B 360) -and $script:Ball.Height -eq (B 64)) 'Compact geometry follows the selected size.'
    Set-MonitorExpanded $true
    Assert-Ui ($script:Ball.Height -eq (B 142)) 'Expanded geometry follows the selected size.'
    Set-MonitorExpanded $false
    $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $script:Ball.Width,$script:Ball.Height
    try {
      $script:Ball.DrawToBitmap($bitmap,(New-Object System.Drawing.Rectangle -ArgumentList 0,0,$bitmap.Width,$bitmap.Height))
      $bitmap.Save((Join-Path $outputDir ('clear-' + $size + '.png')),[System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
  }
  $itemRings.PerformClick()
  $fractional = $ringSample | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $fractional.profiles[0].fiveHour.remainingPercent = 0.4
  $fractional.profiles[0].weekly.remainingPercent = 0.2
  $script:LastData = Merge-DisplayData $null $fractional
  Render-Data $script:LastData
  Assert-Ui ($script:RingCells['personal-five'].ValueText -eq '<1%') 'Native ring preserves a positive fraction.'
  Assert-Ui ($script:BallCells.personal.five.Text -eq '<1%' -and $script:CompactCells.personal.FiveText -eq '<1%') 'Ring, expanded and compact quota formats agree.'
  Assert-Ui ($script:RingCells['personal-five'].AccessibleName -match '<1%') 'Accessibility labels preserve the fraction.'
  Assert-Ui ($script:ToolTip.GetToolTip($script:RingCells['personal-five']) -match '最近更新：') 'Each ring exposes its own last successful update.'
  foreach ($size in @('small','medium','large')) {
    Set-MonitorSize $size
    foreach ($dpi in @(96,120,144,192)) {
      $scale = (Get-MonitorSizeScale $size) * $dpi / 96
      $bounds = New-Object System.Drawing.Rectangle -ArgumentList 200,40,([int][Math]::Round(60*$scale)),([int][Math]::Round(328*$scale))
      $script:Ball.ApplyDpi($dpi,$bounds)
      [System.Windows.Forms.Application]::DoEvents()
      Assert-Ui ($script:Ball.Width -eq (B 60) -and $script:Ball.Height -eq (B 328)) ('Size and DPI compose into fitted geometry: ' + $size + '/' + $dpi + ', actual=' + $script:Ball.ClientSize + ', expected=' + (B 60) + 'x' + (B 328))
      $currentArea = [System.Windows.Forms.Screen]::FromRectangle($script:Ball.Bounds).WorkingArea
      Assert-Ui ($currentArea.Contains($script:Ball.Bounds) -and $script:UiSettings.monitorSize -eq $size) 'Automatic fitting keeps the whole window visible without changing the saved preference.'
      foreach ($ring in $script:RingCells.Values) { Assert-Ui ($script:RingPanel.ClientRectangle.Contains($ring.Bounds)) 'All rings fit after a size/DPI transition.' }
      $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $script:Ball.Width,$script:Ball.Height
      try {
        $script:Ball.DrawToBitmap($bitmap,(New-Object System.Drawing.Rectangle -ArgumentList 0,0,$bitmap.Width,$bitmap.Height))
        $bitmap.Save((Join-Path $outputDir ('rings-' + $size + '-' + $dpi + '.png')),[System.Drawing.Imaging.ImageFormat]::Png)
      } finally { $bitmap.Dispose() }
    }
  }
  # Negative-coordinate secondary display, removal and reduced resolution.
  $primary = New-Object System.Drawing.Rectangle -ArgumentList 0,0,1920,1040
  $secondary = New-Object System.Drawing.Rectangle -ArgumentList -2560,0,2560,1400
  $saved = New-Object System.Drawing.Rectangle -ArgumentList -2500,100,84,460
  $areas = [System.Drawing.Rectangle[]]@($primary,$secondary)
  Assert-Ui ([CodexUsage.DesktopIntegration]::RestorePlacement($saved,$areas) -eq $saved) 'Connected secondary-display placement is preserved.'
  $restored = [CodexUsage.DesktopIntegration]::RestorePlacement($saved,[System.Drawing.Rectangle[]]@($primary))
  Assert-Ui ($primary.Contains($restored)) 'Removing the saved display restores the window to a connected display.'
  $reduced = New-Object System.Drawing.Rectangle -ArgumentList 0,0,1280,680
  $oldBounds = New-Object System.Drawing.Rectangle -ArgumentList 1800,900,84,460
  Assert-Ui ($reduced.Contains([CodexUsage.DesktopIntegration]::RestorePlacement($oldBounds,[System.Drawing.Rectangle[]]@($reduced)))) 'Resolution reduction preserves complete visibility.'
  Assert-Ui ([CodexUsage.DesktopIntegration]::RestorePlacement($saved,[System.Drawing.Rectangle[]]@()) -eq $saved) 'Transient missing display data does not move the window.'
  $script:Ball.NotifyDisplayEnvironmentChanged($false)
  Assert-Ui $script:DesktopRecoveryPending 'Display-change messages schedule layout recovery.'
  $script:Ball.Location = New-Object System.Drawing.Point -ArgumentList 99999,99999
  Restore-DesktopLayout
  $area = [System.Windows.Forms.Screen]::FromRectangle($script:Ball.Bounds).WorkingArea
  Assert-Ui ($area.Contains($script:Ball.Bounds) -and -not $script:DesktopRecoveryPending) 'Actual native window recovery stays inside the current working area.'
  $script:Ball.NotifyDisplayEnvironmentChanged($true)
  Assert-Ui $script:ResumeRefreshRequested 'Resume messages request fresh account data.'
  Restore-DesktopLayout
  Assert-Ui (-not $script:ResumeRefreshRequested -and -not $script:RefreshPending) 'Resume recovery clears obsolete in-flight state without test account access.'
  # Save/reload into a fixture directory; never use the installed preferences.
  $script:UiSettingsPath = $fixtureSettingsPath
  $SmokeTest = $false
  try {
    Save-UiSettings
    $reloaded = Load-UiSettings
    Assert-Ui ($reloaded.monitorSize -eq 'large' -and $reloaded.clearMode -and $reloaded.ringMode) 'Size, clarity and ring mode survive saved-settings reload.'
    Assert-Ui ($reloaded.ballX -eq $script:RestLocation.X -and $reloaded.ballY -eq $script:RestLocation.Y) 'Recovered window position survives reload.'
    $restart = New-Object CodexUsage.FloatingForm
    $restart.FormBorderStyle = 'None'
    $restart.ShowInTaskbar = $false
    $restart.StartPosition = 'Manual'
    $restart.ClientSize = New-Object System.Drawing.Size -ArgumentList (B 60),(B 328)
    $restart.Location = New-Object System.Drawing.Point -ArgumentList $reloaded.ballX,$reloaded.ballY
    try {
      $restart.Show()
      Assert-Ui ($restart.ClientSize.Width -eq (B 60)) 'Recreated window keeps the saved size on first show.'
    } finally { $restart.Close(); $restart.Dispose() }
  } finally { $SmokeTest = $true }
  # Publish one account before another completes, then ignore duplicate/reconfigured results.
  $script:CachePath = $fixtureCachePath
  $script:ReadRevision = $script:ProfileRevision
  $script:ReadId = 'fixture-new-read'
  $script:LastProgressRevision = -1
  $script:LastData = Merge-DisplayData $null $ringSample
  $partial = $ringSample | ConvertTo-Json -Depth 10 | ConvertFrom-Json
  $partial.profiles[0] = [pscustomobject]@{id='personal';label='个人账号';ok=$false;pending=$true;error=''}
  $partial.profiles[1].fiveHour.remainingPercent = 0.4
  @{ok=$true;readId=$script:ReadId;pending=$true;revision=1;data=$partial} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $fixtureCachePath -Encoding UTF8
  Read-RefreshProgress
  Assert-Ui ($script:BallCells.work.five.Text -eq '<1%' -and $script:BallCells.personal.five.Text -eq '100%') 'Fast account refresh displays immediately while preserving the pending account.'
  Assert-Ui ((Get-DisplayProfile $script:LastData 'personal').pending -and -not (Test-ProfileStale (Get-DisplayProfile $script:LastData 'personal'))) 'Fresh retained values are not marked as failures while reading.'
  $cardBefore = $script:ContentPanel.Controls[0]
  Read-RefreshProgress
  Assert-Ui ([object]::ReferenceEquals($cardBefore,$script:ContentPanel.Controls[0])) 'Duplicate progress does not rebuild cards.'
  $script:ReadRevision = $script:ProfileRevision - 1
  $partial.profiles[1].fiveHour.remainingPercent = 10
  @{ok=$true;readId=$script:ReadId;pending=$false;revision=2;data=$partial} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $fixtureCachePath -Encoding UTF8
  Read-RefreshProgress
  Assert-Ui ($script:BallCells.work.five.Text -eq '<1%') 'Old account-configuration results are ignored.'
  $script:ReadRevision = $script:ProfileRevision
  @{ok=$true;readId='fixture-old-read';pending=$false;revision=2;data=$partial} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $fixtureCachePath -Encoding UTF8
  Read-RefreshProgress
  Assert-Ui ($script:BallCells.work.five.Text -eq '<1%') 'Results from a cancelled pre-resume reader are ignored.'
} finally {
  $SmokeTest = $true
  $script:UiSettingsPath = $experienceSettingsPath
  $script:CachePath = $experienceCachePath
  $script:ReadRevision = $experienceReadRevision
  $script:ReadId = $experienceReadId
  $script:LastProgressRevision = $experienceProgressRevision
  $script:UiSettings = $experienceSettings
  $script:DesktopRecoveryPending = $false
  $script:ResumeRefreshRequested = $false
  if ($script:UiSettings.ringMode) { $itemRings.PerformClick() }
  Set-MonitorSize 'small'
  $script:Ball.ApplyDpi($experienceDpi,(New-Object System.Drawing.Rectangle -ArgumentList 200,40,([int](360*$experienceDpi/96)),([int](64*$experienceDpi/96))))
  $script:LastData = $experienceData
  Render-Data $script:LastData
  $script:UiSettings.clearMode = $false
  $itemClear.Checked = $false
  $script:OpacitySlider.Value = 20
  Update-MonitorOpacity
  foreach ($fixturePath in @($fixtureSettingsPath,$fixtureCachePath)) { Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue }
}
Write-Output 'Experience: sizes, clarity, fractions, display/resume recovery, restart and partial refresh passed.'
