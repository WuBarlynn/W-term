$ErrorActionPreference = 'Stop'
$installer = Get-ChildItem -Path build/windows/installer/*.exe | Select-Object -First 1
if (-not $installer) { throw 'Installer was not produced' }
$target = Join-Path $env:RUNNER_TEMP ("wterm-silent-" + [Guid]::NewGuid().ToString('N'))
$process = Start-Process -FilePath $installer.FullName `
  -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', "/DIR=$target") `
  -PassThru
$deadline = (Get-Date).AddMinutes(3)
while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
  $process.Refresh()
}
if (-not $process.HasExited) {
  Stop-Process -Id $process.Id -Force
  throw 'Silent installer timed out'
}
if ($process.ExitCode -ne 0) {
  throw "Silent installer exited with $($process.ExitCode)"
}
if (-not (Test-Path (Join-Path $target 'wterm.exe'))) {
  throw 'Silent installer did not create wterm.exe'
}
Start-Sleep -Seconds 3
Get-Process -Name wterm -ErrorAction SilentlyContinue | Stop-Process -Force
$uninstaller = Join-Path $target 'unins000.exe'
if (Test-Path $uninstaller) {
  Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES') -Wait | Out-Null
}
Write-Host "Silent installer smoke passed: $($installer.Name)"
