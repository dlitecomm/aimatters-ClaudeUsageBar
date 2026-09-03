import Cocoa

extension String: @retroactive Error {}

// MARK: - 자격증명 저장소 (Claude Code가 저장한 OAuth 토큰)
// macOS: 키체인 서비스 "Claude Code-credentials" / 폴백: ~/.claude/.credentials.json
// 토큰이 만료되면 refreshToken으로 직접 갱신하고 저장소에 다시 써 둔다.

let kService = "Claude Code-credentials"
let kOwnService = "ClaudeUsageBar" // 앱 소유 항목 — 자기가 만든 항목은 접근 프롬프트가 없다
let kClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code 공개 OAuth 클라이언트
let kTokenURL = "https://console.anthropic.com/v1/oauth/token"
let kUsageURL = "https://api.anthropic.com/api/oauth/usage"

enum CredSource {
    case own       // 앱 소유 키체인 항목 (기본 경로 — 프롬프트 없음)
    case file(URL) // ~/.claude/.credentials.json 폴백
}

struct CredStore {
    var obj: [String: Any]   // 저장소 전체 JSON (mcpOAuth 등 다른 필드 보존)
    var source: CredSource

    var oauth: [String: Any]? { obj["claudeAiOauth"] as? [String: Any] }
    var accessToken: String? { oauth?["accessToken"] as? String }
    var refreshToken: String? { oauth?["refreshToken"] as? String }
    var expiresAt: Double? { oauth?["expiresAt"] as? Double } // ms epoch
}

func keychainRead(service: String, account: String) -> (Data?, OSStatus) {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var ref: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &ref)
    return (status == errSecSuccess ? ref as? Data : nil, status)
}

func ownItemWrite(_ data: Data) {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kOwnService,
        kSecAttrAccount as String: "default",
    ]
    let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        var add = q
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

// 실행 중에는 메모리 캐시를 사용해 키체인 접근(=허용 프롬프트 기회)을 최소화한다.
var cachedStore: CredStore?
// Claude Code의 키체인 항목은 앱 시작 시 1회만 읽어 자기 항목으로 복사한다.
// 거부되면 자동 재시도하지 않고(허용 창 반복 방지) '지금 갱신'을 눌렀을 때만 다시 시도한다.
var keychainBlocked = false

func loadStore() -> Result<CredStore, String> {
    if let c = cachedStore { return .success(c) }

    // 1) 수동 등록 토큰 파일 — `claude setup-token`으로 발급한 장기 토큰.
    //    키체인을 전혀 거치지 않는 최우선 경로 (프롬프트 원천 차단).
    let tokenPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/cubr-token")
    if let raw = try? String(contentsOf: tokenPath, encoding: .utf8) {
        // 파일 안 어디에 있든 sk-ant-… 토큰만 뽑아낸다 (앞뒤 공백·다른 텍스트 허용)
        if let r = raw.range(of: #"sk-ant-[A-Za-z0-9_\-]{20,}"#, options: .regularExpression) {
            let tok = String(raw[r])
            let store = CredStore(obj: ["claudeAiOauth": ["accessToken": tok]], source: .own)
            cachedStore = store
            return .success(store)
        }
    }

    // 1.5) 앱 소유 키체인 항목
    let (ownData, _) = keychainRead(service: kOwnService, account: "default")
    if let d = ownData, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        let store = CredStore(obj: o, source: .own)
        if store.accessToken != nil { cachedStore = store; return .success(store) }
    }

    // 2) 파일 폴백 (~/.claude/.credentials.json — 프롬프트 없음)
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")
    if let d = try? Data(contentsOf: path),
       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        let store = CredStore(obj: o, source: .file(path))
        if store.accessToken != nil { cachedStore = store; return .success(store) }
    }

    // 3) 부트스트랩: Claude Code CLI의 키체인 항목에서 1회 복사.
    //    여기서만 시스템 허용 창이 뜰 수 있고, 거부되면 자동으로 다시 두드리지 않는다.
    if keychainBlocked {
        return .failure("키체인 접근 보류 중 — 메뉴의 '지금 갱신'을 누르면 다시 시도합니다")
    }
    let listQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kService,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var listRef: CFTypeRef?
    let listStatus = SecItemCopyMatching(listQuery as CFDictionary, &listRef)
    var accounts: [String] = []
    if listStatus == errSecSuccess {
        let attrsList = (listRef as? [[String: Any]]) ?? (listRef as? [String: Any]).map { [$0] } ?? []
        accounts = attrsList.compactMap { $0[kSecAttrAccount as String] as? String }
    }
    var lastStatus: OSStatus = listStatus
    for account in accounts {
        let (d, status) = keychainRead(service: kService, account: account)
        lastStatus = status
        guard let d = d,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let oauth = o["claudeAiOauth"] as? [String: Any],
              oauth["accessToken"] is String else { continue }
        // 자기 소유 항목으로 복사 — 이후로는 프롬프트 없이 여기만 사용
        let obj: [String: Any] = ["claudeAiOauth": oauth]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { ownItemWrite(data) }
        let store = CredStore(obj: obj, source: .own)
        cachedStore = store
        return .success(store)
    }
    if lastStatus == errSecUserCanceled || lastStatus == errSecAuthFailed || lastStatus == errSecInteractionNotAllowed {
        keychainBlocked = true
        return .failure("키체인 접근이 거부됨 — 메뉴의 '지금 갱신'으로 재시도 (허용 창에서 '허용' 한 번이면 됩니다)")
    }
    return .failure("토큰 없음 — 터미널에서 claude setup-token 발급 후 ~/.claude/cubr-token 에 저장")
}

