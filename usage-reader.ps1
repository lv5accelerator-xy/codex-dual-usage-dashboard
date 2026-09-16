$ErrorActionPreference = 'Stop'

function Resolve-CodexHomePath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
  if ($Path -eq '~') { return $env:USERPROFILE }
  if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
    return Join-Path $env:USERPROFILE $Path.Substring(2)
  }
  return $Path
}

function Start-CodexAppServer {
  param(
    [Parameter(Mandatory = $true)][string]$CodexPath,
    [Parameter(Mandatory = $true)][string]$CodexHome
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $ext = [System.IO.Path]::GetExtension($CodexPath).ToLowerInvariant()

  if ($ext -eq '.cmd' -or $ext -eq '.bat') {
    $psi.FileName = $env:ComSpec
    $psi.Arguments = ('/d /s /c ""{0}" app-server --listen stdio://"' -f $CodexPath)
  } else {
    $psi.FileName = $CodexPath
    $psi.Arguments = 'app-server --listen stdio://'
  }

  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['CODEX_HOME'] = $CodexHome
  $psi.EnvironmentVariables['CODEX_NON_INTERACTIVE'] = '1'

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  if (-not $process.Start()) {
    throw '无法启动 Codex app-server。'
  }
  return $process
}

function Write-CodexRpcLine {
  param(
    [Parameter(Mandatory = $true)]$Process,
    [Parameter(Mandatory = $true)]$Payload
  )
  $json = $Payload | ConvertTo-Json -Compress -Depth 20
  $Process.StandardInput.WriteLine($json)
  $Process.StandardInput.Flush()
}

function Read-CodexRpcResponse {
  param(
    [Parameter(Mandatory = $true)]$Process,
    [Parameter(Mandatory = $true)][string]$Id,
    [int]$TimeoutMs = 15000
  )

  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
    if ($Process.HasExited) {
      $stderr = ''
      try { $stderr = $Process.StandardError.ReadToEnd() } catch {}
      if ([string]::IsNullOrWhiteSpace($stderr)) {
        throw ('Codex app-server 已退出，错误码 {0}。' -f $Process.ExitCode)
      }
      throw ('Codex app-server 已退出：' + $stderr.Trim())
    }

    $remaining = [Math]::Max(1, $TimeoutMs - [int]$watch.ElapsedMilliseconds)
    $task = $Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($remaining)) {
      throw ('等待 Codex 响应超时（{0} ms）。' -f $TimeoutMs)
    }

    $line = $task.Result
    if ($null -eq $line) {
      if ($Process.HasExited) { continue }
      throw 'Codex app-server 输出流已关闭。'
    }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    try {
      $message = $line | ConvertFrom-Json
    } catch {
      continue
    }

    $idProp = $message.PSObject.Properties['id']
    if ($null -eq $idProp) { continue }
    if ([string]$message.id -ne [string]$Id) { continue }

    if ($null -ne $message.error) {
      $errText = [string]$message.error.message
      if ([string]::IsNullOrWhiteSpace($errText)) { $errText = 'Codex app-server 返回错误。' }
      throw $errText
    }
    return $message.result
  }

  throw ('等待 Codex 响应超时（{0} ms）。' -f $TimeoutMs)
}

function Invoke-CodexRateLimitsRead {
  param(
    [Parameter(Mandatory = $true)][string]$CodexPath,
    [Parameter(Mandatory = $true)][string]$CodexHome
  )

  $process = $null
  try {
    $process = Start-CodexAppServer -CodexPath $CodexPath -CodexHome $CodexHome

    Write-CodexRpcLine -Process $process -Payload @{
      method = 'initialize'
      id = '1'
      params = @{
        clientInfo = @{ name = 'codex-dual-usage-dashboard'; version = '0.3.3' }
        capabilities = @{ experimentalApi = $true }
      }
    }
    [void](Read-CodexRpcResponse -Process $process -Id '1' -TimeoutMs 15000)

    Write-CodexRpcLine -Process $process -Payload @{ method = 'initialized' }

    Write-CodexRpcLine -Process $process -Payload @{
      method = 'account/rateLimits/read'
      id = '2'
      params = $null
    }
    return Read-CodexRpcResponse -Process $process -Id '2' -TimeoutMs 20000
  } finally {
    if ($null -ne $process) {
      try { $process.StandardInput.Close() } catch {}
      try {
        if (-not $process.HasExited) { $process.Kill() }
      } catch {}
      try { $process.Dispose() } catch {}
    }
  }
}

function Convert-UnixSecondsToIso {
  param($Value)
  if ($null -eq $Value) { return $null }
  try {
    $sec = [Int64]$Value
    if ($sec -le 0) { return $null }
    return [DateTimeOffset]::FromUnixTimeSeconds($sec).UtcDateTime.ToString('o')
  } catch {
    return $null
  }
}

