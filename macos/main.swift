import Cocoa
import CryptoKit
import Network

extension String: @retroactive Error {}
extension Int: @retroactive Error {}

// MARK: - 자격증명
//
// 토큰 출처 우선순위:
//  1) ~/.claude/cubr-token — 사용자가 직접 넣어둔 장기 토큰(선택). 갱신 없음.
//  2) 앱 전용 로그인 — 메뉴 'Claude 로그인'으로 브라우저 승인 1회. 앱이 자기 토큰만 갱신한다.
//  3) Claude Code 키체인 항목 — 읽기 전용. 절대 갱신하거나 되쓰지 않는다.
//
// 왜 앱 전용 로그인인가: Claude Code와 같은 토큰을 같이 갱신하면 갱신 토큰이 회전될 때
// 한쪽이 든 토큰이 무효가 되고, 실행 중인 Claude Code가 실패하면서 로그인 정보를 지운다.
// 그러면 Claude Code도 로그아웃되고 앱도 멈춘다. 별도 로그인은 서로 건드릴 일이 없다.
//
// 키체인 접근은 전부 Apple 정식 도구 /usr/bin/security 를 거친다 — 키체인이 기본 신뢰하는
// 도구라 허용 창이 뜨지 않고, 앱을 다시 빌드해도 영향이 없다.


let kService = "Claude Code-credentials"   // Claude Code 항목 (읽기 전용)
let kAuthService = "ClaudeUsageBar-auth"     // 앱 전용 로그인 저장 항목
let kClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code 공개 OAuth 클라이언트
let kAuthorizeURL = "https://claude.com/cai/oauth/authorize"
let kTokenURL = "https://platform.claude.com/v1/oauth/token"
let kUsageURL = "https://api.anthropic.com/api/oauth/usage"
let kScopes = ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload"]

enum CredSource {
    case tokenFile   // ~/.claude/cubr-token (갱신 불가)
    case own         // 앱 전용 로그인 (앱이 갱신)
    case cli         // Claude Code 항목 (읽기 전용 — 만료되면 Claude Code가 갱신할 때까지 대기)
}

struct CredStore {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?   // ms epoch
    var source: CredSource

    var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return exp / 1000 < Date().timeIntervalSince1970 + 60
    }
}

