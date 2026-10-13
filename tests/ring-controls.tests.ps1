# Runs against the native controls already loaded by tray.ps1 -SmokeTest.
# First-show geometry must be checked before resizing an existing window.
$startupRing = New-Object CodexUsage.FloatingForm
$startupRing.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$startupRing.ShowInTaskbar = $false
$startupRing.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$startupRing.ClientSize = New-Object System.Drawing.Size -ArgumentList (B 60),(B 328)
$requestedRingSize = $startupRing.ClientSize
try {
  $startupRing.Show()
  [System.Windows.Forms.Application]::DoEvents()
  Assert-Ui ($startupRing.ClientSize -eq $requestedRingSize) 'First show must preserve the requested narrow ring window size.'
  $startupRing.Hide()
  $startupRing.Show()
  Assert-Ui ($startupRing.ClientSize -eq $requestedRingSize) 'Showing the ring window again must preserve its size.'
} finally { $startupRing.Close(); $startupRing.Dispose() }
