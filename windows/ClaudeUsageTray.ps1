# ClaudeUsageTray — 윈도우 작업표시줄 트레이에 Claude 사용량 표시
# 필요: Claude Code 로그인 (%USERPROFILE%\.claude\.credentials.json 이 있어야 함)
# 실행: powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File ClaudeUsageTray.ps1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:CredPath = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$script:ClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"  # Claude Code 공개 OAuth 클라이언트
$script:TokenUrl = "https://console.anthropic.com/v1/oauth/token"
$script:UsageUrl = "https://api.anthropic.com/api/oauth/usage"

$script:WindowLabels = @{
    "five_hour"           = "5시간"
    "seven_day"           = "주간 (전체)"
    "seven_day_sonnet"    = "주간 (Sonnet)"
    "seven_day_opus"      = "주간 (Opus)"
    "seven_day_oauth_apps"= "주간 (연동 앱)"
}
$script:WindowOrder = @("five_hour","seven_day","seven_day_sonnet","seven_day_opus","seven_day_oauth_apps")

# 아이콘에 표시할 기준 창 (five_hour | seven_day) — 레지스트리에 저장해 재시작 후 유지
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

# 갱신 주기(초) — 기본 3분. 잦은 요청은 API 429 제한을 유발할 수 있음
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

function Get-FreshToken {
    if (-not (Test-Path $script:CredPath)) {
        throw "자격증명 없음 — 터미널에서 claude auth login 한 번 실행 필요"
    }
    $cred = Get-Content $script:CredPath -Raw | ConvertFrom-Json
    $oauth = $cred.claudeAiOauth
    if (-not $oauth -or -not $oauth.accessToken) {
        throw "accessToken 없음 — claude auth login 다시 실행 필요"
    }
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($oauth.expiresAt -and ($oauth.expiresAt -lt ($nowMs + 60000))) {
        # 만료 → refresh (갱신 토큰이 회전되므로 반드시 파일에 되써야 CLI 로그인도 유지됨)
        if (-not $oauth.refreshToken) { throw "토큰 만료 + 갱신 토큰 없음 — claude auth login 다시 실행 필요" }
        $body = @{ grant_type = "refresh_token"; refresh_token = $oauth.refreshToken; client_id = $script:ClientId } | ConvertTo-Json
        $resp = Invoke-RestMethod -Uri $script:TokenUrl -Method Post -ContentType "application/json" -Body $body -TimeoutSec 15
        $oauth.accessToken = $resp.access_token
        if ($resp.refresh_token) { $oauth.refreshToken = $resp.refresh_token }
        if ($resp.expires_in) {
            $newExp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + [long]($resp.expires_in * 1000)
            if ($oauth.PSObject.Properties["expiresAt"]) { $oauth.expiresAt = $newExp }
            else { $oauth | Add-Member -NotePropertyName expiresAt -NotePropertyValue $newExp }
        }
        $cred | ConvertTo-Json -Depth 10 | Set-Content $script:CredPath -Encoding UTF8
    }
    return $oauth.accessToken
}

function Get-Usage {
    $token = Get-FreshToken
    $headers = @{
        "Authorization"  = "Bearer $token"
        "anthropic-beta" = "oauth-2025-04-20"
    }
    $resp = Invoke-RestMethod -Uri $script:UsageUrl -Headers $headers -TimeoutSec 15
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
    $windows | Sort-Object { $i = $script:WindowOrder.IndexOf($_.Key); if ($i -lt 0) { 99 } else { $i } }
}

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
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $icon
}

# ---- 트레이 아이콘 구성 ----

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = New-PercentIcon "…" ([System.Drawing.Color]::White)
$notify.Text = "Claude 사용량: 로딩 중"
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $menu

function Update-Icon {
    if (-not $script:LastWindows) { return }
    $dispKey = Get-DisplayKey
    $sel = $script:LastWindows | Where-Object Key -eq $dispKey | Select-Object -First 1
    if (-not $sel) { $sel = $script:LastWindows | Where-Object Key -eq "five_hour" | Select-Object -First 1 }
    if (-not $sel) { $sel = $script:LastWindows[0] }
    $pct = [int][math]::Round($sel.Utilization)
    $color = if ($pct -lt 50) { [System.Drawing.Color]::LimeGreen }
             elseif ($pct -lt 80) { [System.Drawing.Color]::Gold }
             else { [System.Drawing.Color]::OrangeRed }
    $text = if ($dispKey -eq "seven_day") { "주$pct" } else { "$pct" }
    $old = $notify.Icon
    $notify.Icon = New-PercentIcon $text $color
    if ($old) { $old.Dispose() }
}

