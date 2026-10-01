# ClaudeUsageTray — 윈도우 작업표시줄 트레이에 Claude 사용량 표시
# 필요: Claude Code 로그인 (%USERPROFILE%\.claude\.credentials.json 이 있어야 함)
# 실행: powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File ClaudeUsageTray.ps1
# 오류 기록: %LOCALAPPDATA%\ClaudeUsageBar\cubr.log

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 구형 윈도우/PowerShell 5.1은 기본이 TLS 1.0이라 api.anthropic.com 접속이 실패할 수 있다
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$script:CredPath = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$script:ClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"  # Claude Code 공개 OAuth 클라이언트
$script:TokenUrl = "https://console.anthropic.com/v1/oauth/token"
$script:UsageUrl = "https://api.anthropic.com/api/oauth/usage"
$script:LogDir   = Join-Path $env:LOCALAPPDATA "ClaudeUsageBar"
$script:LogPath  = Join-Path $script:LogDir "cubr.log"

$script:WindowLabels = @{
    "five_hour"           = "5시간"
    "seven_day"           = "주간 (전체)"
    "seven_day_sonnet"    = "주간 (Sonnet)"
    "seven_day_opus"      = "주간 (Opus)"
    "seven_day_oauth_apps"= "주간 (연동 앱)"
}
$script:WindowOrder = @("five_hour","seven_day","seven_day_sonnet","seven_day_opus","seven_day_oauth_apps")

# 상태
$script:LastWindows = $null
$script:LastUpdate  = $null
$script:LastError   = $null

function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        if ((Test-Path $script:LogPath) -and ((Get-Item $script:LogPath).Length -gt 200KB)) {
            Move-Item $script:LogPath ($script:LogPath + ".old") -Force
        }
        $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $msg
        [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

# ---- 설정 (레지스트리, 재시작 후 유지) ----
$script:CfgReg = "HKCU:\Software\ClaudeUsageBar"
function Get-DisplayKey {
    try {
        $v = (Get-ItemProperty -Path $script:CfgReg -Name DisplayWindow -ErrorAction Stop).DisplayWindow
        if ($v) { return $v }
    } catch {}
    return "five_hour"
}
function Set-DisplayKey($k) {
    New-Item -Path $script:CfgReg -Force | Out-Null
    Set-ItemProperty -Path $script:CfgReg -Name DisplayWindow -Value $k
}
function Get-RefreshSec {
    try {
        $v = (Get-ItemProperty -Path $script:CfgReg -Name RefreshSec -ErrorAction Stop).RefreshSec
        if ($v -ge 60) { return [int]$v }
    } catch {}
    return 180
}
function Set-RefreshSec($s) {
    New-Item -Path $script:CfgReg -Force | Out-Null
    Set-ItemProperty -Path $script:CfgReg -Name RefreshSec -Value ([int]$s) -Type DWord
}

# ---- 자격증명 ----

function Read-Credentials {
    if (-not (Test-Path $script:CredPath)) {
        throw "Claude Code 로그인 정보 없음 — 터미널에서 claude auth login 실행 필요"
    }
    # Claude Code가 파일을 쓰는 도중일 수 있으니 짧게 재시도
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:CredPath)
            $raw = $raw.TrimStart([char]0xFEFF)  # 혹시 남아 있는 BOM 제거
            return ($raw | ConvertFrom-Json)
        } catch {
            if ($i -eq 2) { throw "로그인 정보 파일을 읽을 수 없음: $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 300
        }
    }
}

