# UI-only presentation rules. No network, credentials, or WinForms dependencies.
function Test-MeaningfulLimit {
  param($Limit)
  if ($null -eq $Limit) { return $false }
  if ($null -eq $Limit.limit) { return $true }
  try { return ([double]$Limit.limit -gt 0) } catch { return $false }
}

function Get-QuotaPair {
  param($Profile)
  $fiveHour = $null
  $longTerm = $null
  $source = '未提供'
  if ($null -ne $Profile -and $Profile.ok) {
    if ($null -ne $Profile.fiveHour) { $fiveHour = $Profile.fiveHour.remainingPercent }
    if ($null -ne $Profile.weekly -and $null -ne $Profile.weekly.remainingPercent) {
      $longTerm = [double]$Profile.weekly.remainingPercent
      $source = '每周额度'
    }
    if ((Test-MeaningfulLimit $Profile.individualLimit) -and $null -ne $Profile.individualLimit.remainingPercent) {
      $monthly = [double]$Profile.individualLimit.remainingPercent
      if ($null -eq $longTerm -or $monthly -lt $longTerm) {
        $longTerm = $monthly
        $source = '工作空间 / 月度额度'
      }
    }
  }
  return [pscustomobject]@{ fiveHour = $fiveHour; longTerm = $longTerm; source = $source }
}

function Get-DisplayProfile {
  param($Data,[string]$Id)
  foreach ($profile in @($Data.profiles)) {
    if ($null -ne $profile -and [string]$profile.id -eq $Id) { return $profile }
  }
  return $null
}

function Merge-DisplayData {
  param($Previous,$Incoming)
  $profiles = @()
  foreach ($profile in @($Incoming.profiles)) {
    if ($null -eq $profile) { continue }
    $old = Get-DisplayProfile -Data $Previous -Id ([string]$profile.id)
    $source = $profile
    $stale = -not $profile.ok
    # Match by account ID, never by list position. Retain last success only for this account.
    if ($stale -and $null -ne $old -and $old.ok) { $source = $old }
    $copy = [ordered]@{}
    foreach ($property in $source.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    $copy['stale'] = $stale
    $copy['refreshError'] = if ($stale) { [string]$profile.error } else { '' }
    $profiles += [pscustomobject]$copy
  }
  return [pscustomobject]@{ profiles = $profiles; fetchedAt = $Incoming.fetchedAt }
}

function Test-ProfileStale {
  param($Profile,[DateTimeOffset]$Now = [DateTimeOffset]::Now)
  if ($null -eq $Profile -or -not $Profile.ok -or $Profile.stale) { return $true }
  try { return (($Now - [DateTimeOffset]::Parse([string]$Profile.fetchedAt)).TotalMinutes -ge 10) }
  catch { return $true }
}

function Format-Percent {
  param($Value)
  if ($null -eq $Value) { return '—' }
  try { return ('{0:0}%' -f [double]$Value) } catch { return '—' }
}

function Get-ResetText {
  param([string]$Iso)
  if ([string]::IsNullOrWhiteSpace($Iso)) { return '未提供重置时间' }
  try {
    $span = [DateTimeOffset]::Parse($Iso) - [DateTimeOffset]::Now
    if ($span.TotalSeconds -le 0) { return '等待额度更新' }
    if ($span.TotalDays -ge 1) { return ('{0}天 {1}小时后重置' -f [Math]::Floor($span.TotalDays), $span.Hours) }
    if ($span.TotalHours -ge 1) { return ('{0}小时 {1}分钟后重置' -f [Math]::Floor($span.TotalHours), $span.Minutes) }
    return ('{0}分钟后重置' -f [Math]::Max(1, [Math]::Ceiling($span.TotalMinutes)))
  } catch { return '未提供重置时间' }
}
