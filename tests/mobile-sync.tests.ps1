$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'ui-model.ps1')
. (Join-Path $root 'remote-crypto.ps1')
. (Join-Path $root 'mobile-sync.ps1')
$script:Checks = 0

function Assert-Mobile([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw ('Mobile sync test: ' + $Message) }
  $script:Checks++
}

$vector = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\mobile-crypto-vector.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Mobile ((Get-RemoteTopic $vector.pairKey) -eq $vector.completionTopic) 'Existing completion topic must remain byte-for-byte stable.'
Assert-Mobile ((Get-MobileUsageTopic $vector.pairKey) -eq $vector.usageTopic) 'Usage topic derivation must match the shared vector.'
Assert-Mobile ((Get-MobileUsageTopic ($vector.pairKey + '-other')) -ne $vector.usageTopic) 'Different pair keys need different usage topics.'
Assert-Mobile ((Get-MobileUsageTopic $vector.pairKey) -ne (Get-RemoteTopic $vector.pairKey)) 'Usage and completion topics must remain separate.'
$iv = New-Object byte[] 16
for ($i = 0; $i -lt 16; $i++) { $iv[$i] = [byte]$i }
$cipher = Protect-RemoteMessageTestVector -PlainText $vector.plainText -PairKey $vector.pairKey -InitializationVector $iv
Assert-Mobile ($cipher -eq $vector.cipherText) 'PowerShell deterministic encryption must match the cross-runtime fixture.'
Assert-Mobile ((Unprotect-RemoteMessage -CipherText $cipher -PairKey $vector.pairKey) -eq $vector.plainText) 'PowerShell fixture must decrypt.'

