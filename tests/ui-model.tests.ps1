$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ui-model.ps1')
$script:Checks = 0
function Assert-Equal($Actual,$Expected,[string]$Message) {
  if ($Actual -ne $Expected) { throw "$Message (expected: $Expected; actual: $Actual)" }
  $script:Checks++
}
function New-Profile([string]$Id,[double]$Five,[double]$Weekly) {
  [pscustomobject]@{
    id = $Id; label = $Id; ok = $true; fetchedAt = [DateTimeOffset]::Now.ToString('o')
    fiveHour = [pscustomobject]@{ remainingPercent = $Five }
    weekly = [pscustomobject]@{ remainingPercent = $Weekly }
    individualLimit = $null
  }
}
$personal = New-Profile 'personal' 100 95
$work = New-Profile 'work' 49 21
$work.individualLimit = [pscustomobject]@{ limit = 100; remainingPercent = 68 }
$pair = Get-QuotaPair $work
Assert-Equal $pair.fiveHour 49 '5-hour value must not be replaced by the minimum'
Assert-Equal $pair.longTerm 21 'Weekly is the limiting long-term window'
Assert-Equal $pair.source '每周额度' 'Source explains the displayed minimum'
$work.individualLimit.remainingPercent = 10
Assert-Equal (Get-QuotaPair $work).longTerm 10 'Monthly can be the limiting window'
$work.individualLimit.limit = 0
Assert-Equal (Get-QuotaPair $work).longTerm 21 'Zero-limit placeholder is excluded'
$work.individualLimit.limit = -1
Assert-Equal (Test-MeaningfulLimit $work.individualLimit) $false 'Negative limit is excluded'
$work.individualLimit.limit = 100
$work.individualLimit.remainingPercent = 0
Assert-Equal (Get-QuotaPair $work).longTerm 0 'Genuine zero remaining is preserved'
Assert-Equal (Format-Percent 0) '0%' 'Zero is not missing data'
Assert-Equal (Format-Percent $null) '—' 'Missing data is not zero'
Assert-Equal (Get-QuotaPair $null).longTerm $null 'Absent account is safe'
Assert-Equal (Get-QuotaPair ([pscustomobject]@{ ok = $false })).fiveHour $null 'Failed account has no invented quota'

$previous = [pscustomobject]@{ profiles = @($personal,$work) }
$failure = [pscustomobject]@{ id = 'personal'; label = 'personal'; ok = $false; error = 'offline' }
$freshWork = New-Profile 'work' 42 17
$incoming = [pscustomobject]@{ profiles = @($freshWork,$failure); fetchedAt = [DateTimeOffset]::Now.ToString('o') }
$merged = Merge-DisplayData $previous $incoming
$retained = Get-DisplayProfile $merged 'personal'
Assert-Equal $retained.fiveHour.remainingPercent 100 'Reordered profiles keep the correct previous account'
Assert-Equal $retained.stale $true 'Retained quota is explicitly stale'
Assert-Equal $retained.refreshError 'offline' 'Failure reason remains available'
Assert-Equal $retained.fetchedAt $personal.fetchedAt 'Failure never advances the successful-data timestamp'
Assert-Equal (Get-DisplayProfile $merged 'work').fiveHour.remainingPercent 42 'Other account continues updating'
Assert-Equal (Get-DisplayProfile $merged 'work').stale $false 'Successful account is fresh'
Assert-Equal $personal.PSObject.Properties.Name.Contains('stale') $false 'Merge does not mutate previous data'
$again = Merge-DisplayData $merged $incoming
Assert-Equal (Get-DisplayProfile $again 'personal').fiveHour.remainingPercent 100 'Repeated failures preserve last success'
$recovered = Merge-DisplayData $again ([pscustomobject]@{ profiles = @((New-Profile 'personal' 80 90)); fetchedAt = [DateTimeOffset]::Now.ToString('o') })
Assert-Equal (Get-DisplayProfile $recovered 'personal').stale $false 'Recovery clears stale state'
Assert-Equal (Get-DisplayProfile $recovered 'personal').refreshError '' 'Recovery clears previous error'
$firstFailure = Merge-DisplayData $null ([pscustomobject]@{ profiles = @($failure) })
Assert-Equal (Get-DisplayProfile $firstFailure 'personal').ok $false 'First failure does not manufacture cached data'
Assert-Equal (Test-ProfileStale $personal) $false 'Recent successful data is current'
$personal.fetchedAt = [DateTimeOffset]::Now.AddMinutes(-11).ToString('o')
Assert-Equal (Test-ProfileStale $personal) $true 'Data expires even without an explicit refresh error'
$personal.fetchedAt = 'invalid'
Assert-Equal (Test-ProfileStale $personal) $true 'Invalid timestamp is not considered fresh'
Assert-Equal (Get-ResetText ([DateTimeOffset]::Now.AddMinutes(-1).ToString('o'))) '等待额度更新' 'Expired countdown does not claim a successful reset'
Write-Output "UI model: $script:Checks checks passed."
