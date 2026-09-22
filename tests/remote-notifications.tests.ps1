$ErrorActionPreference = 'Stop'

function Assert-Remote([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw ('Remote notification test: ' + $Message) }
}

$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-remote-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
  . (Join-Path $root 'remote-worker.ps1') -DataRoot $temp -LibraryOnly

  $key = 'pair-key-test-123456789'
  $plain = '{"hello":"remote Codex","value":42}'
  $cipher = Protect-RemoteMessage -PlainText $plain -PairKey $key
  Assert-Remote ($cipher -ne $plain) 'Ciphertext must not expose plaintext.'
  Assert-Remote ((Unprotect-RemoteMessage -CipherText $cipher -PairKey $key) -eq $plain) 'Encrypted payload must round-trip.'

  $bytes = [Convert]::FromBase64String($cipher)
  $bytes[20] = $bytes[20] -bxor 1
  $tampered = [Convert]::ToBase64String($bytes)
  $failed = $false
  try { [void](Unprotect-RemoteMessage -CipherText $tampered -PairKey $key) } catch { $failed = $true }
  Assert-Remote $failed 'Tampered payload must fail authentication.'

  $topic1 = Get-RemoteTopic $key
  $topic2 = Get-RemoteTopic $key
  $topic3 = Get-RemoteTopic ($key + '-other')
  Assert-Remote ($topic1 -eq $topic2) 'Pair topic must be deterministic.'
  Assert-Remote ($topic1 -ne $topic3) 'Different pair keys must produce different topics.'
  Assert-Remote ($topic1 -match '^codex-[a-f0-9]{48}$') 'Topic must avoid exposing the pair key.'

  $session = Join-Path $temp 'rollout-2026-09-22T10-00-00-test.jsonl'
  $now = [DateTimeOffset]::UtcNow
  $lines = @(
    ([ordered]@{
      timestamp = $now.AddSeconds(-5).ToString('o')
      type = 'session_meta'
      payload = [ordered]@{ cwd = 'C:\work\tft-cn-companion' }
    } | ConvertTo-Json -Compress -Depth 6),
    ([ordered]@{
      timestamp = $now.ToString('o')
      type = 'event_msg'
      payload = [ordered]@{
        type = 'task_complete'
        turn_id = 'turn-123'
        last_agent_message = 'build completed and tests passed'
        error = $null
      }
    } | ConvertTo-Json -Compress -Depth 6)
  )
  [System.IO.File]::WriteAllLines($session,$lines,(New-Object System.Text.UTF8Encoding($false)))

  $events = @(Get-CompletionEventsFromFile -Path $session -Since $now.AddMinutes(-1) -DeviceId 'pc-a' -DeviceName 'Office-PC' -IncludeSummary $true)
  Assert-Remote ($events.Count -eq 1) 'One task_complete record must produce one event.'
  Assert-Remote ($events[0].id -eq 'pc-a:turn-123') 'Event id must deduplicate by device and turn.'
  Assert-Remote ($events[0].project -eq 'tft-cn-companion') 'Project name must come from session cwd.'
  Assert-Remote ($events[0].status -eq 'completed') 'Null error must map to completed.'
  Assert-Remote ($events[0].summary -eq 'build completed and tests passed') 'Summary opt-in must include the final response.'

  $privateEvents = @(Get-CompletionEventsFromFile -Path $session -Since $now.AddMinutes(-1) -DeviceId 'pc-a' -DeviceName 'Office-PC' -IncludeSummary $false)
  Assert-Remote ([string]::IsNullOrEmpty([string]$privateEvents[0].summary)) 'Summary must be omitted by default.'

  $future = @(Get-CompletionEventsFromFile -Path $session -Since $now.AddMinutes(1) -DeviceId 'pc-a' -DeviceName 'Office-PC' -IncludeSummary $true)
  Assert-Remote ($future.Count -eq 0) 'Old completions must not notify after worker startup.'

  $badRelay = [pscustomobject]@{ relayUrl = 'http://example.com'; pairKey = $key }
  $rejected = $false
  try { [void](Get-RemoteRelayUrl $badRelay) } catch { $rejected = $true }
  Assert-Remote $rejected 'Non-local HTTP relay must be rejected.'

  Write-Output 'Remote notification tests passed.'
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
