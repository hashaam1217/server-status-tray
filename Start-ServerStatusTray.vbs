' Launches the server status tray icon with no console window.
Dim sh, script
Set sh = CreateObject("WScript.Shell")
script = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\")) & "ServerStatusTray.ps1"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