function Write-Credentials($cred) {
    # BOM 없는 UTF-8로 써야 한다. Set-Content -Encoding UTF8 은 BOM을 붙여서
    # Claude Code(Node.js)가 JSON 파싱에 실패해 로그인이 깨진다.
    $json = $cred | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($script:CredPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Get-FreshToken {
    $cred = Read-Credentials
    $oauth = $cred.claudeAiOauth
    if (-not $oauth -or -not $oauth.accessToken) {
        throw "로그인 정보에 토큰 없음 — claude auth login 다시 실행 필요"
    }
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($oauth.expiresAt -and ([long]$oauth.expiresAt -lt ($nowMs + 60000))) {
        # 만료 → 갱신. 갱신 토큰이 회전되므로 원본 파일에 되써서 Claude Code와 같은 체인을 유지한다.
        if (-not $oauth.refreshToken) { throw "토큰 만료 (갱신 토큰 없음) — Claude Code를 한 번 실행하거나 claude auth login" }
        $body = @{ grant_type = "refresh_token"; refresh_token = $oauth.refreshToken; client_id = $script:ClientId } | ConvertTo-Json
        try {
            $resp = Invoke-RestMethod -Uri $script:TokenUrl -Method Post -ContentType "application/json" -Body $body -TimeoutSec 15
        } catch {
            Write-Log "토큰 갱신 실패: $($_.Exception.Message)"
            throw "토큰 갱신 실패 — Claude Code를 한 번 실행해 로그인을 갱신해 주세요"
        }
        $oauth.accessToken = $resp.access_token
        if ($resp.refresh_token) { $oauth.refreshToken = $resp.refresh_token }
        if ($resp.expires_in) {
            $newExp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + [long]($resp.expires_in * 1000)
            if ($oauth.PSObject.Properties["expiresAt"]) { $oauth.expiresAt = $newExp }
            else { $oauth | Add-Member -NotePropertyName expiresAt -NotePropertyValue $newExp }
        }
        Write-Credentials $cred
        Write-Log "토큰 갱신 성공 (원본 파일에 되씀)"
    }
    return $oauth.accessToken
}

# ---- 사용량 조회 ----

function Get-Usage {
    $token = Get-FreshToken
    $headers = @{
        "Authorization"  = "Bearer $token"
        "anthropic-beta" = "oauth-2025-04-20"
    }
    try {
        $resp = Invoke-RestMethod -Uri $script:UsageUrl -Headers $headers -TimeoutSec 15
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -eq 429) { throw "일시 요청 제한(429) — 다음 갱신 때 자동 재시도" }
        if ($code -eq 401) { throw "인증 만료(401) — 다음 갱신 때 다시 시도" }
        throw "사용량 조회 실패($code): $($_.Exception.Message)"
    }
    $windows = @()
    foreach ($prop in $resp.PSObject.Properties) {
        $v = $prop.Value
        if ($null -ne $v -and $v.PSObject.Properties["utilization"]) {
            $util = [double]$v.utilization
            if ($util -le 1.0) { $util *= 100 }  # 0-1 스케일 대비
            $resets = $null
            if ($v.PSObject.Properties["resets_at"] -and $v.resets_at) {
                try { $resets = ([DateTimeOffset]::Parse($v.resets_at)).LocalDateTime } catch {}
            }
            $windows += [pscustomobject]@{ Key = $prop.Name; Utilization = $util; ResetsAt = $resets }
        }
    }
    @($windows | Sort-Object { $i = $script:WindowOrder.IndexOf($_.Key); if ($i -lt 0) { 99 } else { $i } })
}

# ---- 표시 ----

function Format-Reset($d) {
    if ($null -eq $d) { return "" }
    if ($d.Date -eq (Get-Date).Date) { return " · 리셋 {0:HH\:mm}" -f $d }
    return " · 리셋 {0:M\/d HH\:mm}" -f $d
}

function Gauge($pct) {
    if ($pct -lt 50) { return "[G]" } elseif ($pct -lt 80) { return "[Y]" } else { return "[R]" }
}

function New-PercentIcon([string]$text, [System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = "AntiAlias"
    $g.TextRenderingHint = "AntiAliasGridFit"
    $g.Clear([System.Drawing.Color]::Transparent)
    $size = if ($text.Length -ge 3) { 13 } else { 17 }
    $font = New-Object System.Drawing.Font("Segoe UI", $size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $brush = New-Object System.Drawing.SolidBrush $color
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = "Center"; $fmt.LineAlignment = "Center"
    $rect = New-Object System.Drawing.RectangleF 0, 0, 32, 32
    $g.DrawString($text, $font, $brush, $rect, $fmt)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Set-TrayIcon([string]$text, [System.Drawing.Color]$color) {
    $old = $notify.Icon
    $notify.Icon = New-PercentIcon $text $color
    if ($old) { $old.Dispose() }
}

function Set-Tip([string]$tip) {
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + "…" }  # NotifyIcon 툴팁 63자 제한
    $notify.Text = $tip
}

function Test-Stale {
    if ($null -eq $script:LastUpdate) { return $true }
    return ((Get-Date) - $script:LastUpdate).TotalSeconds -gt ((Get-RefreshSec) * 3 + 60)
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = New-PercentIcon "…" ([System.Drawing.Color]::White)
$notify.Text = "Claude 사용량: 로딩 중"
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $menu

function Render-State {
    $stale = Test-Stale
    $hasData = ($null -ne $script:LastWindows -and $script:LastWindows.Count -gt 0)

    # 아이콘
    if ($hasData) {
        $dispKey = Get-DisplayKey
        $sel = $script:LastWindows | Where-Object Key -eq $dispKey | Select-Object -First 1
        if (-not $sel) { $sel = $script:LastWindows | Where-Object Key -eq "five_hour" | Select-Object -First 1 }
        if (-not $sel) { $sel = $script:LastWindows[0] }
        $pct = [int][math]::Round($sel.Utilization)
        # 갱신이 끊긴 채 옛 수치일 때는 회색으로 — 정상값처럼 보이지 않게
        $color = if ($script:LastError -or $stale) { [System.Drawing.Color]::Gray }
                 elseif ($pct -lt 50) { [System.Drawing.Color]::LimeGreen }
                 elseif ($pct -lt 80) { [System.Drawing.Color]::Gold }
                 else { [System.Drawing.Color]::OrangeRed }
        $text = if ($dispKey -eq "seven_day") { "주$pct" } else { "$pct" }
        Set-TrayIcon $text $color
    } elseif ($script:LastError) {
        Set-TrayIcon "!" ([System.Drawing.Color]::OrangeRed)
    }

    # 툴팁
    if ($script:LastError -and -not $hasData) {
        Set-Tip ("Claude 사용량 오류: " + $script:LastError)
    } elseif ($hasData) {
        $lines = foreach ($w in $script:LastWindows) {
            $label = $script:WindowLabels[$w.Key]; if (-not $label) { $label = $w.Key }
            "{0}: {1}%{2}" -f $label, [int][math]::Round($w.Utilization), (Format-Reset $w.ResetsAt)
        }
        $prefix = if ($script:LastError -or $stale) { "⚠ 갱신 끊김 (옛 값)`n" } else { "" }
        Set-Tip ($prefix + ($lines -join "`n"))
    }

    # 메뉴
    $menu.Items.Clear()
    if ($script:LastError) {
        $e = $menu.Items.Add("⚠ " + $script:LastError); $e.Enabled = $false
    }
    if ($hasData) {
        foreach ($w in $script:LastWindows) {
            $label = $script:WindowLabels[$w.Key]; if (-not $label) { $label = $w.Key }
            $item = $menu.Items.Add(("{0} {1}: {2}%{3}" -f (Gauge $w.Utilization), $label, [int][math]::Round($w.Utilization), (Format-Reset $w.ResetsAt)))
            $item.Enabled = $false
        }
    }
    if ($script:LastUpdate) {
        $fmt = if ($script:LastUpdate.Date -eq (Get-Date).Date) { "HH\:mm\:ss" } else { "M\/d HH\:mm" }
        $note = if ($stale) { " (오래된 값)" } else { "" }
        $t = $menu.Items.Add(("마지막 갱신 {0:$fmt}{1}" -f $script:LastUpdate, $note)); $t.Enabled = $false
    }
    $menu.Items.Add("-") | Out-Null
    foreach ($opt in @(@{k="five_hour"; l="아이콘 기준: 5시간 창"}, @{k="seven_day"; l="아이콘 기준: 주간 한도"})) {
        $mi = $menu.Items.Add($opt.l)
        $mi.Checked = ((Get-DisplayKey) -eq $opt.k)
        $key = $opt.k
        $mi.add_Click({ Set-DisplayKey $key; Render-State }.GetNewClosure())
    }
    $menu.Items.Add("-") | Out-Null
    foreach ($opt in @(@{s=60; l="갱신 주기: 1분"}, @{s=120; l="갱신 주기: 2분 (추천)"}, @{s=180; l="갱신 주기: 3분 (가장 추천)"})) {
        $mi = $menu.Items.Add($opt.l)
        $mi.Checked = ((Get-RefreshSec) -eq $opt.s)
        $sec = $opt.s
        $mi.add_Click({ Set-RefreshSec $sec; $script:timer.Interval = $sec * 1000; Render-State }.GetNewClosure())
    }
    $menu.Items.Add("-") | Out-Null
    $log = $menu.Items.Add("오류 기록 열기")
    $log.add_Click({ if (Test-Path $script:LogPath) { Start-Process notepad.exe $script:LogPath } else { [System.Windows.Forms.MessageBox]::Show("아직 기록된 오류가 없습니다.", "ClaudeUsageBar") | Out-Null } })
    $refresh = $menu.Items.Add("지금 갱신")
    $refresh.add_Click({ Update-Usage })
    $exit = $menu.Items.Add("종료")
    $exit.add_Click({
        $script:timer.Stop()
        $notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
}

function Update-Usage {
    try {
        $windows = @(Get-Usage)
        if ($windows.Count -eq 0) { throw "사용량 데이터 없음" }
        $script:LastWindows = $windows
        $script:LastUpdate  = Get-Date
        $script:LastError   = $null
    }
    catch {
        $script:LastError = $_.Exception.Message
        Write-Log "오류: $($script:LastError)"
    }
    Render-State
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = (Get-RefreshSec) * 1000
$script:timer.add_Tick({ Update-Usage })
$script:timer.Start()

Write-Log "시작 (갱신 주기 $(Get-RefreshSec)초)"
Update-Usage
[System.Windows.Forms.Application]::Run()