function Update-Usage {
    try {
        $windows = @(Get-Usage)
        if ($windows.Count -eq 0) { throw "사용량 데이터 없음" }
        $script:LastWindows = $windows
        Update-Icon

        $lines = foreach ($w in $windows) {
            $label = $script:WindowLabels[$w.Key]; if (-not $label) { $label = $w.Key }
            "{0}: {1}%{2}" -f $label, [int][math]::Round($w.Utilization), (Format-Reset $w.ResetsAt)
        }
        $tip = ($lines -join "`n")
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + "…" }  # NotifyIcon 툴팁 63자 제한
        $notify.Text = $tip

        $menu.Items.Clear()
        foreach ($w in $windows) {
            $label = $script:WindowLabels[$w.Key]; if (-not $label) { $label = $w.Key }
            $item = $menu.Items.Add(("{0} {1}: {2}%{3}" -f (Gauge $w.Utilization), $label, [int][math]::Round($w.Utilization), (Format-Reset $w.ResetsAt)))
            $item.Enabled = $false
        }
        $t = $menu.Items.Add(("마지막 갱신 {0:HH\:mm\:ss}" -f (Get-Date)))
        $t.Enabled = $false
        $script:HadSuccess = $true
    }
    catch {
        # 이전 정상 수치가 있으면 유지 (429 등 일시 오류로 화면을 덮지 않음)
        if ($script:HadSuccess) { return }
        $msg = $_.Exception.Message
        $old = $notify.Icon
        $notify.Icon = New-PercentIcon "!" ([System.Drawing.Color]::OrangeRed)
        if ($old) { $old.Dispose() }
        $tip = "Claude 사용량 오류: $msg"
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + "…" }
        $notify.Text = $tip
        $menu.Items.Clear()
        $item = $menu.Items.Add("⚠ $msg")
        $item.Enabled = $false
    }
    $menu.Items.Add("-") | Out-Null
    foreach ($opt in @(@{k="five_hour"; l="아이콘 기준: 5시간 창"}, @{k="seven_day"; l="아이콘 기준: 주간 한도"})) {
        $mi = $menu.Items.Add($opt.l)
        $mi.Checked = ((Get-DisplayKey) -eq $opt.k)
        $key = $opt.k
        $mi.add_Click({
            param($s, $e)
            Set-DisplayKey $key
            Update-Icon
            foreach ($it in $menu.Items) {
                if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $it.Text -like "아이콘 기준:*") {
                    $it.Checked = ($it.Text -eq $s.Text)
                }
            }
        }.GetNewClosure())
    }
    $menu.Items.Add("-") | Out-Null
    foreach ($opt in @(@{s=60; l="갱신 주기: 1분"}, @{s=120; l="갱신 주기: 2분 (추천)"}, @{s=180; l="갱신 주기: 3분 (가장 추천)"})) {
        $mi = $menu.Items.Add($opt.l)
        $mi.Checked = ((Get-RefreshSec) -eq $opt.s)
        $sec = $opt.s
        $mi.add_Click({
            param($s, $e)
            Set-RefreshSec $sec
            $script:timer.Interval = $sec * 1000
            foreach ($it in $menu.Items) {
                if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $it.Text -like "갱신 주기:*") {
                    $it.Checked = ($it.Text -eq $s.Text)
                }
            }
        }.GetNewClosure())
    }
    $menu.Items.Add("-") | Out-Null
    $refresh = $menu.Items.Add("지금 갱신")
    $refresh.add_Click({ Update-Usage })
    $exit = $menu.Items.Add("종료")
    $exit.add_Click({
        $script:timer.Stop()
        $notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = (Get-RefreshSec) * 1000
$script:timer.add_Tick({ Update-Usage })
$script:timer.Start()

Update-Usage
[System.Windows.Forms.Application]::Run()
