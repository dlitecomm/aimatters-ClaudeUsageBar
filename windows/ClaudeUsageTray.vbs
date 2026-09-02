' 창 없이 트레이 앱 실행 (더블클릭용)
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
shell.Run "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\ClaudeUsageTray.ps1""", 0, False