/// /usr/bin/security 실행. 응답이 없는 경우를 대비해 시간 제한을 둔다.
func runSecurity(_ args: [String], timeout: TimeInterval = 30) -> (out: String, err: String, code: Int32, timedOut: Bool) {
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

// MARK: 앱 전용 로그인 저장소

func readOwnAuth() -> CredStore? {
    let r = runSecurity(["find-generic-password", "-s", kAuthService, "-a", "default", "-w"])
    guard r.code == 0,
          let d = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let access = o["accessToken"] as? String, !access.isEmpty else { return nil }
    return CredStore(accessToken: access,
                     refreshToken: o["refreshToken"] as? String,
                     expiresAt: o["expiresAt"] as? Double,
                     source: .own)
}

func writeOwnAuth(_ s: CredStore) {
    var o: [String: Any] = ["accessToken": s.accessToken]
    if let r = s.refreshToken { o["refreshToken"] = r }
    if let e = s.expiresAt { o["expiresAt"] = e }
    guard let d = try? JSONSerialization.data(withJSONObject: o),
          let json = String(data: d, encoding: .utf8) else { return }
    _ = runSecurity(["add-generic-password", "-U", "-s", kAuthService, "-a", "default",
                     "-l", "ClaudeUsageBar 로그인", "-w", json])
}

func deleteOwnAuth() {
    _ = runSecurity(["delete-generic-password", "-s", kAuthService, "-a", "default"])
}

/// 토큰 응답(JSON)을 저장소 형태로
func storeFromTokenResponse(_ o: [String: Any], previousRefresh: String?) -> CredStore? {
    guard let access = o["access_token"] as? String, !access.isEmpty else { return nil }
    var exp: Double? = nil
    if let sec = o["expires_in"] as? Double { exp = (Date().timeIntervalSince1970 + sec) * 1000 }
    return CredStore(accessToken: access,
                     refreshToken: (o["refresh_token"] as? String) ?? previousRefresh,
                     expiresAt: exp, source: .own)
}

// MARK: Claude Code 항목 (읽기 전용)

func readCLIItem() -> CredStore? {
    let meta = runSecurity(["find-generic-password", "-s", kService], timeout: 15)
    guard meta.code == 0 else { return nil }
    var args = ["find-generic-password", "-s", kService]
    if let r = meta.out.range(of: #""acct"<blob>="[^"]*""#, options: .regularExpression) {
        let line = String(meta.out[r])
        if let q1 = line.range(of: "=\""), let q2 = line.range(of: "\"", options: .backwards), q1.upperBound < q2.lowerBound {
            args += ["-a", String(line[q1.upperBound..<q2.lowerBound])]
        }
    }
    args.append("-w")
    let r = runSecurity(args)
    guard r.code == 0,
          let d = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let oauth = o["claudeAiOauth"] as? [String: Any],
          let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
    let exp = oauth["expiresAt"] as? Double
    return CredStore(accessToken: access, refreshToken: nil,
                     expiresAt: (exp ?? 0) > 0 ? exp : nil, source: .cli)
}

// MARK: 토큰 선택

var cachedStore: CredStore?
let needLoginMessage = "로그인 필요 — 메뉴에서 'Claude 로그인'을 눌러 주세요"

func loadStore() -> CredStore? {
    if let c = cachedStore, !(c.source == .cli && c.isExpired) { return c }

    // 1) 수동 등록 토큰 파일
    let tokenPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/cubr-token")
    if let raw = try? String(contentsOf: tokenPath, encoding: .utf8),
       let r = raw.range(of: #"sk-ant-[A-Za-z0-9_\-]{20,}"#, options: .regularExpression) {
        cachedStore = CredStore(accessToken: String(raw[r]), refreshToken: nil, expiresAt: nil, source: .tokenFile)
        return cachedStore
    }
    // 2) 앱 전용 로그인
    if let own = readOwnAuth() { cachedStore = own; return own }
    // 3) Claude Code 항목 (읽기 전용, 유효할 때만)
    if let cli = readCLIItem(), !cli.isExpired { cachedStore = cli; return cli }
    cachedStore = nil
    return nil
}

// MARK: 토큰 갱신 (앱 전용 로그인만)

func refreshOwn(_ store: CredStore, completion: @escaping (Result<CredStore, String>) -> Void) {
    guard let refresh = store.refreshToken, !refresh.isEmpty else {
        completion(.failure(needLoginMessage)); return
    }
    postToken([
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "client_id": kClientID,
        "scope": kScopes.joined(separator: " "),
    ]) { result in
        switch result {
        case .failure(let code):
            cachedStore = nil
            if code == 400 || code == 401 {
                deleteOwnAuth() // 갱신 토큰이 무효 — 다시 로그인해야 함
                completion(.failure(needLoginMessage))
            } else {
                completion(.failure("토큰 갱신 실패(\(code)) — 다음 갱신 때 다시 시도"))
            }
        case .success(let o):
            guard let s = storeFromTokenResponse(o, previousRefresh: refresh) else {
                completion(.failure("토큰 갱신 응답을 해석할 수 없음")); return
            }
            writeOwnAuth(s)
            cachedStore = s
            completion(.success(s))
        }
    }
}

func postToken(_ body: [String: String], completion: @escaping (Result<[String: Any], Int>) -> Void) {
    var req = URLRequest(url: URL(string: kTokenURL)!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    req.timeoutInterval = 30
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let data = data,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(.failure(code)); return
        }
        completion(.success(o))
    }.resume()
}

func withFreshToken(completion: @escaping (Result<String, String>) -> Void) {
    guard let store = loadStore() else { completion(.failure(needLoginMessage)); return }
    if store.source == .own && store.isExpired {
        refreshOwn(store) { r in completion(r.map { $0.accessToken }) }
    } else {
        completion(.success(store.accessToken))
    }
}

/// 구버전이 만들었던 앱 소유 키체인 항목 정리
func removeLegacyOwnItem() {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ClaudeUsageBar",
    ]
    SecItemDelete(q as CFDictionary)
}

// MARK: - 앱 전용 로그인 (브라우저 승인 → localhost 콜백 → 토큰 교환)

func base64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func randomURLSafe(_ bytes: Int) -> String {
    var b = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
    return base64url(Data(b))
}

final class OAuthLogin {
    private var listener: NWListener?
    private var verifier = ""
    private var state = ""
    private var port: UInt16 = 0
    private var done = false
    private var completion: ((Result<Void, String>) -> Void)?

