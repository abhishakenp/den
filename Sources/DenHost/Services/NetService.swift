import CordisValue
import Foundation
import WebKit

/// `net` service: HTTP for plugins (they have no Foundation or sockets).
///
///   fetch {plugin, url, method? (GET), headers? {name: value}, body? (string), as? json|text (text),
///          session? (false), profile? (default), timeoutMs? (20000, max 60000), maxBytes? (5 MB, max 20 MB), id?}
///     -> {id}; later `net.result {id, ok, status, headers, json | text, error?}`
///
/// - `plugin` needs a `net:<domain>` or `session:<domain>` permission covering the URL's host.
/// - `session: true` (needs `session:<domain>`) attaches the profile's cookies for that URL, copied
///   from its `WKHTTPCookieStore`, the way the page itself would send them. Responses never write
///   cookies back and nothing is cached on disk (ephemeral URLSession).
/// - Redirects are only followed to hosts the plugin may fetch; otherwise the 3xx is returned.
/// - Bodies over `maxBytes` fail with `error: "too large"`. `ok` is true for any HTTP response
///   (check `status`); transport failures have `ok: false` and `error`.
/// - Response header names are lowercased; `set-cookie` is dropped.
/// - `stopAfter: "</head>"` (case-insensitive marker) streams the body and stops reading once the
///   marker has arrived or `maxBytes` is reached: `{ok: true, status, text, truncated}` instead of
///   "too large". Pair with `headers: {Range: "bytes=0-65535"}` where servers honor it. Link
///   previews use it to read only a page's `<head>`.
@MainActor
public final class NetService: HostService {
  public let name = "net"
  let host: ServiceHost
  let webviews: WebViewsService
  let permissions: Permissions
  private var nextId = 1
  private var tasks: [String: Task<Void, Never>] = [:]
  public var requestCount = 0
  private lazy var urlSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: c)
  }()

  public init(host: ServiceHost, webviews: WebViewsService, permissions: Permissions) {
    self.host = host
    self.webviews = webviews
    self.permissions = permissions
  }

  public var inFlight: Int { tasks.count }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "fetch": return fetch(args)
    case "cancel":
      tasks.removeValue(forKey: args.str("id"))?.cancel()
      return .ok
    default: return .error("net: unknown method '\(method)'")
    }
  }

  func fetch(_ args: Value) -> Value {
    let plugin = args.str("plugin")
    guard let url = URL(string: args.str("url")), let h = url.host, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      return .error("net: url must be http(s)")
    }
    let useSession = args.flag("session")
    if useSession {
      guard permissions.allowsSession(plugin, host: h) else { return .error("net: '\(plugin)' has no session:\(h) permission") }
    } else {
      guard permissions.allowsNet(plugin, host: h) else { return .error("net: '\(plugin)' has no permission for \(h)") }
    }
    var id = args.str("id")
    if id.isEmpty { id = "net-\(nextId)"; nextId += 1 }
    var req = URLRequest(url: url)
    req.httpMethod = args.str("method", "GET").uppercased()
    req.timeoutInterval = min(60, max(1, args.num("timeoutMs", 20_000) / 1000))
    for (k, v) in args["headers"].object ?? [] {
      if let s = v.string, k.lowercased() != "cookie" { req.setValue(s, forHTTPHeaderField: k) }
    }
    if let b = args["body"].string { req.httpBody = Data(b.utf8) }
    let maxBytes = Int(min(Double(20 << 20), max(1024, args.num("maxBytes", Double(5 << 20)))))
    let asJSON = args.str("as") == "json"
    let stopAfter = args["stopAfter"].string.flatMap { $0.isEmpty ? nil : $0 }
    let profile = args.str("profile", "default")
    // Redirect checks run off the main thread: use a snapshot of the grants.
    let grants = permissions.list(plugin)
    let allowed: @Sendable (String) -> Bool = { newHost in
      grants.contains { p in
        guard let (k, d) = Permissions.parse(p) else { return false }
        return (!useSession || k == "session") && Permissions.covers(domain: d, host: newHost)
      }
    }
    requestCount += 1
    tasks[id] = Task { @MainActor [weak self] in
      guard let self else { return }
      var request = req
      if useSession {
        let cookies = await Self.cookies(in: self.webviews.store(for: profile), for: url)
        if !cookies.isEmpty { request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
      }
      let result = await Self.run(self.urlSession, request, maxBytes: maxBytes, asJSON: asJSON, stopAfter: stopAfter, allowed: allowed)
      guard self.tasks.removeValue(forKey: id) != nil else { return }  // cancelled
      self.host.emit("net.result", result.with("id", .string(id)))
    }
    return ["id": .string(id)]
  }

  /// Cookies the page itself would send to `url`: domain, path, secure and expiry rules.
  static func cookies(in store: WKWebsiteDataStore, for url: URL) async -> [HTTPCookie] {
    let all = await store.httpCookieStore.allCookies()
    let host = url.host?.lowercased() ?? ""
    let path = url.path.isEmpty ? "/" : url.path
    let secure = url.scheme?.lowercased() == "https"
    let now = Date()
    return all.filter { c in
      let d = c.domain.lowercased()
      let domainOK = d.hasPrefix(".") ? (host == String(d.dropFirst()) || host.hasSuffix(d)) : host == d
      let pathOK = path.hasPrefix(c.path) || c.path == "/"
      let expiryOK = c.expiresDate.map { $0 > now } ?? true
      return domainOK && pathOK && (!c.isSecure || secure) && expiryOK
    }
  }

  /// True when `marker` (lowercase ASCII) ends at `data`'s last byte, compared case-insensitively.
  nonisolated static func endsWith(_ data: Data, _ marker: [UInt8]) -> Bool {
    guard !marker.isEmpty, data.count >= marker.count else { return false }
    var i = data.count - marker.count
    for m in marker {
      var c = data[data.startIndex + i]
      if c >= 65 && c <= 90 { c += 32 }
      if c != m { return false }
      i += 1
    }
    return true
  }

  nonisolated static func run(_ session: URLSession, _ req: URLRequest, maxBytes: Int, asJSON: Bool, stopAfter: String? = nil,
                              allowed: @escaping @Sendable (String) -> Bool) async -> Value {
    do {
      let (bytes, response) = try await session.bytes(for: req, delegate: RedirectTaskGuard(allowed: allowed))
      guard let http = response as? HTTPURLResponse else { return ["ok": false, "error": "net: not an HTTP response"] }
      let marker = stopAfter.map { Array($0.lowercased().utf8) }
      if marker == nil, http.expectedContentLength > Int64(maxBytes) { return ["ok": false, "status": .int(Int64(http.statusCode)), "error": "too large"] }
      var data = Data()
      data.reserveCapacity(min(maxBytes, max(0, Int(http.expectedContentLength))))
      var truncated = false
      for try await b in bytes {
        data.append(b)
        if let marker {
          if endsWith(data, marker) { truncated = true; break }
          if data.count >= maxBytes { truncated = true; break }
        } else if data.count > maxBytes {
          return ["ok": false, "status": .int(Int64(http.statusCode)), "error": "too large"]
        }
      }
      if truncated { bytes.task.cancel() }
      var headers: [(String, Value)] = []
      for (k, v) in http.allHeaderFields {
        let key = String(describing: k).lowercased()
        if key != "set-cookie" { headers.append((key, .string(String(describing: v)))) }
      }
      headers.sort { $0.0 < $1.0 }
      var out: Value = ["ok": true, "status": .int(Int64(http.statusCode)), "headers": .object(headers)]
      if marker != nil { out = out.with("truncated", .bool(truncated)) }
      if asJSON {
        guard let v = ValueJSON.parse(data) else {
          return out.with("json", .null).with("text", .string(String(decoding: data.prefix(2048), as: UTF8.self))).with("error", "invalid json")
        }
        out = out.with("json", v)
      } else {
        out = out.with("text", .string(String(decoding: data, as: UTF8.self)))
      }
      return out
    } catch {
      return ["ok": false, "error": .string("net: \((error as NSError).localizedDescription)")]
    }
  }
}

/// Per-task delegate: follow a redirect only to a host the plugin may fetch, and drop the Cookie
/// header on any redirect (the new URL gets no cookies copied for the old one).
final class RedirectTaskGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let allowed: @Sendable (String) -> Bool
  init(allowed: @escaping @Sendable (String) -> Bool) { self.allowed = allowed }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
    guard let h = request.url?.host, allowed(h) else { return nil }
    var r = request
    r.setValue(nil, forHTTPHeaderField: "Cookie")
    return r
  }
}