$now = [DateTimeOffset]::Parse('2026-09-28T12:00:00Z')
$personal = [pscustomobject]@{
  id='personal'; label='Personal'; enabled=$true; ok=$true; stale=$false; fetchedAt=$now.AddSeconds(-30).ToString('o')
  codexHome='C:\Users\secret\.codex-personal'; accountId='account-secret'; accessToken='token-secret'; refreshToken='refresh-secret'; token='generic-secret'; cookies='cookie-secret'; sessionPath='C:\Users\secret\sessions'
  fiveHour=[pscustomobject]@{ remainingPercent=82; resetsAt=$now.AddHours(2).ToString('o') }
  weekly=[pscustomobject]@{ remainingPercent=63; resetsAt=$now.AddDays(4).ToString('o') }
  individualLimit=[pscustomobject]@{ limit=100; remainingPercent=71; resetsAt=$now.AddDays(20).ToString('o') }
}
$work = [pscustomobject]@{
  id='work'; label='Work'; enabled=$true; ok=$true; stale=$false; fetchedAt=$now.ToString('o')
  fiveHour=[pscustomobject]@{ remainingPercent=41; resetsAt=$now.AddHours(4).ToString('o') }
  weekly=[pscustomobject]@{ remainingPercent=52; resetsAt=$now.AddDays(6).ToString('o') }
  individualLimit=[pscustomobject]@{ limit=100; remainingPercent=27; resetsAt=$now.AddDays(2).ToString('o') }
}
$disabled = [pscustomobject]@{ id='other'; label='Disabled'; enabled=$false; ok=$true; codexHome='C:\secret' }
$settings = [pscustomobject]@{ enabled=$false; usageSyncEnabled=$true; deviceId='device-1'; deviceName='Office PC'; pairKey=$vector.pairKey }
$snapshot = New-MobileUsageSnapshot -Data ([pscustomobject]@{ profiles=@($personal,$work,$disabled) }) -Settings $settings -Now $now
$json = $snapshot | ConvertTo-Json -Compress -Depth 12
Assert-Mobile (@($snapshot.profiles).Count -eq 2) 'Disabled or unknown profiles must not be exported.'
Assert-Mobile ($snapshot.profiles[0].longTerm.kind -eq 'weekly' -and $snapshot.profiles[0].longTerm.remainingPercent -eq 63) 'Weekly must win when it is more limiting.'
Assert-Mobile ($snapshot.profiles[1].longTerm.kind -eq 'workspace' -and $snapshot.profiles[1].longTerm.remainingPercent -eq 27) 'Workspace must win when it is more limiting.'
foreach ($forbidden in @('codexHome','accountId','accessToken','refreshToken','token','cookies','sessionPath','auth.json','C:\Users\secret','token-secret','refresh-secret','generic-secret','cookie-secret')) {
  Assert-Mobile (-not $json.Contains($forbidden)) ('Snapshot must exclude ' + $forbidden)
}
$weeklyOnly = [pscustomobject]@{ weekly=$personal.weekly; individualLimit=$null }
$workspaceOnly = [pscustomobject]@{ weekly=$null; individualLimit=[pscustomobject]@{ limit=1; remainingPercent=0; resetsAt=$now.AddMinutes(-1).ToString('o') } }
$missingLong = [pscustomobject]@{ weekly=$null; individualLimit=$null }
Assert-Mobile ((Get-MobileLongTermWindow $weeklyOnly).kind -eq 'weekly') 'Weekly-only profiles must export weekly.'
Assert-Mobile ((Get-MobileLongTermWindow $workspaceOnly).remainingPercent -eq 0) 'Workspace-only zero percent must not become missing.'
Assert-Mobile ((Get-MobileLongTermWindow $workspaceOnly).resetsAt -eq $workspaceOnly.individualLimit.resetsAt) 'Expired reset timestamps must be preserved for browser confirmation logic.'
Assert-Mobile ($null -eq (Get-MobileLongTermWindow $missingLong)) 'Missing long-term windows must remain missing.'
$personal.stale = $true
$staleSnapshot = New-MobileUsageSnapshot -Data ([pscustomobject]@{ profiles=@($personal) }) -Settings $settings -Now $now
Assert-Mobile (-not [bool]$staleSnapshot.profiles[0].ok) 'Stale desktop data must be marked unavailable on mobile.'
$personal.stale = $false

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-mobile-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
  $pending = Join-Path $temp 'mobile-usage-pending.json'
  Assert-Mobile (Write-MobileUsagePending -Data ([pscustomobject]@{ profiles=@($personal) }) -Settings $settings -Path $pending) 'Enabled sync must queue a snapshot.'
  Assert-Mobile (Test-Path -LiteralPath $pending) 'Pending snapshot must be written atomically.'
  $settings.usageSyncEnabled = $false
  Remove-Item -LiteralPath $pending -Force
  Assert-Mobile (-not (Write-MobileUsagePending -Data ([pscustomobject]@{ profiles=@($personal) }) -Settings $settings -Path $pending)) 'Disabled sync must not queue data.'
  Assert-Mobile (-not (Test-Path -LiteralPath $pending)) 'Disabled sync must not create a pending file.'

  $hash = Get-MobileUsageSnapshotHash $snapshot
  $state = [pscustomobject]@{ lastPublishedHash=$hash; lastPublishedAt=$now.ToString('o') }
  Assert-Mobile (-not (Test-MobileUsagePublishDue -CurrentHash $hash -State $state -Now $now.AddMinutes(4))) 'Unchanged data must be suppressed before heartbeat.'
  Assert-Mobile (Test-MobileUsagePublishDue -CurrentHash $hash -State $state -Now $now.AddMinutes(5)) 'Heartbeat must publish unchanged data after five minutes.'
  Assert-Mobile (Test-MobileUsagePublishDue -CurrentHash ('0' * 64) -State $state -Now $now.AddMinutes(1)) 'Changed data must publish immediately.'
  Assert-Mobile (Test-MobileUsagePublishDue -CurrentHash $hash -State $state -Now $now.AddMinutes(1) -CurrentTopic 'new-topic') 'Pairing-key rotation must publish immediately to the new topic.'

  # A legacy settings file has no usageSyncEnabled property. Loading must add false without changing enabled.
  $script:DataRoot = $temp
  $script:Root = $root
  $script:Exiting = $false
  $SmokeTest = $false
  function Write-TrayLog { param([string]$Message) }
  [System.IO.File]::WriteAllText((Join-Path $temp 'remote-notifications.json'),'{"enabled":true,"deviceId":"old-device","deviceName":"Old PC","pairKey":"old-pair-key-123","includeSummary":false,"relayUrl":"https://ntfy.sh"}',(New-Object System.Text.UTF8Encoding($false)))
  . (Join-Path $root 'remote-ui.ps1')
  Load-RemoteSettings
  Assert-Mobile ([bool]$script:RemoteSettings.enabled) 'Legacy completion enablement must be preserved.'
  Assert-Mobile (-not [bool]$script:RemoteSettings.usageSyncEnabled) 'Legacy settings must migrate with usage sync off.'

  . (Join-Path $root 'remote-worker.ps1') -DataRoot $temp -LibraryOnly
  Assert-Mobile (Test-RemoteWorkerSettingsEnabled ([pscustomobject]@{ enabled=$false; usageSyncEnabled=$true; pairKey='123456789012'; deviceId='device' })) 'Usage-only settings must start the remote worker.'
  Assert-Mobile (-not (Test-RemoteWorkerSettingsEnabled ([pscustomobject]@{ enabled=$false; usageSyncEnabled=$false; pairKey='123456789012'; deviceId='device' }))) 'Both features disabled must not start the worker.'

  $usageOnly = [ordered]@{ enabled=$false; usageSyncEnabled=$true; deviceId='actual-worker'; deviceName='Fixture PC'; pairKey='123456789012'; includeSummary=$false; relayUrl='https://ntfy.sh' }
  Write-AtomicUtf8Json -Path (Join-Path $temp 'remote-notifications.json') -Value $usageOnly -Depth 4
  $powershell = Join-Path $PSHOME 'powershell.exe'
  $worker = Start-Process -FilePath $powershell -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $root 'remote-worker.ps1') + '"'),'-DataRoot',('"' + $temp + '"')) -PassThru -WindowStyle Hidden
  try {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath (Join-Path $temp 'mobile-usage-status.json')) -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Assert-Mobile (-not $worker.HasExited) 'A usage-only worker must remain running.'
    $actualStatus = Get-Content -LiteralPath (Join-Path $temp 'mobile-usage-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Mobile ([string]$actualStatus.state -eq 'waiting') 'A usage-only worker must wait for its first desktop snapshot.'
    $workerLog = Get-Content -LiteralPath (Join-Path $temp 'logs\remote-worker.log') -Raw -ErrorAction SilentlyContinue
    Assert-Mobile ([string]::IsNullOrEmpty($workerLog) -or -not $workerLog.Contains('Watching ')) 'Usage-only mode must not scan Codex session JSONL files.'
  } finally {
    if (-not $worker.HasExited) { $worker.Kill(); [void]$worker.WaitForExit(5000) }
    $worker.Dispose()
  }

  $syncSource = Get-Content -LiteralPath (Join-Path $root 'mobile-sync.ps1') -Raw -Encoding UTF8
  $traySource = Get-Content -LiteralPath (Join-Path $root 'tray.ps1') -Raw -Encoding UTF8
  Assert-Mobile (-not $syncSource.Contains('Invoke-WebRequest')) 'Desktop snapshot queue must contain no network call.'
  Assert-Mobile ($traySource -match "try \{ \[void\]\(Write-MobileUsagePending") 'Desktop refresh must isolate queue failures.'
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "Mobile sync: $script:Checks checks passed."
