<#
    Removes the server status tray icon for the current user.

        .\uninstall.ps1
        .\uninstall.ps1 -Server 'OTHER-SERVER' -KeepSettings
#>

[CmdletBinding()]
param(
    [string] $Server = '1461-Server',

    # Leave %LOCALAPPDATA%\ServerStatusTray\settings.json in place.
    [switch] $KeepSettings
)

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'ServerStatusTray'
$startMenu  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$linkName   = "$Server Status.lnk"

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'ServerStatusTray\.ps1"?\s*$' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "  stopped pid $($_.ProcessId)"
    }

foreach ($link in @((Join-Path $startMenu $linkName), (Join-Path $startMenu "Startup\$linkName"))) {
    if (Test-Path $link) { Remove-Item $link -Force; Write-Host "  removed $link" }
}

if (Test-Path $installDir) {
    if ($KeepSettings) {
        Get-ChildItem $installDir -Exclude 'settings.json' | Remove-Item -Recurse -Force
        Write-Host "  removed program files, kept settings.json"
    }
    else {
        Remove-Item $installDir -Recurse -Force
        Write-Host "  removed $installDir"
    }
}

Write-Host 'Uninstalled.'
