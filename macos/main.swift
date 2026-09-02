import Cocoa

extension String: @retroactive Error {}

// MARK: - 자격증명 저장소 (Claude Code가 저장한 OAuth 토큰)
// macOS: 키체인 서비스 "Claude Code-credentials" / 폴백: ~/.claude/.credentials.json
// 토큰이 만료되면 refreshToken으로 직접 갱신하고 저장소에 다시 써 둔다.

let kService = "Claude Code-credentials"
let kClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code 공개 OAuth 클라이언트
let kTokenURL = "https://console.anthropic.com/v1/oauth/token"
let kUsageURL = "https://api.anthropic.com/api/oauth/usage"

enum CredSource {
    case keychain(account: String)
    case file(URL)
}

struct CredStore {
    var obj: [String: Any]   // 저장소 전체 JSON (mcpOAuth 등 다른 필드 보존)
    var source: CredSource

    var oauth: [String: Any]? { obj["claudeAiOauth"] as? [String: Any] }
    var accessToken: String? { oauth?["accessToken"] as? String }
    var refreshToken: String? { oauth?["refreshToken"] as? String }
    var expiresAt: Double? { oauth?["expiresAt"] as? Double } // ms epoch
}

func keychainRead(account: String) -> Data? {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kService,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var ref: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess else { return nil }
    return ref as? Data
}

func loadStore() -> Result<CredStore, String> {
    // 같은 서비스에 계정별 항목이 있을 수 있으므로 계정 목록을 먼저 얻는다.
    let listQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kService,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var listRef: CFTypeRef?
    let status = SecItemCopyMatching(listQuery as CFDictionary, &listRef)
    var accounts: [String] = []
    if status == errSecSuccess {
        let attrsList = (listRef as? [[String: Any]]) ?? (listRef as? [String: Any]).map { [$0] } ?? []
        accounts = attrsList.compactMap { $0[kSecAttrAccount as String] as? String }
    }
    var best: CredStore?
    for account in accounts {
        guard let d = keychainRead(account: account),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        let store = CredStore(obj: o, source: .keychain(account: account))
        if store.accessToken != nil { best = store; break }
        if best == nil { best = store }
    }
    if best?.accessToken == nil {
        // 파일 폴백
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let d = try? Data(contentsOf: path),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let store = CredStore(obj: o, source: .file(path))
            if store.accessToken != nil { best = store }
        }
    }
    guard let store = best, store.accessToken != nil else {
        if status == errSecUserCanceled || status == errSecAuthFailed {
            return .failure("키체인 접근 거부됨 — 앱 재실행 후 '항상 허용'을 눌러주세요")
        }
        return .failure("계정 토큰 없음 — 터미널에서 claude auth login 한 번 실행 필요")
    }
    return .success(store)
}

func saveStore(_ store: CredStore) {
    guard let data = try? JSONSerialization.data(withJSONObject: store.obj) else { return }
    switch store.source {
    case .keychain(let account):
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kService,
            kSecAttrAccount as String: account,
        ]
        SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
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
        saveStore(newStore) // 갱신 토큰이 회전되므로 반드시 저장소에 되써야 CLI 로그인도 유지됨
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✳ …"
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
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
                    let five = windows.first { $0.key == "five_hour" } ?? windows[0]
                    self.statusItem.button?.title = "✳ \(Int(five.utilization.rounded()))%"
                case .failure(let msg):
                    self.lastError = msg
                    self.statusItem.button?.title = "✳ –"
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
        let refreshItem = NSMenuItem(title: "지금 갱신", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc func refreshNow() { refresh() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
