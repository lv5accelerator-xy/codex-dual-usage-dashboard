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
    $payload = [ordered]@{
      state = $State
      message = $Message
      updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 4
    $tmp = $script:RemoteStatusPath + '.tmp'
    [System.IO.File]::WriteAllText($tmp,$payload,(New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $script:RemoteStatusPath) {
      [System.IO.File]::Replace($tmp,$script:RemoteStatusPath,$null)
    } else {
      [System.IO.File]::Move($tmp,$script:RemoteStatusPath)
    }
  } catch {}
}

function Get-Sha256Bytes {
  param([Parameter(Mandatory = $true)][string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) }
  finally { $sha.Dispose() }
}

function Convert-BytesToHex {
  param([byte[]]$Bytes)
  return ([BitConverter]::ToString($Bytes)).Replace('-','').ToLowerInvariant()
}

function Get-RemoteTopic {
  param([Parameter(Mandatory = $true)][string]$PairKey)
  $hex = Convert-BytesToHex (Get-Sha256Bytes ('codex-remote-topic-v1|' + $PairKey))
  return 'codex-' + $hex.Substring(0,48)
}

function Test-ByteArraysEqual {
  param([byte[]]$Left,[byte[]]$Right)
  if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) { return $false }
  $diff = 0
  for ($i = 0; $i -lt $Left.Length; $i++) { $diff = $diff -bor ($Left[$i] -bxor $Right[$i]) }
  return $diff -eq 0
}

function Protect-RemoteMessage {
  param([Parameter(Mandatory = $true)][string]$PlainText,[Parameter(Mandatory = $true)][string]$PairKey)
  $encKey = Get-Sha256Bytes ('codex-remote-enc-v1|' + $PairKey)
  $macKey = Get-Sha256Bytes ('codex-remote-mac-v1|' + $PairKey)
  $aes = New-Object System.Security.Cryptography.AesManaged
  $aes.KeySize = 256
  $aes.BlockSize = 128
  $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
  $aes.Key = $encKey
  $aes.GenerateIV()
  $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
  $encryptor = $aes.CreateEncryptor()
  try { $cipher = $encryptor.TransformFinalBlock($plainBytes,0,$plainBytes.Length) }
  finally { $encryptor.Dispose() }
  $body = New-Object byte[] ($aes.IV.Length + $cipher.Length)
  [Array]::Copy($aes.IV,0,$body,0,$aes.IV.Length)
  [Array]::Copy($cipher,0,$body,$aes.IV.Length,$cipher.Length)
  $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (,$macKey)
  try { $tag = $hmac.ComputeHash($body) } finally { $hmac.Dispose(); $aes.Dispose() }
  $package = New-Object byte[] ($body.Length + $tag.Length)
  [Array]::Copy($body,0,$package,0,$body.Length)
  [Array]::Copy($tag,0,$package,$body.Length,$tag.Length)
  return [Convert]::ToBase64String($package)
}

function Unprotect-RemoteMessage {
  param([Parameter(Mandatory = $true)][string]$CipherText,[Parameter(Mandatory = $true)][string]$PairKey)
  $package = [Convert]::FromBase64String($CipherText)
  if ($package.Length -lt 65) { throw 'Remote payload is too short.' }
  $bodyLength = $package.Length - 32
  $body = New-Object byte[] $bodyLength
  $tag = New-Object byte[] 32
  [Array]::Copy($package,0,$body,0,$bodyLength)
  [Array]::Copy($package,$bodyLength,$tag,0,32)
  $macKey = Get-Sha256Bytes ('codex-remote-mac-v1|' + $PairKey)
  $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (,$macKey)
  try { $expected = $hmac.ComputeHash($body) } finally { $hmac.Dispose() }
  if (-not (Test-ByteArraysEqual $tag $expected)) { throw 'Remote payload authentication failed.' }
  $iv = New-Object byte[] 16
  $cipher = New-Object byte[] ($body.Length - 16)
  [Array]::Copy($body,0,$iv,0,16)
  [Array]::Copy($body,16,$cipher,0,$cipher.Length)
  $aes = New-Object System.Security.Cryptography.AesManaged
  $aes.KeySize = 256
  $aes.BlockSize = 128
  $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
  $aes.Key = Get-Sha256Bytes ('codex-remote-enc-v1|' + $PairKey)
  $aes.IV = $iv
  $decryptor = $aes.CreateDecryptor()
  try { $plain = $decryptor.TransformFinalBlock($cipher,0,$cipher.Length) }
  finally { $decryptor.Dispose(); $aes.Dispose() }
  return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Resolve-RemoteCodexHome {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if ($Path -eq '~') { return $env:USERPROFILE }
  if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) { return Join-Path $env:USERPROFILE $Path.Substring(2) }
  try { return [System.IO.Path]::GetFullPath($Path) } catch { return $Path }
}

