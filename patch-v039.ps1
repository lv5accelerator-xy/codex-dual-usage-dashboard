param(
  [Parameter(Mandatory = $true)][string]$TrayPath,
  [Parameter(Mandatory = $true)][string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Write-PatchLog {
  param([string]$Message)
  try {
    $line = ('[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
  } catch {}
}

function Replace-LiteralOrThrow {
  param(
    [string]$Text,
    [string]$Old,
    [string]$New,
    [string]$Name
  )
  if ($Text.Contains($Old)) {
    Write-PatchLog ('v0.3.9 patch: ' + $Name)
    return $Text.Replace($Old,$New)
  }
  return $Text
}

$text = [System.IO.File]::ReadAllText($TrayPath,[System.Text.Encoding]::UTF8)
$before = $text

$text = $text.Replace('===== v0.3.8 tray starting =====','===== v0.3.9 tray starting =====')

# Full panel order: 5H first, then workspace/monthly total, then weekly.
$oldOrder = @'
      Add-QuotaRow -Parent $card -Title $monthlyTitle -Window $Profile.individualLimit -Y 38 -Detail $detail
      Add-QuotaRow -Parent $card -Title '5 小时限额' -Window $Profile.fiveHour -Y 98
      Add-QuotaRow -Parent $card -Title '每周限额' -Window $Profile.weekly -Y 158
'@
$newOrder = @'
      Add-QuotaRow -Parent $card -Title '5 小时限额' -Window $Profile.fiveHour -Y 38
      Add-QuotaRow -Parent $card -Title $monthlyTitle -Window $Profile.individualLimit -Y 98 -Detail $detail
      Add-QuotaRow -Parent $card -Title '每周限额' -Window $Profile.weekly -Y 158
'@
$text = Replace-LiteralOrThrow -Text $text -Old $oldOrder -New $newOrder -Name 'reorder detailed quota rows'

# Floating ball: show 5H before total. Total = weekly plus a meaningful monthly/workspace limit, taking the lower one.
$ballFunctionPattern = '(?ms)^  function Update-BallSummary \{.*?^  function Clear-Content \{'
$ballFunctionReplacement = @'
  function Update-BallSummary {
    param($Data)
    if ($null -eq $script:BallPersonalLabel -or $null -eq $script:BallWorkLabel) { return }

    function Get-BallQuotaPair {
      param($Profile)
      if ($null -eq $Profile -or -not $Profile.ok) {
        return [pscustomobject]@{ fiveHour = $null; total = $null }
      }

      $fiveHour = $null
      if ($null -ne $Profile.fiveHour -and $null -ne $Profile.fiveHour.remainingPercent) {
        $fiveHour = [double]$Profile.fiveHour.remainingPercent
      }

      $totalValues = @()
      if ($null -ne $Profile.weekly -and $null -ne $Profile.weekly.remainingPercent) {
        $totalValues += [double]$Profile.weekly.remainingPercent
      }

      if ($null -ne $Profile.individualLimit -and $null -ne $Profile.individualLimit.remainingPercent) {
        $limitIsMeaningful = $true
        if ($null -ne $Profile.individualLimit.limit) {
          try { $limitIsMeaningful = ([double]$Profile.individualLimit.limit -gt 0) } catch {}
        }
        if ($limitIsMeaningful) {
          $totalValues += [double]$Profile.individualLimit.remainingPercent
        }
      }

      $total = $null
      if ($totalValues.Count -gt 0) {
        $total = [double](($totalValues | Measure-Object -Minimum).Minimum)
      }

      return [pscustomobject]@{ fiveHour = $fiveHour; total = $total }
    }

    function Format-BallPercent {
      param($Value)
      if ($null -eq $Value) { return '--' }
      return ('{0:0}%' -f [double]$Value)
    }

    $profiles = @($Data.profiles)
    $personal = if ($profiles.Count -gt 0) { Get-BallQuotaPair $profiles[0] } else { Get-BallQuotaPair $null }
    $work = if ($profiles.Count -gt 1) { Get-BallQuotaPair $profiles[1] } else { Get-BallQuotaPair $null }

    $script:BallPersonalLabel.Text = 'P ' + (Format-BallPercent $personal.fiveHour) + ' / ' + (Format-BallPercent $personal.total)
    $script:BallWorkLabel.Text = 'W ' + (Format-BallPercent $work.fiveHour) + ' / ' + (Format-BallPercent $work.total)

    $all = @()
    foreach ($value in @($personal.fiveHour,$personal.total,$work.fiveHour,$work.total)) {
      if ($null -ne $value) { $all += [double]$value }
    }
    if ($all.Count -eq 0) {
      $script:BallAccent = $script:Theme.Cyan
    } else {
      $min = [double](($all | Measure-Object -Minimum).Minimum)
      $script:BallAccent = Get-BarColor $min
    }
    try { $script:Ball.Invalidate() } catch {}
  }

  function Clear-Content {
'@
$patched = [regex]::Replace($text,$ballFunctionPattern,$ballFunctionReplacement)
if ($patched -ne $text) {
  $text = $patched
  Write-PatchLog 'v0.3.9 patch: floating summary now shows 5H / total.'
}

# Keep the object circular while giving the two quota values enough room.
$text = $text.Replace('return (New-Object System.Drawing.Point -ArgumentList ($area.Right - 118),($area.Bottom - 180))','return (New-Object System.Drawing.Point -ArgumentList ($area.Right - 140),($area.Bottom - 200))')
$text = $text.Replace('$script:Ball.Size = New-Object System.Drawing.Size -ArgumentList 92,92','$script:Ball.Size = New-Object System.Drawing.Size -ArgumentList 112,112')
$text = $text.Replace('-Width 92 -Height 92','-Width 112 -Height 112')

$text = $text.Replace("$script:BallPersonalLabel.Text = 'P --'","$script:BallPersonalLabel.Text = 'P -- / --'")
$text = $text.Replace('$script:BallPersonalLabel.Size = New-Object System.Drawing.Size -ArgumentList 78,22','$script:BallPersonalLabel.Size = New-Object System.Drawing.Size -ArgumentList 98,22')
$text = $text.Replace('$script:BallPersonalLabel.Location = New-Object System.Drawing.Point -ArgumentList 7,17','$script:BallPersonalLabel.Location = New-Object System.Drawing.Point -ArgumentList 7,39')
$text = $text.Replace("$script:BallPersonalLabel.Font = New-UiFont -FamilyName 'Consolas' -Size ([single]10) -Style ([System.Drawing.FontStyle]::Bold)","$script:BallPersonalLabel.Font = New-UiFont -FamilyName 'Consolas' -Size ([single]8.6) -Style ([System.Drawing.FontStyle]::Bold)")

$text = $text.Replace("$script:BallWorkLabel.Text = 'W --'","$script:BallWorkLabel.Text = 'W -- / --'")
$text = $text.Replace('$script:BallWorkLabel.Size = New-Object System.Drawing.Size -ArgumentList 78,22','$script:BallWorkLabel.Size = New-Object System.Drawing.Size -ArgumentList 98,22')
$text = $text.Replace('$script:BallWorkLabel.Location = New-Object System.Drawing.Point -ArgumentList 7,39','$script:BallWorkLabel.Location = New-Object System.Drawing.Point -ArgumentList 7,61')
$text = $text.Replace("$script:BallWorkLabel.Font = New-UiFont -FamilyName 'Consolas' -Size ([single]10) -Style ([System.Drawing.FontStyle]::Bold)","$script:BallWorkLabel.Font = New-UiFont -FamilyName 'Consolas' -Size ([single]8.6) -Style ([System.Drawing.FontStyle]::Bold)")

$text = $text.Replace("$ballCaption.Text = 'CODEX'","$ballCaption.Text = '5H  /  总'")
$text = $text.Replace('$ballCaption.Size = New-Object System.Drawing.Size -ArgumentList 70,14','$ballCaption.Size = New-Object System.Drawing.Size -ArgumentList 84,18')
$text = $text.Replace('$ballCaption.Location = New-Object System.Drawing.Point -ArgumentList 11,63','$ballCaption.Location = New-Object System.Drawing.Point -ArgumentList 14,19')
$text = $text.Replace("$ballCaption.Font = New-UiFont -FamilyName 'Segoe UI' -Size ([single]6.8) -Style ([System.Drawing.FontStyle]::Regular)","$ballCaption.Font = New-UiFont -FamilyName 'Microsoft YaHei UI' -Size ([single]7.4) -Style ([System.Drawing.FontStyle]::Bold)")

if ($text -ne $before) {
  $utf8Bom = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($TrayPath,$text,$utf8Bom)
  Write-PatchLog 'v0.3.9 display patch completed.'
} else {
  Write-PatchLog 'v0.3.9 display patch already applied; no changes needed.'
}
