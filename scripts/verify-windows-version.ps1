$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$versionLine = Get-Content (Join-Path $root 'pubspec.yaml') |
  Where-Object { $_ -match '^version:\s*(.+)$' } |
  Select-Object -First 1
if (-not $versionLine) { throw 'pubspec.yaml has no version field' }
$version = ($versionLine -split ':', 2)[1].Trim()
$parts = $version.Split('+')
$short = $parts[0]
$build = if ($parts.Length -gt 1) { $parts[1] } else { '0' }
$exe = Join-Path $root 'build/windows/x64/runner/Release/wterm.exe'
if (-not (Test-Path $exe)) { throw "Windows executable not found: $exe" }
$info = (Get-Item $exe).VersionInfo
$expected = "$short ($build)"
Write-Host "pubspec=$version FileVersion=$($info.FileVersion) ProductVersion=$($info.ProductVersion)"
if ($info.FileVersion -ne $expected -or $info.ProductVersion -ne $expected) {
  throw "Windows version mismatch: expected '$expected'"
}
