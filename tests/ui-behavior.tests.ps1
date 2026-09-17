$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'ui-model.ps1')
. (Join-Path $root 'ui-behavior.ps1')
$script:Checks = 0
function Assert-Equal($Actual,$Expected,[string]$Message) {
  if ($Actual -ne $Expected) { throw "$Message (expected: $Expected; actual: $Actual)" }
  $script:Checks++
}
$area = [pscustomobject]@{ Left = -1920; Top = 0; Right = 0; Bottom = 1040 }
$snap = Get-SnappedPosition -X -1908 -Y 120 -Width 244 -Height 44 -Area $area
Assert-Equal $snap.x -1920 'Negative-coordinate monitor snaps to its own left edge'
Assert-Equal $snap.horizontal 'left' 'Left anchor is recorded'
$snap = Get-SnappedPosition -X -250 -Y 990 -Width 244 -Height 44 -Area $area
Assert-Equal $snap.x -244 'Right edge accounts for monitor width'
Assert-Equal $snap.y 996 'Bottom uses working area, excluding taskbar'
Assert-Equal $snap.vertical 'bottom' 'Bottom anchor is recorded'
$snap = Get-SnappedPosition -X -1000 -Y 400 -Width 244 -Height 44 -Area $area
Assert-Equal $snap.x -1000 'Middle-of-screen drop does not move'
Assert-Equal $snap.horizontal 'none' 'Dragging away releases the anchor'
$snap = Get-SnappedPosition -X -1908 -Y 120 -Width 244 -Height 44 -Area $area -Enabled $false
Assert-Equal $snap.x -1908 'Snap toggle disables attraction'
$snap = Get-SnappedPosition -X -3000 -Y 1200 -Width 244 -Height 44 -Area $area -Enabled $false
Assert-Equal $snap.x -1920 'Off-screen position still clamps with snapping disabled'
Assert-Equal $snap.y 996 'Off-screen bottom still clamps'
$small = [pscustomobject]@{ Left = 0; Top = 0; Right = 100; Bottom = 30 }
$snap = Get-SnappedPosition -X 50 -Y 20 -Width 244 -Height 44 -Area $small
Assert-Equal $snap.x 0 'Oversized monitor does not produce inverted bounds'
Assert-Equal $snap.y 0 'Oversized height is clamped safely'

$script:Clock = [DateTimeOffset]::Now
$script:Tick = 0
$script:Reset = $script:Clock.AddHours(2).ToString('o')
function Sample($Value,[string]$Id = 'personal') {
  $script:Tick++
  [pscustomobject]@{ profiles = @([pscustomobject]@{
    id = $Id; label = $Id; accountId = 'fixture'; ok = $true
    fetchedAt = $script:Clock.AddSeconds(-120 + $script:Tick).ToString('o')
    fiveHour = [pscustomobject]@{ remainingPercent = $Value; resetsAt = $script:Reset }
  }) }
}
function Alerts($Data,$State,[bool]$Enabled = $true,[bool]$Baseline = $false) {
  @(Get-QuotaAlerts -Data $Data -State $State -Enabled $Enabled -Baseline $Baseline -Now $script:Clock)
}
$state = @{}
Assert-Equal @(Alerts (Sample 80) $state).Count 0 'First sample establishes a baseline'
$found = @(Alerts (Sample 19) $state)
Assert-Equal $found.Count 1 'Crossing 20 triggers once'
Assert-Equal $found[0].threshold 20 'Notification identifies the crossed threshold'
Assert-Equal $found[0].window 'fiveHour' 'Notification identifies the quota window'
Assert-Equal @(Alerts (Sample 18) $state).Count 0 'Refresh below the same threshold is silent'
Assert-Equal @(Alerts (Sample 10) $state).Count 1 'Crossing 10 triggers independently'
[void]@(Alerts (Sample 80) $state)
Assert-Equal @(Alerts (Sample 5) $state).Count 0 'Rebound within the same cycle does not repeat fired thresholds'
$saved = $state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$restored = @{}
foreach ($property in $saved.PSObject.Properties) { $restored[$property.Name] = $property.Value }
[void]@(Alerts (Sample 80) $restored)
Assert-Equal @(Alerts (Sample 5) $restored).Count 0 'Deduplication survives JSON round-trip/restart'
$script:Reset = $script:Clock.AddHours(5).ToString('o')
Assert-Equal @(Alerts (Sample 90) $state).Count 0 'New reset window establishes a new baseline'
$found = @(Alerts (Sample 5) $state)
Assert-Equal $found.Count 1 'Two thresholds crossed in one read produce one notification per window'
Assert-Equal $found[0].threshold 10 'A multi-threshold drop reports the more severe level'
Assert-Equal @($state['personal|fixture|fiveHour'].fired).Count 2 'Both crossed thresholds are remembered'
Assert-Equal @(Alerts (Sample 80 'work') $state).Count 0 'A second account has its own baseline'
Assert-Equal @(Alerts (Sample 19 'work') $state).Count 1 'Account notification state is independent'

$state = @{}
[void]@(Alerts (Sample 80) $state)
$bad = Sample 5
$bad.profiles[0].ok = $false
Assert-Equal @(Alerts $bad $state).Count 0 'Failed reads never notify'
Assert-Equal $state['personal|fixture|fiveHour'].value 80 'Failed reads cannot modify the baseline'
$bad = Sample 5
$bad.profiles[0] | Add-Member -NotePropertyName stale -NotePropertyValue $true
Assert-Equal @(Alerts $bad $state).Count 0 'Merged stale display data never notifies'
$bad = Sample 5
$bad.profiles[0].fetchedAt = $script:Clock.AddMinutes(-11).ToString('o')
Assert-Equal @(Alerts $bad $state).Count 0 'Old timestamps never notify'
$bad = Sample 5
$bad.profiles[0].fiveHour.resetsAt = $script:Clock.AddMinutes(-1).ToString('o')
Assert-Equal @(Alerts $bad $state).Count 0 'Already-expired reset windows never notify'
Assert-Equal @(Alerts (Sample $null) $state).Count 0 'Missing quota is not treated as zero'
Assert-Equal @(Alerts (Sample 101) $state).Count 0 'Invalid percentages are ignored'
Assert-Equal @(Alerts (Sample 0) $state).Count 1 'Real zero remaining can notify'

$state = @{}
[void]@(Alerts (Sample 80) $state)
Assert-Equal @(Alerts (Sample 19) $state $false).Count 0 'Notifications are silent when disabled'
Assert-Equal @(Alerts (Sample 9) $state $true $true).Count 0 'Enabling notifications does not alert immediately on old low values'
Assert-Equal @(Alerts (Sample 8) $state).Count 0 'Remaining below the threshold does not repeat'
$state = @{}
$first = Sample 80
[void]@(Alerts $first $state)
$first.profiles[0].fiveHour.remainingPercent = 5
Assert-Equal @(Alerts $first $state).Count 0 'Replaying the same timestamp cannot fabricate a crossing'
$fresh = Sample 5
$fresh.profiles[0] | Add-Member -NotePropertyName individualLimit -NotePropertyValue ([pscustomobject]@{ limit = 0; remainingPercent = 0 })
[void]@(Alerts $fresh $state)
Assert-Equal $state.ContainsKey('personal|fixture|individualLimit') $false 'Meaningless monthly limits are excluded'
Write-Output "UI behavior: $script:Checks checks passed."