func saveStore(_ store: CredStore) {
    guard let data = try? JSONSerialization.data(withJSONObject: store.obj) else { return }
    switch store.source {
    case .own:
        ownItemWrite(data) // 자기 항목이라 프롬프트 없음
    case .file(let url):
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 토큰 갱신

func refreshToken(store: CredStore, completion: @escaping (Result<CredStore, String>) -> Void) {
    guard let refresh = store.refreshToken else {
        completion(.failure("토큰 만료 + 갱신 토큰 없음 — claude auth login 다시 실행 필요"))
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
            completion(.failure("토큰 갱신 실패(\(code)) — claude auth login 다시 실행 필요"))
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
        // 갱신 토큰이 회전되므로 앱 소유 저장소에 되써 둔다.
        // CLI 쪽 항목은 건드리지 않으므로(프롬프트 방지) CLI 로그인이 나중에 풀릴 수 있는데,
        // 그때는 claude auth login 을 다시 하면 되고 앱에는 영향이 없다.
        saveStore(newStore)
        cachedStore = newStore
        completion(.success(newStore))
    }.resume()
}

func withFreshToken(completion: @escaping (Result<String, String>) -> Void) {
    switch loadStore() {
    case .failure(let msg): completion(.failure(msg))
    case .success(let store):
        let now = Date().timeIntervalSince1970
        if let exp = store.expiresAt, exp / 1000 < now + 60 {
            refreshToken(store: store) { result in
                completion(result.map { $0.accessToken ?? "" })
            }
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

    func updateTitle() {
        guard !lastWindows.isEmpty else { return }
        let target = lastWindows.first { $0.key == displayKey }
            ?? lastWindows.first { $0.key == "five_hour" }
            ?? lastWindows[0]
        let prefix = displayKey == "seven_day" ? "주" : ""
        setBarText("✳\(prefix)\(Int(target.utilization.rounded()))%")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ClaudeUsageBar" // 사용자가 ⌘드래그로 옮긴 위치를 기억
        setBarText("✳…")
        rebuildMenu()
        refresh()
        startTimer()
    }

    func refresh() {
        fetchUsage { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let windows):
                    self.lastWindows = windows
                    self.lastError = nil
                    self.lastUpdate = Date()
                    self.updateTitle()
                case .failure(let msg):
                    self.lastError = msg
                    // 이전 정상 수치가 있으면 유지하고, 없을 때만 오류 표시
                    if self.lastWindows.isEmpty {
                        self.setBarText("✳–")
                    }
                }
                self.rebuildMenu()
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
            let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
            let item = NSMenuItem(title: "마지막 갱신 \(fmt.string(from: t))", action: nil, keyEquivalent: "")
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
        keychainBlocked = false // 수동 갱신 때만 부트스트랩 재시도 허용
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
