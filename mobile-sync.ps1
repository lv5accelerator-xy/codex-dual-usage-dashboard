# Mobile snapshot shaping and local queue helpers. No network access occurs in this file.

function Write-AtomicUtf8Json {
  param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)]$Value,[int]$Depth = 12)
  $json = $Value | ConvertTo-Json -Depth $Depth
  $tmp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  $backup = $Path + '.replace.bak'
  try {
    [System.IO.File]::WriteAllText($tmp,$json,(New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp,$Path,$backup) }
    else { [System.IO.File]::Move($tmp,$Path) }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
  }
}

function ConvertTo-MobilePercent {
  param($Value)
  if ($null -eq $Value) { return $null }
  try { return [Math]::Max(0,[Math]::Min(100,[Math]::Round([double]$Value,2))) } catch { return $null }
}

function ConvertTo-MobileWindow {
  param($Window,[string]$Kind,[string]$Label)
  if ($null -eq $Window) { return $null }
  $remaining = ConvertTo-MobilePercent $Window.remainingPercent
  if ($null -eq $remaining) { return $null }
  return [ordered]@{
    kind = $Kind
    label = $Label
    remainingPercent = $remaining
    resetsAt = $(if ([string]::IsNullOrWhiteSpace([string]$Window.resetsAt)) { $null } else { [string]$Window.resetsAt })
  }
}

function Get-MobileLongTermWindow {
  param($Profile)
  $weekly = ConvertTo-MobileWindow $Profile.weekly 'weekly' 'Weekly'
  $workspace = $null
  if (Test-MeaningfulLimit $Profile.individualLimit) {
    $workspace = ConvertTo-MobileWindow $Profile.individualLimit 'workspace' 'Workspace / Monthly'
  }
  if ($null -eq $weekly) { return $workspace }
  if ($null -eq $workspace) { return $weekly }
  if ([double]$workspace.remainingPercent -lt [double]$weekly.remainingPercent) { return $workspace }
  return $weekly
}

function New-MobileUsageSnapshot {
  param(
    [Parameter(Mandatory = $true)]$Data,
    [Parameter(Mandatory = $true)]$Settings,
    [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
  )
  $profiles = @()
  foreach ($profile in @($Data.profiles)) {
    if ($null -eq $profile) { continue }
    if ($profile.PSObject.Properties.Name -contains 'enabled' -and -not [bool]$profile.enabled) { continue }
    $id = [string]$profile.id
    if ($id -notin @('personal','work')) { continue }
    $fresh = [bool]$profile.ok -and -not [bool]$profile.stale
    $profiles += [ordered]@{
      id = $id
      label = [string]$profile.label
      ok = $fresh
      status = $(if ($fresh) { 'ok' } else { 'error' })
      fetchedAt = $(if ([string]::IsNullOrWhiteSpace([string]$profile.fetchedAt)) { $null } else { [string]$profile.fetchedAt })
      fiveHour = ConvertTo-MobileWindow $profile.fiveHour '5h' '5 Hours'
      longTerm = Get-MobileLongTermWindow $profile
    }
  }
  return [ordered]@{
    version = 1
    type = 'usage_snapshot'
    deviceId = [string]$Settings.deviceId
    deviceName = [string]$Settings.deviceName
    publishedAt = $Now.ToUniversalTime().ToString('o')
    profiles = $profiles
  }
}

function Get-MobileUsageSnapshotHash {
  param([Parameter(Mandatory = $true)]$Snapshot)
  # fetchedAt/publishedAt intentionally do not defeat duplicate suppression; the heartbeat publishes fresh timestamps.
  $semanticProfiles = @()
  foreach ($profile in @($Snapshot.profiles)) {
    $semanticProfiles += [ordered]@{
      id = [string]$profile.id
      label = [string]$profile.label
      ok = [bool]$profile.ok
      status = [string]$profile.status
      fiveHour = $profile.fiveHour
      longTerm = $profile.longTerm
    }
  }
  $semantic = [ordered]@{
    version = [int]$Snapshot.version
    type = [string]$Snapshot.type
    deviceId = [string]$Snapshot.deviceId
    deviceName = [string]$Snapshot.deviceName
    profiles = $semanticProfiles
  } | ConvertTo-Json -Compress -Depth 12
  return Convert-BytesToHex (Get-Sha256Bytes $semantic)
}

function Test-MobileUsagePublishDue {
  param([string]$CurrentHash,$State,[DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,[int]$HeartbeatMinutes = 5,[string]$CurrentTopic = '')
  if ($null -eq $State -or [string]::IsNullOrWhiteSpace([string]$State.lastPublishedHash)) { return $true }
  if (-not [string]::IsNullOrWhiteSpace($CurrentTopic) -and [string]$State.lastPublishedTopic -ne $CurrentTopic) { return $true }
  if ([string]$State.lastPublishedHash -ne $CurrentHash) { return $true }
  $last = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse([string]$State.lastPublishedAt,[ref]$last)) { return $true }
  return (($Now - $last.ToUniversalTime()).TotalMinutes -ge $HeartbeatMinutes)
}

function Write-MobileUsagePending {
  param($Data,$Settings,[string]$Path)
  if ($null -eq $Data -or $null -eq $Settings -or -not [bool]$Settings.usageSyncEnabled) { return $false }
  if ([string]::IsNullOrWhiteSpace([string]$Settings.pairKey)) { return $false }
  if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path $script:DataRoot 'mobile-usage-pending.json' }
  $snapshot = New-MobileUsageSnapshot -Data $Data -Settings $Settings
  Write-AtomicUtf8Json -Path $Path -Value $snapshot -Depth 12
  return $true
}
