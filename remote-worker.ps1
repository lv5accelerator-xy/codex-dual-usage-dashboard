param(
  [Parameter(Mandatory = $true)][string]$DataRoot,
  [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'
$script:RemoteSettingsPath = Join-Path $DataRoot 'remote-notifications.json'
$script:RemoteInboxPath = Join-Path $DataRoot 'remote-inbox.jsonl'
$script:RemoteStatusPath = Join-Path $DataRoot 'remote-worker-status.json'
$script:RemoteTestRequestPath = Join-Path $DataRoot 'remote-test.request'
$script:RemoteLogPath = Join-Path (Join-Path $DataRoot 'logs') 'remote-worker.log'
$script:MobilePendingPath = Join-Path $DataRoot 'mobile-usage-pending.json'
$script:MobileStatusPath = Join-Path $DataRoot 'mobile-usage-status.json'
$script:MobileStatePath = Join-Path $DataRoot 'mobile-usage-state.json'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:Root 'remote-crypto.ps1')
. (Join-Path $script:Root 'ui-model.ps1')
. (Join-Path $script:Root 'mobile-sync.ps1')

function Write-RemoteWorkerLog {
  param([string]$Message)
  try {
    $dir = Split-Path -Parent $script:RemoteLogPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Add-Content -LiteralPath $script:RemoteLogPath -Value ('[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'),$Message) -Encoding UTF8
  } catch {}
}

function Write-RemoteStatus {
  param([string]$State,[string]$Message)
  try {
    Write-AtomicUtf8Json -Path $script:RemoteStatusPath -Value ([ordered]@{
      state = $State
      message = $Message
      updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }) -Depth 4
  } catch {}
}

function Write-MobileUsageStatus {
  param([string]$State,[string]$Message)
  try {
    Write-AtomicUtf8Json -Path $script:MobileStatusPath -Value ([ordered]@{
      state = $State
      message = $Message
      updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }) -Depth 4
  } catch {}
}

function Resolve-RemoteCodexHome {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if ($Path -eq '~') { return $env:USERPROFILE }
  if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) { return Join-Path $env:USERPROFILE $Path.Substring(2) }
  try { return [System.IO.Path]::GetFullPath($Path) } catch { return $Path }
}

function Get-RemoteCodexHomes {
  $homes = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
  [void]$homes.Add((Join-Path $env:USERPROFILE '.codex'))
  $profilesPath = Join-Path $DataRoot 'profiles.json'
  if (Test-Path -LiteralPath $profilesPath) {
    try {
      $profiles = Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($profile in @($profiles.profiles)) {
        if ($null -ne $profile.PSObject.Properties['enabled'] -and -not [bool]$profile.enabled) { continue }
        $codexHomePath = Resolve-RemoteCodexHome ([string]$profile.codexHome)
        if (-not [string]::IsNullOrWhiteSpace($codexHomePath)) { [void]$homes.Add($codexHomePath) }
      }
    } catch { Write-RemoteWorkerLog ('profiles.json warning: ' + $_.Exception.Message) }
  }
  return @($homes)
}

