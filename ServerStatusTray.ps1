<#
    Server status tray icon
    -----------------------
    Shows a coloured dot in the notification area based on how long ago a
    Windows server last received user input (mouse / keyboard). The reading
    comes from the remote session table via `quser`, whose IDLE TIME column is
    derived from each session's last input time.

        RED     last input < BusyMinutes ago          -> in use right now
        YELLOW  last input BusyMinutes-IdleMinutes    -> maybe still in use
        GREEN   last input > IdleMinutes ago          -> free
        GREY    could not read the server             -> unknown

    Right-click the icon for the current reading, notification toggles, a
    manual refresh and exit.
#>

[CmdletBinding()]
param(
    [string] $ServerName,
    [int]    $BusyMinutes,
    [int]    $IdleMinutes,
    [int]    $PollSeconds
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace 'ServerStatus' -Name 'Native' -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(System.IntPtr hIcon);
'@

# --- settings --------------------------------------------------------------
$settingsDir  = Join-Path $env:LOCALAPPDATA 'ServerStatusTray'
$settingsPath = Join-Path $settingsDir 'settings.json'

$settings = [ordered]@{
    ServerName          = '1461-Server'
    BusyMinutes         = 5
    IdleMinutes         = 10
    PollSeconds         = 30
    NotifyRedToYellow   = $false
    NotifyYellowToGreen = $false
}

if (Test-Path $settingsPath) {
    try {
        $saved = Get-Content $settingsPath -Raw | ConvertFrom-Json
        foreach ($key in @($settings.Keys)) {
            if ($null -ne $saved.$key) { $settings[$key] = $saved.$key }
        }
    }
    catch { }   # a corrupt settings file falls back to the defaults above
}

# Explicit command-line arguments win over the saved settings.
if ($PSBoundParameters.ContainsKey('ServerName'))  { $settings.ServerName  = $ServerName }
if ($PSBoundParameters.ContainsKey('BusyMinutes')) { $settings.BusyMinutes = $BusyMinutes }
if ($PSBoundParameters.ContainsKey('IdleMinutes')) { $settings.IdleMinutes = $IdleMinutes }
if ($PSBoundParameters.ContainsKey('PollSeconds')) { $settings.PollSeconds = $PollSeconds }

function Save-Settings {
    try {
        if (-not (Test-Path $settingsDir)) {
            [void] (New-Item -ItemType Directory -Path $settingsDir -Force)
        }
        ($settings | ConvertTo-Json) | Set-Content -Path $settingsPath -Encoding UTF8
    }
    catch { }   # never let a failed write take the tray icon down
}

# --- single instance -------------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ServerStatusTray', [ref] $createdNew)
if (-not $createdNew) { return }

# --- state shared between the background poller and the UI -----------------
$sync = [hashtable]::Synchronized(@{
    Status       = 'unknown'    # busy | idle-soon | free | unknown
    IdleMinutes  = $null
    Detail       = 'Checking...'
    Updated      = $null
    Revision     = 0
    ForceRefresh = $true
    Stop         = $false
    Server       = $settings.ServerName
    Busy         = $settings.BusyMinutes
    Idle         = $settings.IdleMinutes
    Poll         = $settings.PollSeconds
})

# --- background poller -----------------------------------------------------
$poller = {
    # Parse a quser IDLE TIME cell into minutes.
    #   "."       -> input happening right now   -> 0
    #   "7"       -> 7 minutes
    #   "1:23"    -> 1h 23m
    #   "3+01:23" -> 3d 1h 23m
    #   "none"    -> not reported                -> $null
    function ConvertFrom-IdleCell([string] $cell) {
        $cell = $cell.Trim()
        if ($cell -eq '' -or $cell -eq '.') { return 0 }
        if ($cell -eq 'none') { return $null }
        if ($cell -match '^(?:(\d+)\+)?(?:(\d+):)?(\d+)$') {
            $d = if ($Matches[1]) { [int] $Matches[1] } else { 0 }
            $h = if ($Matches[2]) { [int] $Matches[2] } else { 0 }
            $m = [int] $Matches[3]
            return ($d * 1440) + ($h * 60) + $m
        }
        return $null
    }

    function Get-ServerIdle([string] $server) {
        $raw  = & quser.exe /server:$server 2>&1
        $code = $LASTEXITCODE
        $text = ($raw | Out-String)

        if ($code -ne 0) {
            # "No User exists for *" simply means nobody is logged on: free.
            if ($text -match 'No User exists') {
                return @{ Ok = $true; Idle = [int]::MaxValue; User = '(nobody logged on)' }
            }
            $msg = ($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            return @{ Ok = $false; Error = "$msg".Trim() }
        }

        $lines = @($raw | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
        if ($lines.Count -lt 2) {
            return @{ Ok = $true; Idle = [int]::MaxValue; User = '(nobody logged on)' }
        }

        # Column offsets are taken from the header rather than split on
        # whitespace, because a disconnected session leaves SESSIONNAME blank
        # and would shift every field.
        $header   = $lines[0]
        $userCol  = $header.IndexOf('USERNAME')
        $sessCol  = $header.IndexOf('SESSIONNAME')
        $idleCol  = $header.IndexOf('IDLE TIME')
        $logonCol = $header.IndexOf('LOGON TIME')
        if ($userCol -lt 0 -or $sessCol -lt 0 -or $idleCol -lt 0 -or $logonCol -lt 0) {
            return @{ Ok = $false; Error = 'Unexpected quser output format' }
        }

        $best = $null
        $bestUser = ''
        foreach ($line in $lines[1..($lines.Count - 1)]) {
            if ($line.Length -le $idleCol) { continue }
            $len  = [Math]::Min($logonCol - $idleCol, $line.Length - $idleCol)
            $mins = ConvertFrom-IdleCell $line.Substring($idleCol, $len)
            if ($null -eq $mins) { continue }
            if ($null -eq $best -or $mins -lt $best) {
                $best = $mins
                $ulen = [Math]::Min($sessCol - $userCol, $line.Length - $userCol)
                $bestUser = $line.Substring($userCol, $ulen).Trim().TrimStart('>').Trim()
            }
        }

        if ($null -eq $best) {
            return @{ Ok = $false; Error = 'Sessions found but no idle time reported' }
        }
        return @{ Ok = $true; Idle = $best; User = $bestUser }
    }

    $waited = [int]::MaxValue
    while (-not $sync.Stop) {
        if ($sync.ForceRefresh -or $waited -ge $sync.Poll) {
            $sync.ForceRefresh = $false
            $waited = 0

            try   { $r = Get-ServerIdle $sync.Server }
            catch { $r = @{ Ok = $false; Error = $_.Exception.Message } }

            if (-not $r.Ok) {
                $sync.Status      = 'unknown'
                $sync.IdleMinutes = $null
                $sync.Detail      = "Cannot read $($sync.Server): $($r.Error)"
            }
            else {
                $m = $r.Idle
                $sync.IdleMinutes = $m
                if     ($m -lt $sync.Busy) { $sync.Status = 'busy' }
                elseif ($m -lt $sync.Idle) { $sync.Status = 'idle-soon' }
                else                       { $sync.Status = 'free' }

                $ago = if     ($m -eq [int]::MaxValue) { 'nobody logged on' }
                       elseif ($m -eq 0)               { 'active right now' }
                       elseif ($m -eq 1)               { '1 minute ago' }
                       elseif ($m -lt 60)              { "$m minutes ago" }
                       else { '{0}h {1}m ago' -f [int] ($m / 60), ($m % 60) }

                $who = if ($r.User) { "   [$($r.User)]" } else { '' }
                $sync.Detail = "Last input: $ago$who"
            }

            $sync.Updated  = Get-Date
            $sync.Revision = $sync.Revision + 1
        }
        Start-Sleep -Seconds 1
        $waited++
    }
}

$runspace = [runspacefactory]::CreateRunspace()
$runspace.ApartmentState = 'MTA'
$runspace.ThreadOptions  = 'ReuseThread'
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('sync', $sync)
$worker = [powershell]::Create()
$worker.Runspace = $runspace
[void] $worker.AddScript($poller)
[void] $worker.BeginInvoke()

# --- icons -----------------------------------------------------------------
# Built once and reused: generating an Icon on every tick would leak GDI
# handles until the process died.
function New-DotIcon([System.Drawing.Color] $fill) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    $edge  = [System.Drawing.Color]::FromArgb(255, [int] ($fill.R * 0.55), [int] ($fill.G * 0.55), [int] ($fill.B * 0.55))
    $brush = New-Object System.Drawing.SolidBrush $fill
    $pen   = New-Object System.Drawing.Pen $edge, 2.5
    $gloss = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(90, 255, 255, 255))

    $g.FillEllipse($brush, 3, 3, 26, 26)
    $g.FillEllipse($gloss, 9, 7, 14, 9)
    $g.DrawEllipse($pen, 3, 3, 26, 26)

    $hicon = $bmp.GetHicon()
    $icon  = [System.Drawing.Icon]::FromHandle($hicon).Clone()
    [void] [ServerStatus.Native]::DestroyIcon($hicon)

    $gloss.Dispose(); $pen.Dispose(); $brush.Dispose(); $g.Dispose(); $bmp.Dispose()
    return $icon
}

$icons = @{
    'busy'      = New-DotIcon ([System.Drawing.Color]::FromArgb(228, 60, 50))
    'idle-soon' = New-DotIcon ([System.Drawing.Color]::FromArgb(240, 180, 30))
    'free'      = New-DotIcon ([System.Drawing.Color]::FromArgb(50, 185, 85))
    'unknown'   = New-DotIcon ([System.Drawing.Color]::FromArgb(150, 150, 155))
}
$labels = @{
    'busy'      = 'IN USE'
    'idle-soon' = 'MAYBE FREE'
    'free'      = 'FREE'
    'unknown'   = 'UNKNOWN'
}

# --- tray icon -------------------------------------------------------------
$menu     = New-Object System.Windows.Forms.ContextMenuStrip
$miHeader = $menu.Items.Add($settings.ServerName)
$miDetail = $menu.Items.Add('Checking...')
[void] $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miNotifyRY = New-Object System.Windows.Forms.ToolStripMenuItem
$miNotifyRY.Text         = 'Notify on red -> yellow (they stopped using it)'
$miNotifyRY.CheckOnClick = $true
$miNotifyRY.Checked      = [bool] $settings.NotifyRedToYellow

$miNotifyYG = New-Object System.Windows.Forms.ToolStripMenuItem
$miNotifyYG.Text         = 'Notify on yellow -> green (server became free)'
$miNotifyYG.CheckOnClick = $true
$miNotifyYG.Checked      = [bool] $settings.NotifyYellowToGreen

[void] $menu.Items.Add($miNotifyRY)
[void] $menu.Items.Add($miNotifyYG)
[void] $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miRefresh = $menu.Items.Add('Refresh now')
$miExit    = $menu.Items.Add('Exit')

$miHeader.Enabled = $false
$miDetail.Enabled = $false
$miHeader.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon             = $icons['unknown']
$notify.Text             = "$($settings.ServerName) - checking..."
$notify.ContextMenuStrip = $menu
$notify.Visible          = $true

# Handlers are attached after Checked is seeded so loading the saved settings
# does not itself trigger a save.
$miNotifyRY.Add_CheckedChanged({ $settings.NotifyRedToYellow = $miNotifyRY.Checked; Save-Settings })
$miNotifyYG.Add_CheckedChanged({ $settings.NotifyYellowToGreen = $miNotifyYG.Checked; Save-Settings })
$miRefresh.Add_Click({ $sync.ForceRefresh = $true })
$miExit.Add_Click({ [System.Windows.Forms.Application]::ExitThread() })

function Show-Balloon([string] $title, [string] $text) {
    $notify.BalloonTipTitle = $title
    $notify.BalloonTipText  = $text
    $notify.ShowBalloonTip(8000)
}

# Double-click shows the current reading.
$notify.Add_MouseDoubleClick({
    Show-Balloon "$($sync.Server) - $($labels[$sync.Status])" $sync.Detail
})

# Transitions are compared against the last *known* status, so a brief
# connectivity blip (which shows as grey/unknown) does not swallow a real
# change or invent one.
$lastKnown    = $null
$lastRevision = -1

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($sync.Revision -eq $lastRevision) { return }
    $script:lastRevision = $sync.Revision

    $status = $sync.Status
    $notify.Icon = $icons[$status]

    $stamp = if ($sync.Updated) { $sync.Updated.ToString('HH:mm') } else { '--:--' }
    $short = if     ($null -eq $sync.IdleMinutes)           { '?' }
             elseif ($sync.IdleMinutes -eq [int]::MaxValue) { 'nobody on' }
             elseif ($sync.IdleMinutes -eq 0)               { 'active now' }
             elseif ($sync.IdleMinutes -lt 60)              { "idle $($sync.IdleMinutes)m" }
             else { 'idle {0}h{1}m' -f [int] ($sync.IdleMinutes / 60), ($sync.IdleMinutes % 60) }

    # NotifyIcon.Text is capped at 63 characters.
    $text = "$($sync.Server): $($labels[$status]) - $short  @$stamp"
    if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
    $notify.Text = $text

    $miHeader.Text = "$($sync.Server) - $($labels[$status])"
    $miDetail.Text = $sync.Detail

    if ($status -ne 'unknown') {
        if ($lastKnown -and $lastKnown -ne $status) {
            if ($lastKnown -eq 'busy' -and $status -eq 'idle-soon' -and $settings.NotifyRedToYellow) {
                Show-Balloon "$($sync.Server) may be freeing up" $sync.Detail
            }
            elseif ($lastKnown -eq 'idle-soon' -and $status -eq 'free' -and $settings.NotifyYellowToGreen) {
                Show-Balloon "$($sync.Server) is now free" $sync.Detail
            }
        }
        $script:lastKnown = $status
    }
})
$timer.Start()

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    $timer.Stop(); $timer.Dispose()
    $notify.Visible = $false
    $notify.Dispose()
    foreach ($i in $icons.Values) { $i.Dispose() }
    $sync.Stop = $true
    try { $worker.Stop() } catch { }
    $worker.Dispose()
    $runspace.Close(); $runspace.Dispose()
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
