import Cocoa

extension String: @retroactive Error {}

// MARK: - 자격증명 (Claude Code가 저장한 OAuth 토큰)
//
// 토큰 출처 우선순위:
//  1) ~/.claude/cubr-token  — 사용자가 직접 넣어둔 장기 토큰(선택). 갱신 없음.
//  2) Claude Code 키체인 항목 — Apple 정식 도구 /usr/bin/security 로 읽는다.
//     키체인은 security 도구를 기본 신뢰하므로 허용 창이 뜨지 않고, Claude Code가
//     항목을 다시 만들어도 영향이 없다. (앱이 Security 프레임워크로 직접 읽으면
//     항목이 재생성될 때마다 허용 창이 다시 뜬다 — 그래서 쓰지 않는다.)
//  3) ~/.claude/.credentials.json — 리눅스/윈도우식 파일 저장 폴백.
//
// 토큰 갱신: 만료되면 먼저 원본을 다시 읽는다(Claude Code가 이미 갱신했을 수 있음).
// 그래도 만료면 refreshToken으로 갱신하고 **원본에 되쓴다**. 복사본을 따로 갱신하면
// 갱신 토큰 회전 때문에 Claude Code 쪽과 충돌해 둘 중 하나가 죽는다.

let kService = "Claude Code-credentials"
let kClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code 공개 OAuth 클라이언트
let kTokenURL = "https://console.anthropic.com/v1/oauth/token"
let kUsageURL = "https://api.anthropic.com/api/oauth/usage"

enum CredSource {
    case tokenFile            // ~/.claude/cubr-token (갱신 불가)
    case cli(account: String) // Claude Code 키체인 항목 (security 도구 경유)
    case file(URL)            // ~/.claude/.credentials.json
}

struct CredStore {
    var obj: [String: Any]   // 저장소 전체 JSON (mcpOAuth 등 다른 필드 보존)
    var source: CredSource

    var oauth: [String: Any]? { obj["claudeAiOauth"] as? [String: Any] }
    var accessToken: String? { oauth?["accessToken"] as? String }
    var refreshToken: String? { oauth?["refreshToken"] as? String }
    var expiresAt: Double? { oauth?["expiresAt"] as? Double } // ms epoch
    var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return exp / 1000 < Date().timeIntervalSince1970 + 60
    }
}

/// /usr/bin/security 실행. 허용 창이 떠서 응답을 기다리는 경우를 대비해 시간 제한을 둔다.
func runSecurity(_ args: [String], timeout: TimeInterval = 45) -> (out: String, err: String, code: Int32, timedOut: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch { return ("", "\(error)", -1, false) }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    var timedOut = false
    if p.isRunning { p.terminate(); timedOut = true }
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (out, err, p.terminationStatus, timedOut)
}