function Read-RemoteTailText {
  param([Parameter(Mandatory = $true)][string]$Path,[int]$MaxBytes = 262144)
  $stream = $null
  $reader = $null
  try {
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
    $start = [Math]::Max(0,$stream.Length - $MaxBytes)
    [void]$stream.Seek($start,[System.IO.SeekOrigin]::Begin)
    $reader = New-Object System.IO.StreamReader -ArgumentList $stream,(New-Object System.Text.UTF8Encoding($false,$false)),$true,4096,$true
    $text = $reader.ReadToEnd()
    if ($start -gt 0) {
      $newline = $text.IndexOf([Environment]::NewLine)
      if ($newline -ge 0) { $text = $text.Substring($newline + [Environment]::NewLine.Length) } else { $text = '' }
    }
    return $text
  } finally {
    if ($null -ne $reader) { $reader.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
  }
}

function Get-RemoteProjectName {
  param([Parameter(Mandatory = $true)][string]$Path)
  $stream = $null
  $reader = $null
  try {
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
    $reader = New-Object System.IO.StreamReader -ArgumentList $stream,(New-Object System.Text.UTF8Encoding($false,$false)),$true,4096,$true
    for ($i = 0; $i -lt 40 -and -not $reader.EndOfStream; $i++) {
      $line = $reader.ReadLine()
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $record = $line | ConvertFrom-Json } catch { continue }
      if ([string]$record.type -ne 'session_meta') { continue }
      $cwd = ''
      if ($null -ne $record.payload) { $cwd = [string]$record.payload.cwd }
      if ([string]::IsNullOrWhiteSpace($cwd)) { $cwd = [string]$record.cwd }
      if ([string]::IsNullOrWhiteSpace($cwd)) { continue }
      $trimmed = $cwd.TrimEnd([char[]]@('\','/'))
      $leaf = [System.IO.Path]::GetFileName($trimmed)
      if ([string]::IsNullOrWhiteSpace($leaf)) { return $trimmed }
      return $leaf
    }
  } catch {} finally {
    if ($null -ne $reader) { $reader.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
  }
  return [System.IO.Path]::GetFileNameWithoutExtension($Path)
}

function Get-CompletionEventsFromFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][DateTimeOffset]$Since,
    [Parameter(Mandatory = $true)][string]$DeviceId,
    [Parameter(Mandatory = $true)][string]$DeviceName,
    [bool]$IncludeSummary = $false
  )
  $project = Get-RemoteProjectName $Path
  $text = Read-RemoteTailText -Path $Path
  $result = @()
  foreach ($line in @($text -split '[\r\n]+')) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $record = $line | ConvertFrom-Json } catch { continue }
    if ([string]$record.type -ne 'event_msg' -or [string]$record.payload.type -ne 'task_complete') { continue }
    $turnId = [string]$record.payload.turn_id
    if ([string]::IsNullOrWhiteSpace($turnId)) { continue }
    $finishedAt = [DateTimeOffset]::UtcNow
    try { if ($record.timestamp) { $finishedAt = [DateTimeOffset]::Parse([string]$record.timestamp).ToUniversalTime() } } catch {}
    if ($finishedAt -lt $Since.ToUniversalTime()) { continue }
    $hasError = $null -ne $record.payload.error
    $summary = ''
    if ($IncludeSummary -and -not [string]::IsNullOrWhiteSpace([string]$record.payload.last_agent_message)) {
      $summary = [string]$record.payload.last_agent_message
      if ($summary.Length -gt 800) { $summary = $summary.Substring(0,800) + '…' }
    }
    $result += [pscustomobject]@{
      version = 1
      id = $DeviceId + ':' + $turnId
      deviceId = $DeviceId
      deviceName = $DeviceName
      turnId = $turnId
      project = $project
      status = $(if ($hasError) { 'error' } else { 'completed' })
      finishedAt = $finishedAt.ToString('o')
      summary = $summary
    }
  }
  return $result
}

function Get-RemoteRelayUrl {
  param($Settings)
  $base = [string]$Settings.relayUrl
  if ([string]::IsNullOrWhiteSpace($base)) { $base = 'https://ntfy.sh' }
  $uri = $null
  if (-not [Uri]::TryCreate($base,[UriKind]::Absolute,[ref]$uri)) { throw 'Invalid relay URL.' }
  if ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback)) { throw 'Relay URL must use HTTPS (HTTP is allowed only for localhost).' }
  return $base.TrimEnd('/')
}

function Publish-RemoteEvent {
  param($Settings,$Event)
  $topic = Get-RemoteTopic ([string]$Settings.pairKey)
  $relay = Get-RemoteRelayUrl $Settings
  $json = $Event | ConvertTo-Json -Compress -Depth 8
  $cipher = Protect-RemoteMessage -PlainText $json -PairKey ([string]$Settings.pairKey)
  $uri = $relay + '/' + $topic
  [void](Invoke-WebRequest -UseBasicParsing -Method Post -Uri $uri -Body $cipher -ContentType 'text/plain; charset=utf-8' -TimeoutSec 12)
}