function Convert-RateLimitWindow {
  param($Window, [int]$Index = 0)
  if ($null -eq $Window) { return $null }

  $mins = $null
  try {
    if ($null -ne $Window.windowDurationMins) { $mins = [Int64]$Window.windowDurationMins }
  } catch {}

  $kind = ('window-{0}' -f ($Index + 1))
  $label = ('额度窗口 {0}' -f ($Index + 1))
  if ($null -ne $mins) {
    if ($mins -le 360) {
      $kind = '5h'
      $label = '5 小时'
    } elseif ($mins -ge 10000) {
      $kind = 'weekly'
      $label = 'Weekly'
    } elseif ($mins -ge 1440) {
      $kind = 'multi-day'
      $label = ('{0} 天' -f [Math]::Round($mins / 1440.0))
    } else {
      $label = ('{0} 分钟' -f $mins)
    }
  }

  $used = $null
  try {
    if ($null -ne $Window.usedPercent) {
      $used = [Math]::Max(0, [Math]::Min(100, [double]$Window.usedPercent))
    }
  } catch {}
  $remaining = if ($null -eq $used) { $null } else { [Math]::Max(0, [Math]::Min(100, 100 - $used)) }

  return [pscustomobject]@{
    kind = $kind
    label = $label
    usedPercent = $used
    remainingPercent = $remaining
    windowMinutes = $mins
    resetsAt = Convert-UnixSecondsToIso $Window.resetsAt
  }
}

function Get-PrimaryRateLimitSnapshot {
  param($Result)
  if ($null -eq $Result) { return $null }
  if ($null -ne $Result.rateLimits) { return $Result.rateLimits }

  $map = $Result.rateLimitsByLimitId
  if ($null -eq $map) { return $null }
  $codexProp = $map.PSObject.Properties['codex']
  if ($null -ne $codexProp) { return $codexProp.Value }

  foreach ($prop in $map.PSObject.Properties) {
    if ($null -ne $prop.Value) { return $prop.Value }
  }
  return $null
}

function Convert-CodexUsageResult {
  param(
    [Parameter(Mandatory = $true)]$Profile,
    [Parameter(Mandatory = $true)]$Result
  )

  $snapshot = Get-PrimaryRateLimitSnapshot $Result
  if ($null -eq $snapshot) { throw 'Codex 没有返回可用的额度信息。' }

  $windows = @()
  if ($null -ne $snapshot.primary) { $windows += Convert-RateLimitWindow -Window $snapshot.primary -Index 0 }
  if ($null -ne $snapshot.secondary) { $windows += Convert-RateLimitWindow -Window $snapshot.secondary -Index 1 }

  $fiveHour = $null
  $weekly = $null
  foreach ($w in $windows) {
    if ($w.kind -eq '5h' -and $null -eq $fiveHour) { $fiveHour = $w }
    if ($w.kind -eq 'weekly' -and $null -eq $weekly) { $weekly = $w }
  }

  $individualLimit = $null
  if ($null -ne $snapshot.individualLimit) {
    $remaining = $null
    try {
      if ($null -ne $snapshot.individualLimit.remainingPercent) {
        $remaining = [Math]::Max(0, [Math]::Min(100, [double]$snapshot.individualLimit.remainingPercent))
      }
    } catch {}
    $individualLimit = [pscustomobject]@{
      limit = $snapshot.individualLimit.limit
      used = $snapshot.individualLimit.used
      remainingPercent = $remaining
      resetsAt = Convert-UnixSecondsToIso $snapshot.individualLimit.resetsAt
    }
  }

  return [pscustomobject]@{
    id = [string]$Profile.id
    label = [string]$Profile.label
    codexHome = [string]$Profile.codexHome
    ok = $true
    fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
    planType = if ($null -ne $snapshot.planType) { [string]$snapshot.planType } else { 'unknown' }
    accountId = $Result.accountId
    ordinaryUsageAllowed = $Result.ordinaryUsageAllowed
    individualLimit = $individualLimit
    fiveHour = $fiveHour
    weekly = $weekly
    windows = $windows
  }
}

function Read-ProfilesConfig {
  param([Parameter(Mandatory = $true)][string]$ConfigPath)
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw ('未找到 profiles.json：' + $ConfigPath)
  }
  $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  return @($config.profiles)
}

function Get-CodexUsageForProfile {
  param(
    [Parameter(Mandatory = $true)]$Profile,
    [Parameter(Mandatory = $true)][string]$CodexPath
  )

  $resolvedCodexHome = Resolve-CodexHomePath ([string]$Profile.codexHome)
  try {
    $result = Invoke-CodexRateLimitsRead -CodexPath $CodexPath -CodexHome $resolvedCodexHome
    return Convert-CodexUsageResult -Profile $Profile -Result $result
  } catch {
    return [pscustomobject]@{
      id = [string]$Profile.id
      label = [string]$Profile.label
      codexHome = $resolvedCodexHome
      ok = $false
      fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
      error = $_.Exception.Message
    }
  }
}

function Get-CodexUsageAllProfiles {
  param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$CodexPath
  )
  $profiles = Read-ProfilesConfig -ConfigPath $ConfigPath
  $results = @()
  foreach ($profile in $profiles) {
    $results += Get-CodexUsageForProfile -Profile $profile -CodexPath $CodexPath
  }
  return [pscustomobject]@{
    ok = $true
    profiles = $results
    fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
  }
}