/// Claude Code 키체인 항목을 읽는다. 실패 사유를 메시지로 돌려준다.
func readCLIItem() -> Result<CredStore, String> {
    // 계정 이름(acct)부터 — 비밀값 없이 속성만 출력된다
    let meta = runSecurity(["find-generic-password", "-s", kService], timeout: 15)
    if meta.code != 0 {
        if meta.err.contains("could not be found") {
            return .failure("Claude Code 로그인 정보 없음 — 터미널에서 claude auth login 실행 필요")
        }
        return .failure("키체인 조회 실패: \(meta.err.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    var account = ""
    if let r = meta.out.range(of: #""acct"<blob>="([^"]*)""#, options: .regularExpression) {
        let line = String(meta.out[r])
        if let q1 = line.range(of: "=\""), let q2 = line.range(of: "\"", options: .backwards) {
            account = String(line[q1.upperBound..<q2.lowerBound])
        }
    }
    var args = ["find-generic-password", "-s", kService]
    if !account.isEmpty { args += ["-a", account] }
    args.append("-w")
    let r = runSecurity(args)
    if r.timedOut {
        return .failure("키체인 허용 창 응답 대기 중 시간 초과 — 메뉴의 '지금 갱신'으로 재시도")
    }
    guard r.code == 0 else {
        if r.err.contains("User interaction is not allowed") || r.err.contains("canceled") {
            return .failure("키체인 접근이 거부됨 — 메뉴의 '지금 갱신'으로 재시도")
        }
        return .failure("키체인 읽기 실패: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    guard let data = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return .failure("키체인 항목 형식을 해석할 수 없음")
    }
    let store = CredStore(obj: o, source: .cli(account: account))
    guard store.accessToken != nil else {
        return .failure("키체인 항목에 계정 토큰 없음 — claude auth login 실행 필요")
    }
    return .success(store)
}

/// Claude Code 키체인 항목에 되쓴다 (-U: 기존 항목 갱신). security 도구가 쓰므로 허용 창 없음.
func writeCLIItem(account: String, json: Data) {
    guard let s = String(data: json, encoding: .utf8) else { return }
    var args = ["add-generic-password", "-U", "-s", kService]
    if !account.isEmpty { args += ["-a", account] }
    args += ["-w", s]
    _ = runSecurity(args, timeout: 15)
}

// 실행 중에는 메모리 캐시를 쓴다. 만료·401 때만 다시 읽는다.
var cachedStore: CredStore?

func loadStore(force: Bool = false) -> Result<CredStore, String> {
    if !force, let c = cachedStore { return .success(c) }

    // 1) 수동 등록 토큰 파일
    let tokenPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/cubr-token")
    if let raw = try? String(contentsOf: tokenPath, encoding: .utf8),
       let r = raw.range(of: #"sk-ant-[A-Za-z0-9_\-]{20,}"#, options: .regularExpression) {
        let store = CredStore(obj: ["claudeAiOauth": ["accessToken": String(raw[r])]], source: .tokenFile)
        cachedStore = store
        return .success(store)
    }

    // 2) Claude Code 키체인 항목 (security 도구)
    let cli = readCLIItem()
    if case .success(let store) = cli { cachedStore = store; return .success(store) }

    // 3) 파일 폴백
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")
    if let d = try? Data(contentsOf: path),
       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        let store = CredStore(obj: o, source: .file(path))
        if store.accessToken != nil { cachedStore = store; return .success(store) }
    }

    return cli // 키체인 쪽 실패 사유를 그대로 보여준다
}

func saveStore(_ store: CredStore) {
    guard let data = try? JSONSerialization.data(withJSONObject: store.obj) else { return }
    switch store.source {
    case .tokenFile: break
    case .cli(let account): writeCLIItem(account: account, json: data)
    case .file(let url): try? data.write(to: url, options: .atomic)
    }
}

/// 예전 버전이 만들었던 앱 소유 키체인 항목 정리 (우리 항목이라 허용 창 없음)
func removeLegacyOwnItem() {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ClaudeUsageBar",
    ]
    SecItemDelete(q as CFDictionary)
}

// MARK: - 토큰 갱신

func refreshToken(store: CredStore, completion: @escaping (Result<CredStore, String>) -> Void) {
    guard let refresh = store.refreshToken else {
        completion(.failure("토큰 만료 (갱신 토큰 없음) — Claude Code를 한 번 실행하거나 claude auth login"))
        return
    }
    var req = URLRequest(url: URL(string: kTokenURL)!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: [
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "client_id": kClientID,
    ])
    req.timeoutInterval = 15
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err { completion(.failure("토큰 갱신 네트워크 오류: \(err.localizedDescription)")); return }
        guard let http = resp as? HTTPURLResponse, let data = data, http.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String
        else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            cachedStore = nil // 다음 갱신 때 원본을 다시 읽는다
            completion(.failure("토큰 갱신 실패(\(code)) — Claude Code를 한 번 실행해 로그인을 갱신해 주세요"))
            return
        }
        var newStore = store
        var oauth = newStore.oauth ?? [:]
        oauth["accessToken"] = access
        if let newRefresh = o["refresh_token"] as? String { oauth["refreshToken"] = newRefresh }
        if let expiresIn = o["expires_in"] as? Double {
            oauth["expiresAt"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
        }
        newStore.obj["claudeAiOauth"] = oauth
        saveStore(newStore) // 원본에 되써서 Claude Code와 같은 토큰 체인을 유지
        cachedStore = newStore
        completion(.success(newStore))
    }.resume()
}

func withFreshToken(completion: @escaping (Result<String, String>) -> Void) {
    var result = loadStore()
    // 캐시된 토큰이 만료됐으면 원본을 다시 읽는다 — Claude Code가 이미 갱신해 뒀을 수 있다
    if case .success(let s) = result, s.isExpired { result = loadStore(force: true) }
    switch result {
    case .failure(let msg): completion(.failure(msg))
    case .success(let store):
        if store.isExpired {
            refreshToken(store: store) { r in completion(r.map { $0.accessToken ?? "" }) }
        } else {
            completion(.success(store.accessToken ?? ""))
        }
    }
}

