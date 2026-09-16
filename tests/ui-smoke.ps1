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
foreach ($width in @(380,440,620)) {
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
Render-Error 'Fixture: offline'
Assert-Ui ($script:ContentPanel.Controls.Count -eq 2) 'Failed refresh must keep the existing cards.'
Assert-Ui ($script:BallCells.personal.five.Text -eq '100%') 'Failed refresh must keep last successful data.'
Assert-Ui ($script:BallStatus.Text -match '未更新') 'Floating panel must mark stale data.'
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