function Publish-MobileUsageSnapshot {
  param($Settings,$Snapshot)
  $topic = Get-MobileUsageTopic ([string]$Settings.pairKey)
  $relay = Get-RemoteRelayUrl $Settings
  $json = $Snapshot | ConvertTo-Json -Compress -Depth 12
  $cipher = Protect-RemoteMessage -PlainText $json -PairKey ([string]$Settings.pairKey)
  [void](Invoke-WebRequest -UseBasicParsing -Method Post -Uri ($relay + '/' + $topic) -Body $cipher -ContentType 'text/plain; charset=utf-8' -TimeoutSec 12)
}

function Load-MobileUsageState {
  if (-not (Test-Path -LiteralPath $script:MobileStatePath)) { return $null }
  try { return Get-Content -LiteralPath $script:MobileStatePath -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { Write-RemoteWorkerLog ('Mobile state read warning: ' + $_.Exception.Message); return $null }
}

function Append-RemoteInboxEvent {
  param($Event)
  $line = $Event | ConvertTo-Json -Compress -Depth 8
  Add-Content -LiteralPath $script:RemoteInboxPath -Value $line -Encoding UTF8
  try {
    $info = Get-Item -LiteralPath $script:RemoteInboxPath
    if ($info.Length -gt 524288) {
      $tail = @(Get-Content -LiteralPath $script:RemoteInboxPath -Tail 200 -Encoding UTF8)
      [System.IO.File]::WriteAllLines($script:RemoteInboxPath,$tail,(New-Object System.Text.UTF8Encoding($false)))
    }
  } catch {}
}

function Poll-RemoteRelay {
  param($Settings,[System.Collections.Generic.HashSet[string]]$SeenRelayIds)
  $topic = Get-RemoteTopic ([string]$Settings.pairKey)
  $relay = Get-RemoteRelayUrl $Settings
  $uri = $relay + '/' + $topic + '/json?poll=1&since=12s'
  $response = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $uri -TimeoutSec 15
  foreach ($line in @([string]$response.Content -split '[\r\n]+')) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $message = $line | ConvertFrom-Json } catch { continue }
    if ([string]$message.event -ne 'message' -or [string]::IsNullOrWhiteSpace([string]$message.message)) { continue }
    $relayId = [string]$message.id
    if (-not [string]::IsNullOrWhiteSpace($relayId) -and -not $SeenRelayIds.Add($relayId)) { continue }
    try {
      $plain = Unprotect-RemoteMessage -CipherText ([string]$message.message) -PairKey ([string]$Settings.pairKey)
      $event = $plain | ConvertFrom-Json
    } catch {
      Write-RemoteWorkerLog ('Ignored undecryptable relay message: ' + $_.Exception.Message)
      continue
    }
    if ([int]$event.version -ne 1 -or [string]$event.deviceId -eq [string]$Settings.deviceId) { continue }
    Append-RemoteInboxEvent $event
  }
}

function Load-RemoteWorkerSettings {
  if (-not (Test-Path -LiteralPath $script:RemoteSettingsPath)) { return $null }
  try { return Get-Content -LiteralPath $script:RemoteSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { Write-RemoteWorkerLog ('Settings read warning: ' + $_.Exception.Message); return $null }
}

function Test-RemoteWorkerSettingsEnabled {
  param($Settings)
  return ($null -ne $Settings -and ([bool]$Settings.enabled -or [bool]$Settings.usageSyncEnabled) -and
    -not [string]::IsNullOrWhiteSpace([string]$Settings.pairKey) -and
    -not [string]::IsNullOrWhiteSpace([string]$Settings.deviceId))
}

function New-RemoteWatcher {
  param([string]$SessionsPath,[string]$Id)
  if (-not (Test-Path -LiteralPath $SessionsPath)) { return $null }
  $watcher = New-Object System.IO.FileSystemWatcher
  $watcher.Path = $SessionsPath
  $watcher.Filter = '*.jsonl'
  $watcher.IncludeSubdirectories = $true
  $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
  $changedId = 'CodexRemoteChanged-' + $Id
  $createdId = 'CodexRemoteCreated-' + $Id
  Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier $changedId | Out-Null
  Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier $createdId | Out-Null
  $watcher.EnableRaisingEvents = $true
  return [pscustomobject]@{ watcher = $watcher; ids = @($changedId,$createdId) }
}

if ($LibraryOnly) { return }

if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null }
$settings = Load-RemoteWorkerSettings
if (-not (Test-RemoteWorkerSettingsEnabled $settings)) {
  Write-RemoteStatus 'disabled' '远程功能未启用'
  Write-MobileUsageStatus 'disabled' '手机额度同步未启用'
  exit 0
}

