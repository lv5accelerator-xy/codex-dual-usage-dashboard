$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'VERSION must be major.minor.patch.' }
$build = Join-Path $root 'artifacts\desktop-build'
$dist = Join-Path $root 'dist'
if (Test-Path $build) { Remove-Item -Recurse -Force $build }
New-Item -ItemType Directory -Force -Path $build,$dist | Out-Null
$payload = Join-Path $build 'payload'
New-Item -ItemType Directory -Force -Path $payload | Out-Null
# Deliberate source allowlist; never package logs, preferences, or local credentials.
Get-ChildItem $root -File | Where-Object { $_.Extension -in @('.ps1','.bat','.vbs') -or $_.Name -in @('profiles.json','VERSION','ui-controls.cs') } | Copy-Item -Destination $payload
Copy-Item (Join-Path $root 'tests') (Join-Path $payload 'tests') -Recurse
New-Item -ItemType Directory -Force -Path (Join-Path $payload 'assets') | Out-Null
Copy-Item (Join-Path $root 'assets\app.ico') (Join-Path $payload 'assets\app.ico')
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
Get-ChildItem $payload -Recurse -Filter '*.ps1' | ForEach-Object {
  $text = [System.IO.File]::ReadAllText($_.FullName,[System.Text.Encoding]::UTF8)
  [System.IO.File]::WriteAllText($_.FullName,$text,$utf8Bom)
}
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
# Precompile native controls; packaged startup does not invoke a C# compiler.
& $csc /nologo /target:library /optimize+ /codepage:65001 `
  "/out:$(Join-Path $payload 'CodexUsage.Controls.dll')" `
  /reference:System.Windows.Forms.dll /reference:System.Drawing.dll (Join-Path $root 'ui-controls.cs')
if ($LASTEXITCODE -ne 0) { throw 'UI controls compilation failed.' }
Remove-Item (Join-Path $payload 'ui-controls.cs')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = Join-Path $build 'payload.zip'
[System.IO.Compression.ZipFile]::CreateFromDirectory($payload,$zip)
$assemblyInfo = Join-Path $build 'AssemblyInfo.cs'
@"
using System.Reflection;
[assembly: AssemblyTitle("Codex Dual Usage")]
[assembly: AssemblyDescription("Independent dual-account quota monitor")]
[assembly: AssemblyProduct("Codex Dual Usage")]
[assembly: AssemblyVersion("$version.0")]
[assembly: AssemblyFileVersion("$version.0")]
"@ | Set-Content -LiteralPath $assemblyInfo -Encoding UTF8
$exe = Join-Path $dist 'CodexUsage.exe'
& $csc /nologo /target:winexe /platform:anycpu /optimize+ /utf8output /codepage:65001 `
  "/out:$exe" "/win32icon:$(Join-Path $root 'assets\app.ico')" "/win32manifest:$(Join-Path $PSScriptRoot 'app.manifest')" `
  "/resource:$zip,CodexUsage.Payload.zip" `
  /reference:System.dll /reference:System.Core.dll /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
  /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /reference:System.Web.Extensions.dll /reference:Microsoft.CSharp.dll `
  (Join-Path $PSScriptRoot 'Client.cs') (Join-Path $PSScriptRoot 'Distribution.cs') (Join-Path $PSScriptRoot 'SelfTest.cs') $assemblyInfo
if ($LASTEXITCODE -ne 0) { throw 'Desktop client compilation failed.' }
$manifest = [ordered]@{
  version = $version
  exe = 'CodexUsage.exe'
  sha256 = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
  size = (Get-Item $exe).Length
} | ConvertTo-Json
[System.IO.File]::WriteAllText((Join-Path $dist 'update.json'),$manifest,(New-Object System.Text.UTF8Encoding($false)))
Copy-Item (Join-Path $root 'VERSION') (Join-Path $dist 'VERSION') -Force
Write-Output "Built CodexUsage.exe v$version"

Copy-Item (Join-Path $root 'docs\FRIENDS.md') (Join-Path $dist 'READ-ME.txt') -Force
$checksum = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant() + '  CodexUsage.exe'
[System.IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'),$checksum + "`n",(New-Object System.Text.UTF8Encoding($false)))
