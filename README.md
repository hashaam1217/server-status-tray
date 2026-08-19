# Server Status Tray

A coloured dot in the Windows notification area that tells you, at a glance,
whether a shared Windows server is currently being used — based on how long ago
it last received keyboard or mouse input.

| Dot | Meaning | Last input |
| --- | --- | --- |
| 🔴 Red | In use right now | less than 5 minutes ago |
| 🟡 Yellow | Maybe still in use | 5–10 minutes ago |
| 🟢 Green | Free | more than 10 minutes ago |
| ⚪ Grey | Unknown — the server could not be read | — |

Hover for the current reading. Double-click for a notification with the detail.
Right-click for the menu.

## Install

Requires Windows and PowerShell 5.1 (built in). No admin rights needed —
everything is installed per-user.

```powershell
gh repo clone hashaam1217/server-status-tray "$env:TEMP\server-status-tray"
& "$env:TEMP\server-status-tray\install.ps1"
```

That copies the app into `%LOCALAPPDATA%\ServerStatusTray`, adds a Start Menu
entry and a Startup entry so it comes back at logon, pins the icon to the
visible part of the tray, and starts it.

Watching a different machine, or different thresholds:

```powershell
.\install.ps1 -Server 'OTHER-SERVER' -BusyMinutes 5 -IdleMinutes 10 -PollSeconds 30
```

Useful switches: `-NoStartup` (don't launch at logon), `-NoLaunch` (install
without starting).

## Notifications

Right-click the icon. Two toggles, independently selectable, off by default:

- **Notify on green → yellow** — the server went from free to showing recent
  input, i.e. somebody has started using it again.
- **Notify on yellow → green** — the server crossed the idle threshold and is
  now free.

The setting is remembered across restarts.

Transitions are compared against the last *known* status, so a momentary
connection failure (which shows as grey) neither swallows a real change nor
invents a false one.

> Note: a server going straight from idle to actively used jumps **green →
> red**, skipping yellow, because a fresh session reports 0 minutes idle. Yellow
> is normally reached on the way *up* from red. If you want a "someone sat
> down" alert that fires reliably, a green → red toggle is the one to add.

## Configuration

`%LOCALAPPDATA%\ServerStatusTray\settings.json`:

```json
{
  "ServerName": "1461-Server",
  "BusyMinutes": 5,
  "IdleMinutes": 10,
  "PollSeconds": 30,
  "NotifyGreenToYellow": false,
  "NotifyYellowToGreen": false
}
```

Idle strictly below `BusyMinutes` is red; below `IdleMinutes` is yellow; at or
above `IdleMinutes` is green. Re-running `install.ps1` rewrites this file but
preserves the two notification toggles.

## How it works

The reading comes from the remote session table:

```
quser /server:1461-Server
```

```
 USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME
 admin                 rdp-tcp#7           2  Active          7  2026-08-17 6:12 PM
```

The `IDLE TIME` column is how long since that session's last input. The tray
takes the **smallest** idle time across all sessions — the most recent input
anyone gave the box — and colours the dot from that.

Notes on the implementation:

- `quser` works over plain RPC, so **no WinRM / PowerShell Remoting is needed**
  on the target. You do need rights to query sessions on it.
- Columns are read at fixed offsets taken from the header row, not split on
  whitespace: a disconnected session leaves `SESSIONNAME` blank and would
  otherwise shift every field.
- Idle cells are parsed in all the forms `quser` emits: `.` (active now),
  `7`, `1:23`, `3+01:23`, and `none`.
- The server is polled on a background runspace, so a slow or unreachable host
  never freezes the UI thread.
- Tray icons are generated once at startup and reused; building one per tick
  would leak GDI handles.
- A named mutex keeps it to a single instance.

## Uninstall

```powershell
& "$env:TEMP\server-status-tray\uninstall.ps1"
```

Add `-KeepSettings` to keep `settings.json`.

## Licence

MIT
