# Pure interaction/notification rules, shared by the native UI and regression tests.
function Get-SnappedPosition {
  param([int]$X,[int]$Y,[int]$Width,[int]$Height,$Area,[int]$Distance = 20,[bool]$Enabled = $true)
  $left = [int]$Area.Left
  $top = [int]$Area.Top
  $right = [Math]::Max($left,[int]$Area.Right - $Width)
  $bottom = [Math]::Max($top,[int]$Area.Bottom - $Height)
  $X = [Math]::Max($left,[Math]::Min($right,$X))
  $Y = [Math]::Max($top,[Math]::Min($bottom,$Y))
  $horizontal = 'none'
  $vertical = 'none'
  if ($Enabled) {
    if ([Math]::Min($X - $left,$right - $X) -le $Distance) {
      if (($X - $left) -le ($right - $X)) { $X = $left; $horizontal = 'left' }
      else { $X = $right; $horizontal = 'right' }
    }
    if ([Math]::Min($Y - $top,$bottom - $Y) -le $Distance) {
      if (($Y - $top) -le ($bottom - $Y)) { $Y = $top; $vertical = 'top' }
      else { $Y = $bottom; $vertical = 'bottom' }
    }
  }
  [pscustomobject]@{ x = $X; y = $Y; horizontal = $horizontal; vertical = $vertical }
}

function Convert-AlertTime {
  param($Value)
  # ConvertFrom-Json may materialize ISO strings as DateTime. Casting those to
  # string loses timezone/fractional seconds and would reset the dedupe ledger.
  if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).ToUniversalTime() }
  return [DateTimeOffset]::Parse([string]$Value).ToUniversalTime()
}

function Get-QuotaAlerts {
  param($Data,[hashtable]$State,[int[]]$Thresholds = @(20,10),[bool]$Enabled = $false,[bool]$Baseline = $false,
    [DateTimeOffset]$Now = [DateTimeOffset]::Now)
  $levels = @($Thresholds | Where-Object { $_ -gt 0 -and $_ -lt 100 } | Sort-Object -Descending -Unique)
  foreach ($profile in @($Data.profiles)) {
    # Process raw successful responses, never merged display/cache values.
    if ($null -eq $profile -or (Test-ProfileStale -Profile $profile -Now $Now)) { continue }
    $sampleAt = Convert-AlertTime $profile.fetchedAt
    if ($sampleAt -gt $Now.AddMinutes(1)) { continue }
    foreach ($kind in @('fiveHour','weekly','individualLimit')) {
      $window = $profile.$kind
      if ($kind -eq 'individualLimit' -and -not (Test-MeaningfulLimit $window)) { continue }
      if ($null -eq $window -or $null -eq $window.remainingPercent) { continue }
      try { $value = [double]$window.remainingPercent } catch { continue }
      if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0 -or $value -gt 100) { continue }
      $cycle = [string]$window.resetsAt
      if ($cycle) {
        try {
          $reset = Convert-AlertTime $window.resetsAt
          if ($reset -le $Now) { continue }
          $cycle = $reset.ToUniversalTime().ToString('o')
        } catch { continue }
      }
      $key = [string]$profile.id + '|' + [string]$profile.accountId + '|' + $kind
      $old = $State[$key]
      if ($null -ne $old) {
        try { if ($sampleAt -le (Convert-AlertTime $old.sampleAt)) { continue } } catch { $old = $null }
      }
      $oldCycle = ''
      if ($null -ne $old -and $old.cycle) {
        try { $oldCycle = (Convert-AlertTime $old.cycle).ToString('o') } catch { $old = $null }
      }
      $newCycle = $null -eq $old -or $oldCycle -ne $cycle
      $fired = @()
      if (-not $newCycle) { $fired = @($old.fired) }
      # Without a reset timestamp, only recovery above every threshold rearms alerts.
      if (-not $cycle -and $levels.Count -gt 0 -and $value -gt $levels[0]) { $fired = @() }
      $crossed = @()
      $recentBaseline = $null -ne $old -and $null -ne $old.value
      if ($recentBaseline) { $recentBaseline = ($sampleAt - (Convert-AlertTime $old.sampleAt)).TotalMinutes -lt 10 }
      if ($Enabled -and -not $Baseline -and -not $newCycle -and $recentBaseline) {
        foreach ($level in $levels) {
          if ([double]$old.value -gt $level -and $value -le $level -and $fired -notcontains $level) {
            $crossed += $level
            $fired += $level
          }
        }
      }
      $State[$key] = [pscustomobject]@{ value = $value; cycle = $cycle; fired = @($fired); sampleAt = $sampleAt.ToString('o') }
      if ($crossed.Count -gt 0) {
        $title = switch ($kind) { 'fiveHour' { '5 小时' } 'weekly' { '每周' } 'individualLimit' { '工作空间 / 月度' } }
        [pscustomobject]@{ id = $profile.id; label = $profile.label; window = $kind; title = $title;
          remaining = $value; threshold = ($crossed | Measure-Object -Minimum).Minimum }
      }
    }
  }
}
