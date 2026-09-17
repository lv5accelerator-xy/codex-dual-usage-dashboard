# Account preferences, onboarding and desktop behavior. Dot-sourced by tray.ps1.
function Load-ProfilePreferences {
  if ($SmokeTest) {
    $script:ProfileConfig = [pscustomobject]@{ profiles = @(
      [pscustomobject]@{id='personal';label='个人';codexHome='~/.codex-personal';enabled=$true},
      [pscustomobject]@{id='work';label='工作';codexHome='~/.codex-work';enabled=$true}
    ) }
  } else {
    $script:ProfileConfig = Get-Content -LiteralPath (Join-Path $script:DataRoot 'profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  }
  $script:ProfileRevision = 0
  $script:RecoveryRequests = @{}
  $script:AutoHidden = $false
  $script:ProfileCli = $null
}
function Get-ActiveIds {
  return @($script:ProfileConfig.profiles | Where-Object { (Get-ProfileEnabled $_) -and $_.id -in @('personal','work') } | ForEach-Object { [string]$_.id })
}
function Get-AccountName {
  param([string]$Id)
  $profile = @($script:ProfileConfig.profiles | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
  if ($profile.Count -and -not [string]::IsNullOrWhiteSpace([string]$profile[0].label)) { return [string]$profile[0].label }
  if ($Id -eq 'personal') { return '个人' }
  return '工作'
}
function Get-ExpandedHeight {
  if (@(Get-ActiveIds).Count -eq 1) { return 108 }
  return 142
}
function B {
  param([double]$Value)
  $scale = if ($null -ne $script:Ball) { $script:Ball.DisplayDpi / 96.0 } else { $script:UiScale }
  return [int][Math]::Round($Value * $scale)
}
function Apply-ProfileLayout {
  $active = @(Get-ActiveIds)
  $count = [Math]::Max(1,$active.Count)
  for ($i=0; $i -lt 2; $i++) {
    $id = @('personal','work')[$i]
    $show = $id -in $active
    $script:CompactGrid.ColumnStyles[$i].Width = if ($show) { 100.0 / $count } else { 0 }
    $script:CompactCells[$id].Visible = $show
    $script:CompactRecovery[$id].Visible = $show
    foreach ($cell in $script:BallCells[$id].Values) { $cell.Visible = $show }
    $script:BallCells[$id].name.Text = Get-AccountName $id
    $script:ExpandedGrid.RowStyles[$i+1].Height = if ($show) { B 34 } else { 0 }
  }
  Set-MonitorExpanded $script:MonitorExpanded
}
function Find-SetupCli {
  if (-not [string]::IsNullOrWhiteSpace($env:CODEX_USAGE_CLIENT_PATH)) {
    try {
      [void][System.Reflection.Assembly]::LoadFrom($env:CODEX_USAGE_CLIENT_PATH)
      return [CodexUsageDesktop.UsageReader]::FindCli()
    } catch { Write-TrayLog ('CLI detection: ' + $_.Exception.Message) }
  }
  foreach ($candidate in @('codex.exe','codex.cmd')) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return [string]$command.Source }
  }
  foreach ($candidate in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'),
    (Join-Path $env:USERPROFILE '.codex\packages\standalone\current\bin\codex.exe'),
    (Join-Path $env:APPDATA 'npm\codex.cmd')
  )) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate } }
  return $null
}
function Get-SetupStatus {
  param($Profile,[string]$Cli)
  if ([string]::IsNullOrWhiteSpace($Cli)) { return '未安装 Codex CLI' }
  $current = Get-DisplayProfile $script:LastData ([string]$Profile.id)
  if ($null -ne $current -and -not (Test-ProfileStale $current)) { return '已连接' }
  $homePath = [string]$Profile.codexHome
  if ($homePath.StartsWith('~/') -or $homePath.StartsWith('~\')) { $homePath = Join-Path $env:USERPROFILE $homePath.Substring(2) }
  if (Test-Path -LiteralPath (Join-Path $homePath 'auth.json')) { return '已有登录信息 · 等待验证' }
  return '未登录'
}
function Show-AccountSettings {
  if ($SmokeTest) { return }
  $script:SetupDialog = New-Object CodexUsage.DpiForm
  $script:SetupDialog.DisplayDpi = $script:Popup.DisplayDpi
  $script:SetupDialog.Text = '账号与首次使用'
  $script:SetupDialog.Icon = $script:AppIcon
  $script:SetupDialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $script:SetupDialog.ClientSize = New-Object System.Drawing.Size -ArgumentList (U 500),(U 360)
  $script:SetupDialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $script:SetupDialog.MaximizeBox = $false
  $script:SetupDialog.MinimizeBox = $false
  $script:SetupDialog.BackColor = $script:Theme.PopupBack
  $script:SetupDialog.ForeColor = $script:Theme.TextPrimary
  $script:SetupDialog.Font = New-UiFont
  $intro = New-Label -Text '选择显示的账号并命名；每个账号独立登录。' -Size 10
  $intro.Dock = 'None'
  $intro.SetBounds((U 20),(U 16),(U 460),(U 32))
  $script:SetupDialog.Controls.Add($intro)
  $script:SetupRows = @()
  $rowIndex = 0
  foreach ($id in @('personal','work')) {
    $profile = $script:ProfileConfig.profiles | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if ($null -eq $profile) { continue }
    $enabled = New-Object System.Windows.Forms.CheckBox
    $enabled.Checked = Get-ProfileEnabled $profile
    $enabled.Text = if ($id -eq 'personal') { '账号 1' } else { '账号 2' }
    $enabled.SetBounds((U 20),(U (64+80*$rowIndex)),(U 90),(U 30))
    $name = New-Object System.Windows.Forms.TextBox
    $name.Text = Get-AccountName $id
    $name.MaxLength = 12
    $name.SetBounds((U 114),(U (64+80*$rowIndex)),(U 224),(U 30))
    $status = New-Label -Size 9 -Muted
    $status.Dock = 'None'
    $status.SetBounds((U 114),(U (98+80*$rowIndex)),(U 350),(U 26))
    $login = New-Button '安装 / 登录'
    $login.Dock = 'None'
    $login.Tag = $id
    $login.SetBounds((U 350),(U (64+80*$rowIndex)),(U 128),(U 32))
    $login.Add_Click({ param($sender,$e) Start-Login ([string]$sender.Tag) })
    $script:SetupDialog.Controls.AddRange([System.Windows.Forms.Control[]]@($enabled,$name,$status,$login))
    $script:SetupRows += @{ profile=$profile; enabled=$enabled; name=$name; status=$status; login=$login }
    $rowIndex++
  }
  $hint = New-Label -Text '安装或浏览器登录完成后，点击“重新检测”。' -Size 9 -Muted
  $hint.Dock='None'; $hint.SetBounds((U 20),(U 242),(U 460),(U 30))
  $script:SetupDialog.Controls.Add($hint)
  $detect = New-Button '重新检测'
  $detect.Dock='None'; $detect.SetBounds((U 20),(U 298),(U 120),(U 36))
  $script:SetupDialog.Controls.Add($detect)
  $apply = New-Button '保存'
  $apply.Dock='None'; $apply.SetBounds((U 358),(U 298),(U 120),(U 36))
  $script:SetupDialog.Controls.Add($apply)
  $script:RefreshSetup = {
    $cli = Find-SetupCli
    $script:ProfileCli = $cli
    foreach ($row in $script:SetupRows) {
      $row.status.Text = Get-SetupStatus $row.profile $cli
      $row.login.Text = if ([string]::IsNullOrWhiteSpace($cli)) { '安装 CLI' } else { '登录 / 切换' }
    }
  }
  $detect.Add_Click({
    & $script:RefreshSetup
    Start-Refresh
  })
  $apply.Add_Click({
    if (@($script:SetupRows | Where-Object { $_.enabled.Checked }).Count -eq 0) {
      [void][System.Windows.Forms.MessageBox]::Show('至少保留一个账号。','账号设置')
      return
    }
    try {
      $copy = $script:ProfileConfig | ConvertTo-Json -Depth 10 | ConvertFrom-Json
      foreach ($row in $script:SetupRows) {
        $profile = $copy.profiles | Where-Object { $_.id -eq $row.profile.id } | Select-Object -First 1
        $nameText = $row.name.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($nameText)) { throw '账号名称不能为空。' }
        $profile.label = $nameText
        $profile | Add-Member -NotePropertyName enabled -NotePropertyValue ([bool]$row.enabled.Checked) -Force
      }
      $path = Join-Path $script:DataRoot 'profiles.json'
      $temporary = $path + '.tmp'
      $copy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding UTF8
      [System.IO.File]::Replace($temporary,$path,$null)
      $script:ProfileConfig = $copy
      $script:ProfileRevision++
      $script:AlertBaselinePending = $true
      Apply-ProfileLayout
      if ($null -ne $script:LastData) { Render-Data $script:LastData }
      $script:SetupDialog.Close()
      Start-Refresh
    } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'无法保存账号设置') }
  })
  $statusTimer = New-Object System.Windows.Forms.Timer
  $statusTimer.Interval = 1000
  $statusTimer.Add_Tick({
    foreach ($row in $script:SetupRows) { $row.status.Text = Get-SetupStatus $row.profile $script:ProfileCli }
  })
  try {
    $script:ProfileCli = Find-SetupCli
    & $script:RefreshSetup
    $statusTimer.Start()
    [void]$script:SetupDialog.ShowDialog($script:Popup)
    $script:UiSettings.setupSeen = $true
    Save-UiSettings
  } finally { $statusTimer.Stop(); $statusTimer.Dispose(); $script:SetupDialog.Dispose() }
}
function Update-DesktopExperience {
  if ($SmokeTest -or $script:Exiting) { return }
  if ($null -eq $script:BallMouseDown) {
    $before = $script:Ball.Location
    [CodexUsage.DesktopIntegration]::KeepVisible($script:Ball)
    [CodexUsage.DesktopIntegration]::KeepVisible($script:Popup)
    if ($script:Ball.Location -ne $before) { Remember-MonitorPosition }
  }
  $hide = $script:UiSettings.hideFullscreen -and [CodexUsage.DesktopIntegration]::FullScreenOn($script:Ball)
  if ($hide -and $script:Ball.Visible) {
    $script:AutoHidden = $true
    $script:Ball.Hide()
  } elseif (-not $hide -and $script:AutoHidden) {
    $script:AutoHidden = $false
    if ($script:UiSettings.ballVisible) { $script:Ball.Show() }
  }
  if (-not $script:RefreshPending) {
    foreach ($id in @(Get-ActiveIds)) {
      $profile = Get-DisplayProfile $script:LastData $id
      $key = Get-RecoveryKey $profile
      if ($null -ne $key -and -not $script:RecoveryRequests.ContainsKey($key)) {
        $script:RecoveryRequests[$key] = $true
        Start-Refresh -Silent
        break
      }
    }
  }
}