    func start(completion: @escaping (Result<Void, String>) -> Void) {
        self.completion = completion
        verifier = randomURLSafe(32)
        state = randomURLSafe(32)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let l = try? NWListener(using: params) else {
            finish(.failure("로그인 준비 실패 (포트를 열 수 없음)")); return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                self.port = l.port?.rawValue ?? 0
                self.openBrowser()
            case .failed(let e):
                self.finish(.failure("로그인 준비 실패: \(e.localizedDescription)"))
            default: break
            }
        }
        l.start(queue: .main)
        // 5분 안에 승인이 안 오면 정리
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.finish(.failure("로그인 시간 초과 — 다시 시도해 주세요"))
        }
    }

    private func openBrowser() {
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var c = URLComponents(string: kAuthorizeURL)!
        c.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: kClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: "http://localhost:\(port)/callback"),
            URLQueryItem(name: "scope", value: kScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self else { conn.cancel(); return }
            let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = req.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[1].hasPrefix("/callback"),
                  let comps = URLComponents(string: "http://localhost" + parts[1]) else {
                self.respond(conn, status: "404 Not Found", body: "Not found"); return
            }
            let items = comps.queryItems ?? []
            let code = items.first { $0.name == "code" }?.value
            let st = items.first { $0.name == "state" }?.value
            guard let code = code, st == self.state else {
                self.respond(conn, status: "400 Bad Request", body: self.page("로그인 실패", "승인 정보가 올바르지 않습니다. 메뉴에서 다시 시도해 주세요."))
                self.finish(.failure("로그인 실패 — 승인 정보 불일치")); return
            }
            self.respond(conn, status: "200 OK", body: self.page("로그인 완료", "ClaudeUsageBar 로그인이 끝났습니다. 이 창은 닫아도 됩니다."))
            self.exchange(code: code)
        }
    }

    private func exchange(code: String) {
        postToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": "http://localhost:\(port)/callback",
            "client_id": kClientID,
            "code_verifier": verifier,
            "state": state,
        ]) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let c): self?.finish(.failure("토큰 교환 실패(\(c)) — 다시 시도해 주세요"))
                case .success(let o):
                    guard let s = storeFromTokenResponse(o, previousRefresh: nil) else {
                        self?.finish(.failure("토큰 응답을 해석할 수 없음")); return
                    }
                    writeOwnAuth(s)
                    cachedStore = s
                    self?.finish(.success(()))
                }
            }
        }
    }

    private func page(_ title: String, _ msg: String) -> String {
        "<!doctype html><meta charset=utf-8><title>\(title)</title>" +
        "<body style='font-family:-apple-system,sans-serif;text-align:center;padding-top:15vh'>" +
        "<h2>✳ \(title)</h2><p>\(msg)</p></body>"
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let b = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(b.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + b, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func finish(_ r: Result<Void, String>) {
        guard !done else { return }
        done = true
        listener?.cancel()
        listener = nil
        completion?(r)
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
                        // 토큰이 무효 — 앱 전용 로그인이면 다음 갱신 때 새로 발급, 아니면 다시 읽음
                        if var c = cachedStore, c.source == .own {
                            c.expiresAt = 0; cachedStore = c
                        } else {
                            cachedStore = nil
                        }
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

// MARK: - CLI 검증 모드 (--once, --login)

if CommandLine.arguments.contains("--login") {
    let login = OAuthLogin()
    login.start { r in
        switch r {
        case .success: print("로그인 성공")
        case .failure(let m): print("ERROR: \(m)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

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
                    if self.lastError == needLoginMessage {
                        self.setBarText("✳로그인") // 숫자 대신 로그인 필요를 바로 보이게
                    } else if self.lastWindows.isEmpty {
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
        let loggedIn = (cachedStore?.source == .own)
        let loginTitle = loginInProgress ? "로그인 진행 중… (브라우저에서 승인)"
            : (loggedIn ? "Claude 다시 로그인" : "Claude 로그인 (브라우저)")
        let loginItem = NSMenuItem(title: loginTitle, action: loginInProgress ? nil : #selector(startLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        let refreshItem = NSMenuItem(title: "지금 갱신", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    var login: OAuthLogin?
    var loginInProgress = false

    @objc func startLogin() {
        loginInProgress = true
        rebuildMenu()
        let l = OAuthLogin()
        login = l
        l.start { [weak self] r in
            guard let self = self else { return }
            self.loginInProgress = false
            self.login = nil
            if case .failure(let m) = r { self.lastError = m }
            self.rebuildMenu()
            self.refresh()
        }
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
