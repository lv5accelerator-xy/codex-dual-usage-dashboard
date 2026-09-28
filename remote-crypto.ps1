# Shared, dependency-free cryptography for remote completion messages and mobile usage snapshots.
# Keep the completion topic and encryption derivation strings stable for v1 compatibility.

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

function Get-MobileUsageTopic {
  param([Parameter(Mandatory = $true)][string]$PairKey)
  $hex = Convert-BytesToHex (Get-Sha256Bytes ('codex-mobile-usage-topic-v1|' + $PairKey))
  return 'codex-usage-' + $hex.Substring(0,48)
}

function Test-ByteArraysEqual {
  param([byte[]]$Left,[byte[]]$Right)
  if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) { return $false }
  $diff = 0
  for ($i = 0; $i -lt $Left.Length; $i++) { $diff = $diff -bor ($Left[$i] -bxor $Right[$i]) }
  return $diff -eq 0
}

function Protect-RemoteMessageCore {
  param(
    [Parameter(Mandatory = $true)][string]$PlainText,
    [Parameter(Mandatory = $true)][string]$PairKey,
    [byte[]]$InitializationVector
  )
  $encKey = Get-Sha256Bytes ('codex-remote-enc-v1|' + $PairKey)
  $macKey = Get-Sha256Bytes ('codex-remote-mac-v1|' + $PairKey)
  $aes = New-Object System.Security.Cryptography.AesManaged
  $aes.KeySize = 256
  $aes.BlockSize = 128
  $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
  $aes.Key = $encKey
  if ($null -eq $InitializationVector) { $aes.GenerateIV() }
  else {
    if ($InitializationVector.Length -ne 16) { throw 'AES-CBC test IV must contain 16 bytes.' }
    $aes.IV = $InitializationVector
  }
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

function Protect-RemoteMessage {
  param([Parameter(Mandatory = $true)][string]$PlainText,[Parameter(Mandatory = $true)][string]$PairKey)
  return Protect-RemoteMessageCore -PlainText $PlainText -PairKey $PairKey
}

# Deterministic encryption exists only for cross-runtime fixtures. Production callers use Protect-RemoteMessage.
function Protect-RemoteMessageTestVector {
  param(
    [Parameter(Mandatory = $true)][string]$PlainText,
    [Parameter(Mandatory = $true)][string]$PairKey,
    [Parameter(Mandatory = $true)][byte[]]$InitializationVector
  )
  return Protect-RemoteMessageCore -PlainText $PlainText -PairKey $PairKey -InitializationVector $InitializationVector
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