$startedAt = [DateTimeOffset]::UtcNow
$sentEvents = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::Ordinal)
$seenRelayIds = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::Ordinal)
$watchers = @()
$lastFallback = [DateTimeOffset]::MinValue
$lastRelayPoll = [DateTimeOffset]::MinValue
$lastSettingsWrite = (Get-Item -LiteralPath $script:RemoteSettingsPath).LastWriteTimeUtc
$lastCandidateWrite = @{}
$mobileState = Load-MobileUsageState
$nextMobileAttempt = [DateTimeOffset]::MinValue
$mobileFailureCount = 0

try {
  if ([bool]$settings.enabled) {
    foreach ($codexHomePath in @(Get-RemoteCodexHomes)) {
      $sessions = Join-Path $codexHomePath 'sessions'
      $watch = New-RemoteWatcher -SessionsPath $sessions -Id ([Guid]::NewGuid().ToString('N'))
      if ($null -ne $watch) { $watchers += $watch; Write-RemoteWorkerLog ('Watching ' + $sessions) }
    }
    Write-RemoteStatus 'running' ('正在监听 Codex 完成事件 · ' + [string]$settings.deviceName)
  }
  if ([bool]$settings.usageSyncEnabled) { Write-MobileUsageStatus 'waiting' '等待电脑生成额度快照…' }
  while ($true) {
    Start-Sleep -Milliseconds 700

    try {
      $currentWrite = (Get-Item -LiteralPath $script:RemoteSettingsPath).LastWriteTimeUtc
      if ($currentWrite -ne $lastSettingsWrite) {
        Write-RemoteWorkerLog 'Settings changed; worker will restart.'
        break
      }
    } catch { break }

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    if ([bool]$settings.enabled) {
      foreach ($entry in $watchers) {
        foreach ($sourceId in $entry.ids) {
          foreach ($evt in @(Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue)) {
            try {
              $path = [string]$evt.SourceEventArgs.FullPath
              if (-not [string]::IsNullOrWhiteSpace($path)) { [void]$paths.Add($path) }
            } finally { Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue }
          }
        }
      }
    }

    $now = [DateTimeOffset]::UtcNow
    if ([bool]$settings.enabled -and ($now - $lastFallback).TotalSeconds -ge 12) {
      $lastFallback = $now
      foreach ($codexHomePath in @(Get-RemoteCodexHomes)) {
        $sessions = Join-Path $codexHomePath 'sessions'
        if (-not (Test-Path -LiteralPath $sessions)) { continue }
        try {
          foreach ($file in @(Get-ChildItem -LiteralPath $sessions -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -ge $startedAt.UtcDateTime.AddSeconds(-5) })) {
            [void]$paths.Add($file.FullName)
          }
        } catch {}
      }
    }

    foreach ($path in @($paths)) {
      if (-not (Test-Path -LiteralPath $path)) { continue }
      try {
        $write = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
        if ($lastCandidateWrite.ContainsKey($path) -and $lastCandidateWrite[$path] -eq $write) { continue }
        $lastCandidateWrite[$path] = $write
        foreach ($event in @(Get-CompletionEventsFromFile -Path $path -Since $startedAt.AddSeconds(-5) -DeviceId ([string]$settings.deviceId) -DeviceName ([string]$settings.deviceName) -IncludeSummary ([bool]$settings.includeSummary))) {
          if ($sentEvents.Contains([string]$event.id)) { continue }
          try {
            Publish-RemoteEvent -Settings $settings -Event $event
            [void]$sentEvents.Add([string]$event.id)
            Write-RemoteWorkerLog ('Published ' + [string]$event.id + ' · ' + [string]$event.project)
          } catch {
            Write-RemoteWorkerLog ('Publish failed: ' + $_.Exception.Message)
            Write-RemoteStatus 'degraded' '检测正常，但远程发送失败；将自动重试'
          }
        }
      } catch { Write-RemoteWorkerLog ('Session parse warning: ' + $_.Exception.Message) }
    }

    if ([bool]$settings.enabled -and (Test-Path -LiteralPath $script:RemoteTestRequestPath)) {
      try {
        Remove-Item -LiteralPath $script:RemoteTestRequestPath -Force -ErrorAction SilentlyContinue
        $testEvent = [pscustomobject]@{
          version = 1
          id = [string]$settings.deviceId + ':test:' + [Guid]::NewGuid().ToString('N')
          deviceId = [string]$settings.deviceId
          deviceName = [string]$settings.deviceName
          turnId = 'test'
          project = '远程通知测试'
          status = 'completed'
          finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
          summary = $(if ([bool]$settings.includeSummary) { '这是一条跨电脑 Codex 完成通知测试。' } else { '' })
        }
        Publish-RemoteEvent -Settings $settings -Event $testEvent
        Write-RemoteWorkerLog 'Published test event.'
      } catch { Write-RemoteWorkerLog ('Test publish failed: ' + $_.Exception.Message) }
    }

    if ([bool]$settings.enabled -and ($now - $lastRelayPoll).TotalSeconds -ge 5) {
      $lastRelayPoll = $now
      try {
        Poll-RemoteRelay -Settings $settings -SeenRelayIds $seenRelayIds
        Write-RemoteStatus 'running' ('正在监听 Codex 完成事件 · ' + [string]$settings.deviceName)
      } catch {
        Write-RemoteWorkerLog ('Relay poll failed: ' + $_.Exception.Message)
        Write-RemoteStatus 'degraded' '本机监听正常，远程中继暂时不可用'
      }
    }

    if ([bool]$settings.usageSyncEnabled -and $now -ge $nextMobileAttempt) {
      $nextMobileAttempt = $now.AddSeconds(2)
      if (Test-Path -LiteralPath $script:MobilePendingPath) {
        try {
          $snapshot = Get-Content -LiteralPath $script:MobilePendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
          if ([int]$snapshot.version -ne 1 -or [string]$snapshot.type -ne 'usage_snapshot') { throw 'Invalid mobile snapshot schema.' }
          $currentHash = Get-MobileUsageSnapshotHash $snapshot
          $currentTopic = Get-MobileUsageTopic ([string]$settings.pairKey)
          if (Test-MobileUsagePublishDue -CurrentHash $currentHash -State $mobileState -Now $now -CurrentTopic $currentTopic) {
            Publish-MobileUsageSnapshot -Settings $settings -Snapshot $snapshot
            $mobileState = [pscustomobject]@{ lastPublishedHash = $currentHash; lastPublishedAt = $now.ToString('o'); lastPublishedTopic = $currentTopic }
            Write-AtomicUtf8Json -Path $script:MobileStatePath -Value $mobileState -Depth 4
            $mobileFailureCount = 0
            Write-MobileUsageStatus 'running' '同步正常'
            Write-RemoteWorkerLog 'Published mobile usage snapshot.'
          }
        } catch {
          $mobileFailureCount++
          $delays = @(5,15,30,60)
          $delay = $delays[[Math]::Min($mobileFailureCount - 1,$delays.Count - 1)]
          $nextMobileAttempt = $now.AddSeconds($delay)
          Write-MobileUsageStatus 'degraded' ('网络错误；约 ' + $delay + ' 秒后重试')
          Write-RemoteWorkerLog ('Mobile usage publish failed: ' + $_.Exception.Message)
        }
      }
    }
  }
} catch {
  Write-RemoteWorkerLog ('FATAL: ' + $_.Exception.ToString())
  Write-RemoteStatus 'error' ('远程通知后台异常：' + $_.Exception.Message)
  exit 1
} finally {
  foreach ($entry in $watchers) {
    foreach ($sourceId in $entry.ids) {
      Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
      Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
    try { $entry.watcher.EnableRaisingEvents = $false; $entry.watcher.Dispose() } catch {}
  }
}

exit 0