// MARK: - 사용량 API

struct UsageWindow {
    let key: String
    let utilization: Double // 0-100
    let resetsAt: Date?
}

let windowLabels: [String: String] = [
    "five_hour": "5시간",
    "seven_day": "주간 (전체)",
    "seven_day_sonnet": "주간 (Sonnet)",
    "seven_day_opus": "주간 (Opus)",
    "seven_day_oauth_apps": "주간 (연동 앱)",
]

func parseUsage(_ data: Data) -> [UsageWindow] {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    let iso = ISO8601DateFormatter()
    let isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var out: [UsageWindow] = []
    for (key, value) in obj {
        guard let dict = value as? [String: Any], var util = dict["utilization"] as? Double else { continue }
        if util <= 1.0 { util *= 100 } // 0-1 스케일로 올 경우 대비
        var resets: Date?
        if let s = dict["resets_at"] as? String {
            resets = isoFrac.date(from: s) ?? iso.date(from: s)
        } else if let t = dict["resets_at"] as? Double {
            resets = Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t)
        }
        out.append(UsageWindow(key: key, utilization: util, resetsAt: resets))
    }
    let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps"]
    out.sort { (order.firstIndex(of: $0.key) ?? 99) < (order.firstIndex(of: $1.key) ?? 99) }
    return out
}

func fetchUsage(completion: @escaping (Result<[UsageWindow], String>) -> Void) {
    withFreshToken { result in
        switch result {
        case .failure(let msg): completion(.failure(msg))
        case .success(let token):
            var req = URLRequest(url: URL(string: kUsageURL)!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.timeoutInterval = 15
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err { completion(.failure("네트워크 오류: \(err.localizedDescription)")); return }
                guard let http = resp as? HTTPURLResponse, let data = data else {
                    completion(.failure("응답 없음")); return
                }
                guard http.statusCode == 200 else {
                    if http.statusCode == 429 {
                        completion(.failure("일시 요청 제한 — 다음 갱신 때 자동 재시도")); return
                    }
                    if http.statusCode == 401 {
                        // 캐시된 토큰이 무효 — 다음 갱신 때 저장소에서 다시 읽음
                        cachedStore = nil
                        completion(.failure("인증 만료 — 다음 갱신 때 자동 재시도")); return
                    }
                    let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                    completion(.failure("API 오류 \(http.statusCode): \(body)")); return
                }
                let windows = parseUsage(data)
                if windows.isEmpty {
                    let body = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                    completion(.failure("사용량 데이터 없음: \(body)"))
                } else {
                    completion(.success(windows))
                }
            }.resume()
        }
    }
}

// MARK: - 표시 포맷

func resetString(_ date: Date?) -> String {
    guard let date = date else { return "" }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "ko_KR")
    fmt.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d(E) HH:mm"
    return " · 리셋 \(fmt.string(from: date))"
}

func gauge(_ pct: Double) -> String {
    switch pct {
    case ..<50: return "🟢"
    case ..<80: return "🟡"
    default: return "🔴"
    }
}

// MARK: - CLI 검증 모드 (--once)

