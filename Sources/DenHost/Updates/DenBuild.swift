import Foundation

/// What this den binary is, from its Info.plist (stamped by scripts/bundle.sh). Read once at
/// launch: the bundle on disk can be replaced by an update while this process keeps running.
public struct DenBuild: Sendable, Equatable {
  public var version: String  // CFBundleShortVersionString, e.g. 0.1.0-alpha.1
  public var build: Int  // CFBundleVersion (monotonic; Sparkle compares it)
  public var commit: String  // DenCommit
  /// DenHostAPI: the host API generation (number of commits that changed the host). A managed
  /// plugin is built against one generation and only loads into a host of that generation.
  /// nil for unbundled dev builds, which accept every plugin.
  public var hostAPI: Int?
  public var builtAt: String  // DenBuildDate, ISO 8601

  public init(version: String = "dev", build: Int = 0, commit: String = "", hostAPI: Int? = nil, builtAt: String = "") {
    self.version = version
    self.build = build
    self.commit = commit
    self.hostAPI = hostAPI
    self.builtAt = builtAt
  }

  public init(info: [String: Any]) {
    func int(_ k: String) -> Int? { (info[k] as? Int) ?? (info[k] as? String).flatMap { Int($0) } }
    self.init(version: info["CFBundleShortVersionString"] as? String ?? "dev", build: int("CFBundleVersion") ?? 0,
              commit: info["DenCommit"] as? String ?? "", hostAPI: int("DenHostAPI"), builtAt: info["DenBuildDate"] as? String ?? "")
  }

  /// The running binary. First read at launch (main.swift) and never again.
  @MainActor public static let running = DenBuild(info: Bundle.main.infoDictionary ?? [:])

  /// The host API generation of the app bundle at `contents` (…/Contents) as it is on disk now.
  public static func hostAPI(ofContents contents: URL) -> Int? {
    guard let d = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] else { return nil }
    return DenBuild(info: d).hostAPI
  }
}
