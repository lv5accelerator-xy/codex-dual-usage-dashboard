# Cross-device Codex completion notification UI/lifecycle. Dot-sourced by tray.ps1.
$script:RemoteSettingsPath = Join-Path $script:DataRoot 'remote-notifications.json'
$script:RemoteInboxPath = Join-Path $script:DataRoot 'remote-inbox.jsonl'
$script:RemoteStatusPath = Join-Path $script:DataRoot 'remote-worker-status.json'
$script:RemoteNotifiedPath = Join-Path $script:DataRoot 'remote-notified.json'
$script:RemoteTestRequestPath = Join-Path $script:DataRoot 'remote-test.request'
$script:RemoteWorkerProcess = $null
$script:RemoteSettings = $null
$script:RemoteNotified = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::Ordinal)
$script:RemoteLastEnsure = [DateTimeOffset]::MinValue

function New-RemotePairKey {
  $bytes = New-Object byte[] 18
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return ([Convert]::ToBase64String($bytes)).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Get-DefaultRemoteSettings {
  return [pscustomobject]@{
    enabled = $false
    deviceId = [Guid]::NewGuid().ToString('N')
    deviceName = $env:COMPUTERNAME
    pairKey = ''
    includeSummary = $false
    relayUrl = 'https://ntfy.sh'
  }
}

function Save-RemoteSettings {
  param($Settings)
  $json = $Settings | ConvertTo-Json -Depth 6
  $tmp = $script:RemoteSettingsPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  try {
    [System.IO.File]::WriteAllText($tmp,$json,(New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $script:RemoteSettingsPath) {
      [System.IO.File]::Replace($tmp,$script:RemoteSettingsPath,($script:RemoteSettingsPath + '.bak'))
    } else {
      [System.IO.File]::Move($tmp,$script:RemoteSettingsPath)
    }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
}

function Load-RemoteSettings {
  if ($SmokeTest) {
    $script:RemoteSettings = Get-DefaultRemoteSettings
    $script:RemoteSettings.deviceName = '测试电脑'
    return
  }
  if (Test-Path -LiteralPath $script:RemoteSettingsPath) {
    try { $loaded = Get-Content -LiteralPath $script:RemoteSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-TrayLog ('Remote settings load warning: ' + $_.Exception.Message); $loaded = $null }
  } else { $loaded = $null }
  if ($null -eq $loaded) {
    $loaded = Get-DefaultRemoteSettings
    Save-RemoteSettings $loaded
  }
  foreach ($name in @('enabled','deviceId','deviceName','pairKey','includeSummary','relayUrl')) {
    if ($loaded.PSObject.Properties.Name -notcontains $name) {
      $defaults = Get-DefaultRemoteSettings
      $loaded | Add-Member -NotePropertyName $name -NotePropertyValue $defaults.$name -Force
    }
  }
  if ([string]::IsNullOrWhiteSpace([string]$loaded.deviceId)) { $loaded.deviceId = [Guid]::NewGuid().ToString('N') }
  if ([string]::IsNullOrWhiteSpace([string]$loaded.deviceName)) { $loaded.deviceName = $env:COMPUTERNAME }
  if ([string]::IsNullOrWhiteSpace([string]$loaded.relayUrl)) { $loaded.relayUrl = 'https://ntfy.sh' }
  $script:RemoteSettings = $loaded
  Save-RemoteSettings $loaded
}

function Load-RemoteNotified {
  if ($SmokeTest -or -not (Test-Path -LiteralPath $script:RemoteNotifiedPath)) { return }
  try {
    $ids = Get-Content -LiteralPath $script:RemoteNotifiedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($id in @($ids)) { if (-not [string]::IsNullOrWhiteSpace([string]$id)) { [void]$script:RemoteNotified.Add([string]$id) } }
  } catch { Write-TrayLog ('Remote notification ledger warning: ' + $_.Exception.Message) }
}

function Save-RemoteNotified {
  if ($SmokeTest) { return }
  try {
    $ids = @($script:RemoteNotified)
    if ($ids.Count -gt 300) { $ids = @($ids | Select-Object -Last 300) }
    [System.IO.File]::WriteAllText($script:RemoteNotifiedPath,($ids | ConvertTo-Json -Depth 2),(New-Object System.Text.UTF8Encoding($false)))
  } catch { Write-TrayLog ('Remote notification ledger save warning: ' + $_.Exception.Message) }
}

function Stop-RemoteWorker {
  if ($null -eq $script:RemoteWorkerProcess) { return }
  try { if (-not $script:RemoteWorkerProcess.HasExited) { $script:RemoteWorkerProcess.Kill() } } catch {}
  try { $script:RemoteWorkerProcess.Dispose() } catch {}
  $script:RemoteWorkerProcess = $null
}

function Start-RemoteWorker {
  if ($SmokeTest -or $script:Exiting -or $null -eq $script:RemoteSettings -or -not [bool]$script:RemoteSettings.enabled) { return }
  if ([string]::IsNullOrWhiteSpace([string]$script:RemoteSettings.pairKey)) { return }
  if ($null -ne $script:RemoteWorkerProcess) {
    try { if (-not $script:RemoteWorkerProcess.HasExited) { return } } catch {}
    Stop-RemoteWorker
  }
  try {
    $worker = Join-Path $script:Root 'remote-worker.ps1'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psi.FileName)) { $psi.FileName = 'powershell.exe' }
    $psi.Arguments = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -DataRoot "{1}"' -f $worker,$script:DataRoot)
    $psi.WorkingDirectory = $script:Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:RemoteWorkerProcess = New-Object System.Diagnostics.Process
    $script:RemoteWorkerProcess.StartInfo = $psi
    if (-not $script:RemoteWorkerProcess.Start()) { throw '无法启动远程通知后台进程。' }
    Write-TrayLog ('Remote worker PID: ' + $script:RemoteWorkerProcess.Id)
  } catch {
    Stop-RemoteWorker
    Write-TrayLog ('Remote worker start warning: ' + $_.Exception.Message)
  }
}

function Restart-RemoteWorker {
  Stop-RemoteWorker
  Start-Sleep -Milliseconds 150
  Start-RemoteWorker
}

function Get-RemoteWorkerStatusText {
  if ($null -eq $script:RemoteSettings -or -not [bool]$script:RemoteSettings.enabled) { return '未启用' }
  if ([string]::IsNullOrWhiteSpace([string]$script:RemoteSettings.pairKey)) { return '需要配对密钥' }
  try {
    if (Test-Path -LiteralPath $script:RemoteStatusPath) {
      $status = Get-Content -LiteralPath $script:RemoteStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
      return [string]$status.message
    }
  } catch {}
  return '正在启动监听…'
}

function Process-RemoteInbox {
  if ($SmokeTest -or -not (Test-Path -LiteralPath $script:RemoteInboxPath)) { return }
  try {
    $changed = $false
    foreach ($line in @(Get-Content -LiteralPath $script:RemoteInboxPath -Tail 200 -Encoding UTF8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $event = $line | ConvertFrom-Json } catch { continue }
      $id = [string]$event.id
      if ([string]::IsNullOrWhiteSpace($id) -or $script:RemoteNotified.Contains($id)) { continue }
      [void]$script:RemoteNotified.Add($id)
      $changed = $true
      $device = if ([string]::IsNullOrWhiteSpace([string]$event.deviceName)) { '另一台电脑' } else { [string]$event.deviceName }
      $project = if ([string]::IsNullOrWhiteSpace([string]$event.project)) { 'Codex 会话' } else { [string]$event.project }
      $failed = [string]$event.status -eq 'error'
      $title = if ($failed) { 'Codex 施工需要检查 · ' + $device } else { 'Codex 施工完成 · ' + $device }
      $body = $project
      if (-not [string]::IsNullOrWhiteSpace([string]$event.summary)) { $body += [Environment]::NewLine + [string]$event.summary }
      $icon = if ($failed) { [System.Windows.Forms.ToolTipIcon]::Warning } else { [System.Windows.Forms.ToolTipIcon]::Info }
      $script:NotifyIcon.ShowBalloonTip(10000,$title,$body,$icon)
      Write-TrayLog ('Remote completion shown: ' + $id)
    }
    if ($changed) { Save-RemoteNotified }
  } catch { Write-TrayLog ('Remote inbox warning: ' + $_.Exception.Message) }
}

function Update-RemoteNotifications {
  if ($SmokeTest -or $script:Exiting) { return }
  Process-RemoteInbox
  $now = [DateTimeOffset]::UtcNow
  if (($now - $script:RemoteLastEnsure).TotalSeconds -lt 5) { return }
  $script:RemoteLastEnsure = $now
  if ($null -ne $script:RemoteSettings -and [bool]$script:RemoteSettings.enabled) { Start-RemoteWorker }
}

function Show-RemoteNotificationSettings {
  if ($SmokeTest) { return }
  $dialog = New-Object CodexUsage.DpiForm
  $dialog.DisplayDpi = $script:Popup.DisplayDpi
  $dialog.Text = '跨电脑 Codex 完成通知'
  $dialog.Icon = $script:AppIcon
  $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dialog.ClientSize = New-Object System.Drawing.Size -ArgumentList (U 540),(U 430)
  $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $dialog.MaximizeBox = $false
  $dialog.MinimizeBox = $false
  $dialog.BackColor = $script:Theme.PopupBack
  $dialog.ForeColor = $script:Theme.TextPrimary
  $dialog.Font = New-UiFont

  $enabled = New-Object System.Windows.Forms.CheckBox
  $enabled.Text = '启用跨电脑完成通知'
  $enabled.Checked = [bool]$script:RemoteSettings.enabled
  $enabled.SetBounds((U 20),(U 18),(U 260),(U 30))

  $nameLabel = New-Label -Text '本机名称' -Size 9 -Muted
  $nameLabel.Dock='None'; $nameLabel.SetBounds((U 20),(U 64),(U 100),(U 28))
  $name = New-Object System.Windows.Forms.TextBox
  $name.Text = [string]$script:RemoteSettings.deviceName
  $name.MaxLength = 40
  $name.SetBounds((U 130),(U 62),(U 380),(U 30))

  $keyLabel = New-Label -Text '配对密钥' -Size 9 -Muted
  $keyLabel.Dock='None'; $keyLabel.SetBounds((U 20),(U 108),(U 100),(U 28))
  $key = New-Object System.Windows.Forms.TextBox
  $key.Text = [string]$script:RemoteSettings.pairKey
  $key.SetBounds((U 130),(U 106),(U 270),(U 30))
  $generate = New-Button '生成'
  $generate.Dock='None'; $generate.SetBounds((U 410),(U 106),(U 100),(U 30))
  $generate.Add_Click({ $key.Text = New-RemotePairKey })

  $summary = New-Object System.Windows.Forms.CheckBox
  $summary.Text = '通知中包含 Codex 最终回复摘要（最多 800 字）'
  $summary.Checked = [bool]$script:RemoteSettings.includeSummary
  $summary.SetBounds((U 130),(U 150),(U 380),(U 30))

  $relayLabel = New-Label -Text '中继地址' -Size 9 -Muted
  $relayLabel.Dock='None'; $relayLabel.SetBounds((U 20),(U 194),(U 100),(U 28))
  $relay = New-Object System.Windows.Forms.TextBox
  $relay.Text = [string]$script:RemoteSettings.relayUrl
  $relay.SetBounds((U 130),(U 192),(U 380),(U 30))

  $privacy = New-Label -Text '两台电脑填写同一配对密钥即可互相通知。消息正文会先在本机加密；默认只发送设备名、项目名、状态与时间。' -Size 9 -Muted
  $privacy.Dock='None'; $privacy.SetBounds((U 20),(U 238),(U 490),(U 56))

  $statusLabel = New-Label -Text ('状态：' + (Get-RemoteWorkerStatusText)) -Size 9 -Muted
  $statusLabel.Dock='None'; $statusLabel.SetBounds((U 20),(U 300),(U 490),(U 30))

  $test = New-Button '发送测试通知'
  $test.Dock='None'; $test.SetBounds((U 20),(U 362),(U 140),(U 36))
  $save = New-Button '保存'
  $save.Dock='None'; $save.SetBounds((U 390),(U 362),(U 120),(U 36))

  $test.Add_Click({
    if (-not [bool]$script:RemoteSettings.enabled -or [string]::IsNullOrWhiteSpace([string]$script:RemoteSettings.pairKey)) {
      [void][System.Windows.Forms.MessageBox]::Show('请先保存并启用跨电脑通知。','跨电脑通知')
      return
    }
    Set-Content -LiteralPath $script:RemoteTestRequestPath -Value 'test' -Encoding ASCII
    [void][System.Windows.Forms.MessageBox]::Show('测试事件已交给后台发送。另一台已配对电脑应收到通知。','跨电脑通知')
  })

  $save.Add_Click({
    try {
      $deviceName = $name.Text.Trim()
      $pairKey = $key.Text.Trim()
      $relayUrl = $relay.Text.Trim()
      if ([string]::IsNullOrWhiteSpace($deviceName)) { throw '本机名称不能为空。' }
      if ($enabled.Checked -and $pairKey.Length -lt 12) { throw '启用时配对密钥至少需要 12 个字符。' }
      $uri = $null
      if (-not [Uri]::TryCreate($relayUrl,[UriKind]::Absolute,[ref]$uri)) { throw '中继地址无效。' }
      if ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback)) { throw '中继地址必须使用 HTTPS；只有 localhost 可用 HTTP。' }
      $copy = [pscustomobject]@{
        enabled = [bool]$enabled.Checked
        deviceId = [string]$script:RemoteSettings.deviceId
        deviceName = $deviceName
        pairKey = $pairKey
        includeSummary = [bool]$summary.Checked
        relayUrl = $relayUrl.TrimEnd('/')
      }
      Save-RemoteSettings $copy
      $script:RemoteSettings = $copy
      Restart-RemoteWorker
      $dialog.Close()
    } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'无法保存跨电脑通知') }
  })

  $dialog.Controls.AddRange([System.Windows.Forms.Control[]]@(
    $enabled,$nameLabel,$name,$keyLabel,$key,$generate,$summary,$relayLabel,$relay,$privacy,$statusLabel,$test,$save
  ))
  try { [void]$dialog.ShowDialog($script:Popup) } finally { $dialog.Dispose() }
}

function Initialize-RemoteNotifications {
  Load-RemoteSettings
  Load-RemoteNotified
}