if CommandLine.arguments.contains("--once") {
    let sem = DispatchSemaphore(value: 0)
    fetchUsage { result in
        switch result {
        case .failure(let msg): print("ERROR: \(msg)")
        case .success(let windows):
            for w in windows {
                let label = windowLabels[w.key] ?? w.key
                print("\(label): \(String(format: "%.0f", w.utilization))%\(resetString(w.resetsAt))")
            }
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// MARK: - 메뉴바 앱

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastWindows: [UsageWindow] = []
    var lastError: String?
    var lastUpdate: Date?

    // 상태바에 표시할 기준 창 (five_hour | seven_day) — 재시작 후에도 유지
    var displayKey: String {
        get { UserDefaults.standard.string(forKey: "displayWindow") ?? "five_hour" }
        set { UserDefaults.standard.set(newValue, forKey: "displayWindow") }
    }

    // 갱신 주기(초) — 기본 3분. 잦은 요청은 API 429 제한을 유발할 수 있음
    var refreshInterval: Double {
        get { let v = UserDefaults.standard.double(forKey: "refreshInterval"); return v > 0 ? v : 180 }
        set { UserDefaults.standard.set(newValue, forKey: "refreshInterval") }
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // 노치 맥북은 메뉴바 공간이 부족하면 아이콘을 통째로 숨기므로 폭을 최소화한다.
    func setBarText(_ s: String) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.attributedTitle = NSAttributedString(string: s, attributes: [.font: font])
    }

    // 마지막 성공 후 이만큼 지나면 '오래된 값'으로 본다 (갱신 주기 3회분 + 여유)
    var isStale: Bool {
        guard let t = lastUpdate else { return true }
        return Date().timeIntervalSince(t) > refreshInterval * 3 + 60
    }

    func updateTitle() {
        guard !lastWindows.isEmpty else { return }
        let target = lastWindows.first { $0.key == displayKey }
            ?? lastWindows.first { $0.key == "five_hour" }
            ?? lastWindows[0]
        let prefix = displayKey == "seven_day" ? "주" : ""
        // 갱신이 끊긴 채 옛 수치를 보여줄 때는 ⚠ 를 붙여 정상값처럼 보이지 않게 한다
        let mark = (lastError != nil || isStale) ? "⚠" : ""
        setBarText("✳\(prefix)\(Int(target.utilization.rounded()))%\(mark)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        removeLegacyOwnItem()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ClaudeUsageBar" // 사용자가 ⌘드래그로 옮긴 위치를 기억
        setBarText("✳…")
        rebuildMenu()
        refresh()
        startTimer()
    }

    var refreshing = false

    func refresh() {
        if refreshing { return } // 허용 창 대기 등으로 길어질 때 중복 실행 방지
        refreshing = true
        // 키체인 조회가 길어져도(허용 창 대기) 메뉴바가 멈추지 않도록 백그라운드에서 실행
        DispatchQueue.global(qos: .utility).async {
            fetchUsage { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.refreshing = false
                    switch result {
                    case .success(let windows):
                        self.lastWindows = windows
                        self.lastError = nil
                        self.lastUpdate = Date()
                    case .failure(let msg):
                        self.lastError = msg
                    }
                    if self.lastWindows.isEmpty {
                        self.setBarText(self.lastError == nil ? "✳…" : "✳–")
                    } else {
                        self.updateTitle() // 옛 수치 유지 + 오류 시 ⚠ 표시
                    }
                    self.rebuildMenu()
                }
            }
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        if let err = lastError {
            let item = NSMenuItem(title: "⚠️ \(err)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for w in lastWindows {
            let label = windowLabels[w.key] ?? w.key
            let title = "\(gauge(w.utilization)) \(label): \(Int(w.utilization.rounded()))%\(resetString(w.resetsAt))"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let t = lastUpdate {
            let fmt = DateFormatter()
            fmt.dateFormat = Calendar.current.isDateInToday(t) ? "HH:mm:ss" : "M/d HH:mm"
            let note = isStale ? " (오래된 값)" : ""
            let item = NSMenuItem(title: "마지막 갱신 \(fmt.string(from: t))\(note)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let header = NSMenuItem(title: "상태바 표시 기준", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (key, label) in [("five_hour", "5시간 창"), ("seven_day", "주간 한도")] {
            let item = NSMenuItem(title: label, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = (displayKey == key) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let intervalHeader = NSMenuItem(title: "갱신 주기", action: nil, keyEquivalent: "")
        intervalHeader.isEnabled = false
        menu.addItem(intervalHeader)
        let intervals: [(Double, String)] = [
            (60, "1분"),
            (120, "2분 (추천)"),
            (180, "3분 (가장 추천)"),
        ]
        for (sec, label) in intervals {
            let item = NSMenuItem(title: label, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sec
            item.state = (refreshInterval == sec) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "지금 갱신", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc func refreshNow() {
        cachedStore = nil // 수동 갱신은 토큰도 원본에서 다시 읽는다
        refresh()
    }

    @objc func selectDisplay(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { displayKey = key }
        updateTitle()
        rebuildMenu()
    }

    @objc func selectInterval(_ sender: NSMenuItem) {
        if let sec = sender.representedObject as? Double {
            refreshInterval = sec
            startTimer()
        }
        rebuildMenu()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
