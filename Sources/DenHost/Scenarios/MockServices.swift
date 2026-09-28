// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import Foundation
import Network

/// A local fake Slack + GitHub for development, tests and `--scenario` snapshots: realistic
/// responses in the shapes the real sites return, on 127.0.0.1, so the whole pipeline
/// (session → net → AI → briefing) runs without real accounts.
///
/// - `GET /slack/signin`: a page that "signs you in" the way slack.com leaves a browser: an
///   HttpOnly `d` cookie plus `localConfig_v2` in localStorage with two workspaces and their
///   `xoxc-` tokens.
/// - `GET /login`: github.com's signed-in cookies (`logged_in=yes`, `dotcom_user`, HttpOnly
///   `user_session`).
/// - `POST /api/<method>`: Slack Web API methods den uses. Requests need the workspace's token in
///   the form body **and** the `d` cookie, like the real web client; otherwise `invalid_auth`.
/// - `GET /search?q=…&type=…`: github.com's search JSON (`payload.blackbirdSearchRoute`), shaped
///   like a real response captured on 2026-09-27; `logged_in: false` without `user_session`.
public final class MockServices: @unchecked Sendable {
  public private(set) var port: UInt16 = 0
  public var base: String { "http://127.0.0.1:\(port)" }
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "den.mock-services")
  private let lock = NSLock()
  private var _log: [String] = []
  /// Every request as "METHOD /path", in order.
  public var log: [String] { lock.withLock { _log } }
  public let now: Date
  public static let dCookie = "xoxd-mock-session"
  public static let tokens = ["T01ACME": "xoxc-mock-acme", "T02DEN": "xoxc-mock-den"]
  public static let me = "U01ME"
  /// Static files by path (the mini player scenario's test page and video), with byte ranges:
  /// WebKit's media loader asks for `Range: bytes=…` and needs 206 answers.
  public var files: [String: (type: String, data: Data)] {
    get { lock.withLock { _files } }
    set { lock.withLock { _files = newValue } }
  }
  private var _files: [String: (type: String, data: Data)] = [:]

  public init(now: Date = Date()) { self.now = now }

  private var _pages: [String: (String, Data)] = [:]
  /// Serves `body` at `path` (extension tests and scenarios: test pages, a fake ad script).
  public func page(_ path: String, _ body: String, type: String = "text/html; charset=utf-8") {
    lock.withLock { _pages[path] = (type, Data(body.utf8)) }
  }

  /// Starts listening on a free port; returns once the port is known.
  public func start() throws {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    let l = try NWListener(using: params)
    let ready = DispatchSemaphore(value: 0)
    l.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
      if case .failed = state { ready.signal() }
    }
    l.newConnectionHandler = { [weak self] c in self?.serve(c) }
    l.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    port = l.port?.rawValue ?? 0
    listener = l
  }

  public func stop() { listener?.cancel() }

  // MARK: HTTP

  struct Request {
    var method = "", path = "", query: [String: String] = [:], headers: [String: String] = [:], body = Data()
    var form: [String: String] { MockServices.parseQuery(String(decoding: body, as: UTF8.self)) }
    var cookies: [String: String] {
      var out: [String: String] = [:]
      for part in (headers["cookie"] ?? "").split(separator: ";") {
        let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { out[kv[0]] = kv[1] }
      }
      return out
    }
  }

  static func parseQuery(_ s: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in s.split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
      if kv.count == 2 { out[kv[0]] = kv[1] } else if kv.count == 1 { out[kv[0]] = "" }
    }
    return out
  }

  func serve(_ c: NWConnection) {
    c.start(queue: queue)
    var buffer = Data()
    func read() {
      c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
        guard let self else { return c.cancel() }
        if let data { buffer.append(data) }
        if let req = Self.parse(buffer) {
          let (status, headers, body) = self.respond(req)
          let reason = [200: "OK", 206: "Partial Content", 302: "Found", 401: "Unauthorized"][status] ?? "Error"
          var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
          for (k, v) in headers { head += "\(k): \(v)\r\n" }
          c.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in c.cancel() })
          return
        }
        if done || error != nil { c.cancel() } else { read() }
      }
    }
    read()
  }

  static func parse(_ data: Data) -> Request? {
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    guard let first = head.first else { return nil }
    let parts = first.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    var r = Request()
    r.method = String(parts[0])
    let target = String(parts[1])
    if let q = target.firstIndex(of: "?") {
      r.path = String(target[..<q])
      r.query = parseQuery(String(target[target.index(after: q)...]))
    } else {
      r.path = target
    }
    for line in head.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      r.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let length = Int(r.headers["content-length"] ?? "0") ?? 0
    let bodyStart = end.upperBound
    guard data.count - bodyStart >= length else { return nil }
    r.body = data[bodyStart..<(bodyStart + length)]
    return r
  }

  // thin-host: feature-specific, migrate to plugin (mock pages for the passwords plugin)
  /// A mock sign-in (or sign-up) form for the password vault. Submitting it goes nowhere.
  static func vaultPage(signup: Bool) -> String {
    let fields = signup
      ? "<input id=u type=email placeholder='Email' autocomplete=email><input id=p1 type=password placeholder='Password' autocomplete=new-password><input id=p2 type=password placeholder='Confirm password' autocomplete=new-password>"
      : "<input id=u placeholder='Email or username' autocomplete=username><input id=p type=password placeholder='Password' autocomplete=current-password>"
    return """
      <!doctype html><title>\(signup ? "Create account" : "Sign in") – Mock</title>
      <style>body{font:15px -apple-system;background:#f4f5f7;margin:0}form{width:340px;margin:90px auto;background:#fff;padding:28px;border-radius:14px;box-shadow:0 2px 12px #0002}
      h2{margin:0 0 18px}input{display:block;width:100%;box-sizing:border-box;margin:0 0 12px;padding:11px;border:1px solid #ccd;border-radius:8px;font:inherit}
      button{width:100%;padding:11px;border:0;border-radius:8px;background:#3139fb;color:#fff;font:600 15px -apple-system}</style>
      <form id=f action="javascript:void 0"><h2>\(signup ? "Create your account" : "Sign in to Mock")</h2>\(fields)<button id=go type=submit>\(signup ? "Create account" : "Sign in")</button></form>
      """
  }

  /// A static file, or the part `Range: bytes=a-b` asks for.
  func file(_ type: String, _ data: Data, range: String?) -> (Int, [(String, String)], Data) {
    var headers = [("Content-Type", type), ("Accept-Ranges", "bytes")]
    guard let range, range.hasPrefix("bytes="), !data.isEmpty else { return (200, headers, data) }
    let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
    let start = min(parts.first.flatMap { $0 } ?? 0, data.count - 1)
    let end = min(parts.count > 1 ? (parts[1] ?? data.count - 1) : data.count - 1, data.count - 1)
    guard start <= end else { return (416, headers, Data()) }
    headers.append(("Content-Range", "bytes \(start)-\(end)/\(data.count)"))
    return (206, headers, data.subdata(in: start..<(end + 1)))
  }

  func json(_ obj: Any) -> (Int, [(String, String)], Data) {
    (200, [("Content-Type", "application/json; charset=utf-8")], (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
  }

  func respond(_ r: Request) -> (Int, [(String, String)], Data) {
    lock.withLock { _log.append("\(r.method) \(r.path)") }
    if r.method == "GET", let f = files[r.path] { return file(f.type, f.data, range: r.headers["range"]) }
    if let (type, body) = lock.withLock({ _pages[r.path] }) { return (200, [("Content-Type", type)], body) }
    if let answer = routeGoogleNotion(r) { return answer }
    switch (r.method, r.path) {
    case ("GET", "/slack/signin"):
      return (200, [("Content-Type", "text/html; charset=utf-8"), ("Set-Cookie", "d=\(Self.dCookie); Path=/; HttpOnly; SameSite=Lax")], Data(slackSignedInPage.utf8))
    case ("GET", "/login"):
      return (200, [("Content-Type", "text/html; charset=utf-8"),
                    ("Set-Cookie", "logged_in=yes; Path=/"), ("Set-Cookie", "dotcom_user=octo-den; Path=/"),
                    ("Set-Cookie", "user_session=mock-user-session; Path=/; HttpOnly")],
              Data("<!doctype html><title>GitHub</title><body style='font:15px -apple-system;padding:40px'><h2>Signed in as octo-den</h2></body>".utf8))
    case ("GET", "/vault/login"), ("GET", "/vault/signup"):
      return (200, [("Content-Type", "text/html; charset=utf-8")], Data(Self.vaultPage(signup: r.path.hasSuffix("signup")).utf8))
    case ("GET", "/search"): return githubSearch(r)
    case ("GET", "/redirect-out"): return (302, [("Location", "http://example.invalid/")], Data())
    case ("GET", "/big"): return (200, [("Content-Type", "text/plain")], Data(repeating: 65, count: 300_000))
    case ("GET", "/basic-auth"):
      // HTTP Basic sign-in (user "den", password "secret") for the web page sign-in dialog.
      if r.headers["authorization"] == "Basic " + Data("den:secret".utf8).base64EncodedString() {
        return (200, [("Content-Type", "text/html; charset=utf-8")], Data("<!doctype html><title>Signed in</title><body>Welcome, den</body>".utf8))
      }
      return (401, [("Content-Type", "text/html; charset=utf-8"), ("WWW-Authenticate", "Basic realm=\"den test\"")],
              Data("<!doctype html><title>Unauthorized</title><body>401</body>".utf8))
    default:
      if r.path.hasPrefix("/api/") { return slackAPI(String(r.path.dropFirst(5)), r) }
      return (404, [("Content-Type", "text/plain")], Data("not found".utf8))
    }
  }

  // MARK: Slack

  var slackConfig: String {
    let teams: [String: Any] = [
      "T01ACME": ["id": "T01ACME", "name": "Acme Inc", "url": base + "/", "domain": "acme", "user_id": Self.me, "token": Self.tokens["T01ACME"]!,
                  "icon": ["image_68": ""]],
      "T02DEN": ["id": "T02DEN", "name": "den OSS", "url": base + "/", "domain": "den-oss", "user_id": Self.me, "token": Self.tokens["T02DEN"]!,
                 "icon": ["image_68": ""]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: ["teams": teams, "lastActiveTeamId": "T01ACME"])
    return String(decoding: data, as: UTF8.self)
  }

  var slackSignedInPage: String {
    """
    <!doctype html><title>Slack</title>
    <script>localStorage.setItem('localConfig_v2', \(String(reflecting: slackConfig)));</script>
    <body style="font:15px -apple-system;padding:40px"><h2>You're signed in to Acme Inc and den OSS</h2><p>You can close this tab.</p></body>
    """
  }

  func ts(_ minutesAgo: Double) -> String { String(format: "%.6f", now.timeIntervalSince1970 - minutesAgo * 60) }

  func slackAPI(_ method: String, _ r: Request) -> (Int, [(String, String)], Data) {
    let token = r.form["token"] ?? ""
    guard let team = Self.tokens.first(where: { $0.value == token })?.key, r.cookies["d"] == Self.dCookie else {
      return json(["ok": false, "error": "invalid_auth"])
    }
    let acme = team == "T01ACME"
    switch method {
    case "client.counts":
      return json(["ok": true,
                   "ims": acme ? [["id": "D01MAYA", "has_unreads": true, "mention_count": 2, "last_read": ts(300)],
                                  ["id": "D02OMAR", "has_unreads": false, "mention_count": 0, "last_read": ts(10)]]
                     : [["id": "D03LEE", "has_unreads": true, "mention_count": 1, "last_read": ts(900)]],
                   "mpims": [], "channels": [["id": "C01GEN", "has_unreads": true, "mention_count": 1]],
                   "threads": ["has_unreads": true, "mention_count": 1]])
    case "conversations.history":
      let msgs: [[String: Any]]
      switch r.form["channel"] ?? "" {
      case "D01MAYA": msgs = [["type": "message", "user": "U02MAYA", "text": "Can you look at the Q3 launch deck before the 2pm review? Slides 4–7 need your numbers.", "ts": ts(42)],
                              ["type": "message", "user": "U02MAYA", "text": "morning!", "ts": ts(55)], ["type": "message", "user": Self.me, "text": "hey", "ts": ts(400)]]
      case "D03LEE": msgs = [["type": "message", "user": "U05LEE", "text": "Is the plugin ABI frozen for 0.2, or can I still rename cordis_host.call?", "ts": ts(130)]]
      default: msgs = []
      }
      return json(["ok": true, "messages": msgs, "has_more": false])
    case "search.messages":
      guard (r.form["query"] ?? "").contains("<@\(Self.me)>") else { return json(["ok": true, "messages": ["matches": [], "total": 0]]) }
      let matches: [[String: Any]] = acme ? [
        ["iid": "1", "ts": ts(25), "user": "U03JON", "username": "jon", "text": "<@\(Self.me)> the checkout fix is on staging, can you confirm it works on Safari?",
         "channel": ["id": "C02ENG", "name": "eng-web", "is_im": false], "permalink": base + "/archives/C02ENG/p1?thread_ts=\(ts(90))&cid=C02ENG"],
        ["iid": "2", "ts": ts(70), "user": "U04ANA", "username": "ana", "text": "Launch checklist is up, <@\(Self.me)> owns the release notes :memo: <https://docs.acme.test/launch|Launch doc>",
         "channel": ["id": "C01GEN", "name": "launch", "is_im": false], "permalink": base + "/archives/C01GEN/p2"],
        ["iid": "3", "ts": ts(200), "user": "U03JON", "username": "jon", "text": "<@\(Self.me)> thanks for the review!",
         "channel": ["id": "C02ENG", "name": "eng-web", "is_im": false], "permalink": base + "/archives/C02ENG/p3?thread_ts=\(ts(260))&cid=C02ENG"],
      ] : []
      return json(["ok": true, "query": r.form["query"] ?? "", "messages": ["total": matches.count, "matches": matches]])
    case "conversations.replies":
      // The first thread has no answer from you yet; the second one does.
      let answered = (r.form["ts"] ?? "") == ts(260)
      var msgs: [[String: Any]] = [["user": "U03JON", "text": "mention", "ts": r.form["oldest"] ?? ts(25)]]
      if answered { msgs.append(["user": Self.me, "text": "anytime", "ts": ts(190)]) }
      return json(["ok": true, "messages": msgs])
    case "users.info":
      let names = ["U02MAYA": "Maya Chen", "U05LEE": "Lee Park", "U03JON": "Jon", "U04ANA": "Ana"]
      let id = r.form["user"] ?? ""
      return json(["ok": true, "user": ["id": id, "name": id.lowercased(), "real_name": names[id] ?? id, "profile": ["display_name": names[id] ?? "", "real_name": names[id] ?? id]]])
    default:
      return json(["ok": false, "error": "unknown_method"])
    }
  }

  // MARK: GitHub

  func iso(_ minutesAgo: Double) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: now.addingTimeInterval(-minutesAgo * 60))
  }

  func pr(_ owner: String, _ repo: String, _ n: Int, _ title: String, _ author: String, _ minutesAgo: Double, pr: Bool = true) -> [String: Any] {
    ["author_name": author, "author_avatar_url": "", "id": String(4_600_000_000 + n),
     "issue": ["issue": ["pull_request_id": pr ? (4_600_000_000 + n) as Any : NSNull()]],
     "repo": ["repository": ["id": 1000 + n, "name": repo, "owner_id": 42, "owner_login": owner, "has_issues": true]],
     "labels": [], "num_comments": 2, "number": n, "state": "open", "state_reason": NSNull(),
     "hl_title": title, "hl_text": "", "created": iso(minutesAgo), "reviewable_state": pr ? "ready" : NSNull(), "merged": pr ? false : NSNull()]
  }

  func githubSearch(_ r: Request) -> (Int, [(String, String)], Data) {
    let q = r.query["q"] ?? ""
    let loggedIn = r.cookies["user_session"] != nil
    var results: [[String: Any]] = []
    if loggedIn {
      if q.contains("review-requested:@me") {
        results = [pr("acme", "web", 1482, "Checkout: retry card &lt;iframe&gt; load on Safari", "jonw", 50),
                   pr("abhishakenp", "den", 214, "Plugins: <em>session</em> service for signed-in sites", "leepark", 180)]
      } else if q.contains("status:failure") {
        results = [pr("abhishakenp", "den", 209, "Briefing: rank feed by kind, recency and affinity", "octo-den", 300)]
      } else if q.contains("assignee:@me") {
        results = [pr("acme", "api", 77, "Rate limiter drops requests at exactly 100/s", "ana-g", 1500, pr: false)]
      } else if q.contains("mentions:@me") {
        results = [pr("acme", "web", 1482, "Checkout: retry card &lt;iframe&gt; load on Safari", "jonw", 50),
                   pr("acme", "design", 31, "Icon set v3: which glyph for &quot;Archive&quot;?", "maya-c", 700, pr: false)]
      }
    }
    let route: [String: Any] = ["header_redesign_enabled": false, "results": results, "type": r.query["type"] ?? "issues", "page": 1,
                                "page_count": results.isEmpty ? 0 : 1, "elapsed_millis": 7, "errors": [], "result_count": results.count,
                                "facets": [], "protected_org_logins": [], "topics": NSNull(), "query_id": "", "logged_in": loggedIn]
    return json(["meta": ["title": "Search results"], "payload": ["blackbirdSearchRoute": route]])
  }
}
#endif
