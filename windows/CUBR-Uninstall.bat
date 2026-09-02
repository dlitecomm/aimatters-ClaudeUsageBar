@echo off
rem ClaudeUsageBar (CUBR) uninstaller - double-click to remove
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CUBR-Installer.ps1" -Uninstall
pause
