<#
    Installs the server status tray icon for the current user.

    Copies the tray script into %LOCALAPPDATA%\ServerStatusTray, writes the
    settings file, creates Start Menu and Startup shortcuts, promotes the icon
    out of the notification-area overflow, and starts it.

    Run from a clone of the repo:

        .\install.ps1
        .\install.ps1 -Server 'OTHER-SERVER' -BusyMinutes 5 -IdleMinutes 10
#>

[CmdletBinding()]
param(
    [string] $Server      = '1461-Server',
    [int]    $BusyMinutes = 5,
    [int]    $IdleMinutes = 10,
    [int]    $PollSeconds = 30,

    # Do not start the tray icon automatically at logon.
    [switch] $NoStartup,

    # Install the files but do not launch it now.
    [switch] $NoLaunch
)

$ErrorActionPreference = 'Stop'

$appName    = 'ServerStatusTray'
$installDir = Join-Path $env:LOCALAPPDATA $appName
$startMenu  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$startupDir = Join-Path $startMenu 'Startup'
$linkName   = "$Server Status.lnk"

$source = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
foreach ($f in 'ServerStatusTray.ps1', 'Start-ServerStatusTray.vbs') {
    if (-not (Test-Path (Join-Path $source $f))) {
        throw "Cannot find $f in '$source'. Run install.ps1 from a clone of the repository."
    }
}

function Stop-Tray {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'ServerStatusTray\.ps1"?\s*$' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function New-Shortcut([string] $path, [string] $vbs) {
    $ws = New-Object -ComObject WScript.Shell
    $s  = $ws.CreateShortcut($path)
    $s.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
    $s.Arguments        = '"' + $vbs + '"'
    $s.WorkingDirectory = Split-Path $vbs -Parent
    $s.Description      = "$Server in-use status indicator"
    $s.IconLocation     = 'imageres.dll,109'
    $s.Save()
}

# Lift the icon out of the hidden-icon overflow so it sits on the taskbar.
# The entry only exists once the icon has been shown at least once, and the
# change is picked up when the icon is next registered.
function Set-IconPromoted([string] $serverName) {
    $root = 'HKCU:\Control Panel\NotifyIconSettings'
    if (-not (Test-Path $root)) { return $false }
    $hit = Get-ChildItem $root | Where-Object {
        $p = Get-ItemProperty $_.PSPath
        $p.ExecutablePath -like '*WindowsPowerShell\v1.0\powershell.exe' -and $p.InitialTooltip -like "$serverName*"
    } | Select-Object -First 1
    if (-not $hit) { return $false }
    Set-ItemProperty $hit.PSPath -Name 'IsPromoted' -Value 1 -Type DWord
    return $true
}

Write-Host "Installing $appName -> $installDir"
Stop-Tray
Start-Sleep -Milliseconds 500

if (-not (Test-Path $installDir)) { [void] (New-Item -ItemType Directory -Path $installDir -Force) }
Copy-Item (Join-Path $source 'ServerStatusTray.ps1')        $installDir -Force
Copy-Item (Join-Path $source 'Start-ServerStatusTray.vbs')  $installDir -Force

# Settings: keep the notification toggles if this is an upgrade.
$settingsPath = Join-Path $installDir 'settings.json'
$notifyRY = $false
$notifyYG = $false
if (Test-Path $settingsPath) {
    try {
        $old = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($null -ne $old.NotifyRedToYellow)   { $notifyRY = [bool] $old.NotifyRedToYellow }
        if ($null -ne $old.NotifyYellowToGreen) { $notifyYG = [bool] $old.NotifyYellowToGreen }
    }
    catch { }
}

[ordered]@{
    ServerName          = $Server
    BusyMinutes         = $BusyMinutes
    IdleMinutes         = $IdleMinutes
    PollSeconds         = $PollSeconds
    NotifyRedToYellow   = $notifyRY
    NotifyYellowToGreen = $notifyYG
} | ConvertTo-Json | Set-Content -Path $settingsPath -Encoding UTF8

$vbs = Join-Path $installDir 'Start-ServerStatusTray.vbs'
New-Shortcut (Join-Path $startMenu $linkName) $vbs
Write-Host "  Start Menu shortcut: $linkName"

$startupLink = Join-Path $startupDir $linkName
if ($NoStartup) {
    if (Test-Path $startupLink) { Remove-Item $startupLink -Force }
    Write-Host '  Startup entry: disabled'
}
else {
    New-Shortcut $startupLink $vbs
    Write-Host '  Startup entry: enabled (starts at logon)'
}

if ($NoLaunch) {
    Write-Host "Done. Start it from the Start Menu: '$Server Status'."
    return
}

Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList "`"$vbs`""
Start-Sleep -Seconds 6

if (Set-IconPromoted $Server) {
    # Re-register the icon so the promotion takes effect immediately.
    Stop-Tray
    Start-Sleep -Milliseconds 800
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList "`"$vbs`""
    Start-Sleep -Seconds 4
    Write-Host '  Taskbar: icon pinned to the visible tray area'
}
else {
    Write-Host '  Taskbar: icon is in the hidden-icon overflow (click the ^ to drag it out)'
}

$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'ServerStatusTray\.ps1"?\s*$' })

if ($running.Count -ge 1) {
    Write-Host "Running (pid $($running[0].ProcessId)). Watching $Server."
}
else {
    Write-Warning 'The tray process is not running. Start it from the Start Menu to see the error.'
}