function Get-RemoteCodexHomes {
  $homes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  [void]$homes.Add((Join-Path $env:USERPROFILE '.codex'))
  $profilesPath = Join-Path $DataRoot 'profiles.json'
  if (Test-Path -LiteralPath $profilesPath) {
    try {
      $profiles = Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($profile in @($profiles.profiles)) {
        if ($null -ne $profile.PSObject.Properties['enabled'] -and -not [bool]$profile.enabled) { continue }
        $home = Resolve-RemoteCodexHome ([string]$profile.codexHome)
        if (-not [string]::IsNullOrWhiteSpace($home)) { [void]$homes.Add($home) }
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
    $stream = New-Object System.IO.FileStream -ArgumentList $Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite
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
    $stream = New-Object System.IO.FileStream -ArgumentList $Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite
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
if ($null -eq $settings -or -not [bool]$settings.enabled -or [string]::IsNullOrWhiteSpace([string]$settings.pairKey) -or [string]::IsNullOrWhiteSpace([string]$settings.deviceId)) {
  Write-RemoteStatus 'disabled' '跨电脑通知未启用'
  exit 0
}

$startedAt = [DateTimeOffset]::UtcNow
$sentEvents = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$seenRelayIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$watchers = @()
$lastFallback = [DateTimeOffset]::MinValue
$lastRelayPoll = [DateTimeOffset]::MinValue
$lastSettingsWrite = (Get-Item -LiteralPath $script:RemoteSettingsPath).LastWriteTimeUtc
$lastCandidateWrite = @{}

try {
  foreach ($home in @(Get-RemoteCodexHomes)) {
    $sessions = Join-Path $home 'sessions'
    $watch = New-RemoteWatcher -SessionsPath $sessions -Id ([Guid]::NewGuid().ToString('N'))
    if ($null -ne $watch) { $watchers += $watch; Write-RemoteWorkerLog ('Watching ' + $sessions) }
  }
  Write-RemoteStatus 'running' ('正在监听 Codex 完成事件 · ' + [string]$settings.deviceName)
  while ($true) {
    Start-Sleep -Milliseconds 700

    try {
      $currentWrite = (Get-Item -LiteralPath $script:RemoteSettingsPath).LastWriteTimeUtc
      if ($currentWrite -ne $lastSettingsWrite) {
        Write-RemoteWorkerLog 'Settings changed; worker will restart.'
        break
      }
    } catch { break }

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
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

    $now = [DateTimeOffset]::UtcNow
    if (($now - $lastFallback).TotalSeconds -ge 12) {
      $lastFallback = $now
      foreach ($home in @(Get-RemoteCodexHomes)) {
        $sessions = Join-Path $home 'sessions'
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

    if (Test-Path -LiteralPath $script:RemoteTestRequestPath) {
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

    if (($now - $lastRelayPoll).TotalSeconds -ge 5) {
      $lastRelayPoll = $now
      try {
        Poll-RemoteRelay -Settings $settings -SeenRelayIds $seenRelayIds
        Write-RemoteStatus 'running' ('正在监听 Codex 完成事件 · ' + [string]$settings.deviceName)
      } catch {
        Write-RemoteWorkerLog ('Relay poll failed: ' + $_.Exception.Message)
        Write-RemoteStatus 'degraded' '本机监听正常，远程中继暂时不可用'
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
