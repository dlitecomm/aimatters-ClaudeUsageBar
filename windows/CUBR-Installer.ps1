# ClaudeUsageBar(CUBR) 윈도우 설치/삭제 스크립트
# 설치:  powershell -ExecutionPolicy Bypass -File CUBR-Installer.ps1
# 삭제:  powershell -ExecutionPolicy Bypass -File CUBR-Installer.ps1 -Uninstall
# 설치 후에는 윈도우 설정 > 앱 > 설치된 앱 목록의 "ClaudeUsageBar" 항목으로도 제거 가능

param([switch]$Uninstall)

$ErrorActionPreference = "Stop"
$AppName    = "ClaudeUsageBar"
$Version    = "1.0"
$InstallDir = Join-Path $env:LOCALAPPDATA $AppName
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupLnk = Join-Path $StartupDir "$AppName.lnk"
$RegPath    = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"

function Stop-Tray {
    # ClaudeUsageTray 를 실행 중인 powershell / wscript 프로세스 종료
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "ClaudeUsageTray" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

if ($Uninstall) {
    Write-Host "▶ $AppName 삭제를 시작합니다."
    Stop-Tray
    if (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
    if (Test-Path $RegPath)    { Remove-Item $RegPath -Recurse -Force }
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
    Write-Host ""
    Write-Host "✅ 삭제 완료. (Claude Code 로그인 정보는 앱 것이 아니므로 그대로 유지됩니다)"
    exit 0
}

Write-Host "▶ $AppName 설치를 시작합니다."
Stop-Tray

# 1) 파일 복사
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item (Join-Path $src "ClaudeUsageTray.ps1") $InstallDir -Force
Copy-Item (Join-Path $src "ClaudeUsageTray.vbs") $InstallDir -Force
Copy-Item (Join-Path $src "CUBR-Installer.ps1") $InstallDir -Force
Write-Host "▶ 파일 복사: $InstallDir"

# 2) 시작 프로그램 등록 (로그인 시 자동 실행)
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($StartupLnk)
$lnk.TargetPath = "$env:SystemRoot\System32\wscript.exe"
$lnk.Arguments = """$InstallDir\ClaudeUsageTray.vbs"""
$lnk.WorkingDirectory = $InstallDir
$lnk.Description = "Claude 사용량 트레이"
$lnk.Save()
Write-Host "▶ 시작 프로그램에 등록했습니다."

# 3) 윈도우 '설치된 앱' 목록에 언인스톨 항목 등록 (HKCU — 관리자 권한 불필요)
New-Item -Path $RegPath -Force | Out-Null
Set-ItemProperty $RegPath "DisplayName"     "ClaudeUsageBar (Claude 사용량 트레이)"
Set-ItemProperty $RegPath "DisplayVersion"  $Version
Set-ItemProperty $RegPath "Publisher"       "ClaudeUsageBar"
Set-ItemProperty $RegPath "InstallLocation" $InstallDir
Set-ItemProperty $RegPath "UninstallString" "powershell -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\CUBR-Installer.ps1`" -Uninstall"
Set-ItemProperty $RegPath "NoModify" 1 -Type DWord
Set-ItemProperty $RegPath "NoRepair" 1 -Type DWord
$size = [int]((Get-ChildItem $InstallDir | Measure-Object Length -Sum).Sum / 1KB)
Set-ItemProperty $RegPath "EstimatedSize" $size -Type DWord
Write-Host "▶ 윈도우 '설치된 앱' 목록에 등록했습니다. (설정 > 앱에서 제거 가능)"

# 4) 즉시 실행
Start-Process "$env:SystemRoot\System32\wscript.exe" "`"$InstallDir\ClaudeUsageTray.vbs`""

Write-Host ""
Write-Host "✅ 설치 완료! 작업표시줄 트레이에서 % 아이콘을 확인하세요."
Write-Host "   (숨김 아이콘 ^ 안에 있을 수 있습니다. 숫자 대신 ! 가 뜨면 'claude auth login' 로그인이 필요합니다)"
