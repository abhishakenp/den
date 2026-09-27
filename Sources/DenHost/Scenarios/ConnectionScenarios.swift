// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue
import WebKit

/// `--scenario` states for connections and the briefing, run against the real plugins with the
/// local fake Slack/GitHub (`MockServices`) and a private (in-memory) profile, so snapshots never
/// touch a real account or den's real website data.
///
/// - `briefingEmpty`: no connection yet, the first-run page with the Connect buttons.
/// - `connectToast`: "Connect Slack" through the real flow (sign-in tab → session detected →
///   toast), snapshotted while the toast shows.
/// - `briefing` / `briefingFeed`: Slack (2 workspaces) and GitHub connected, then the briefing:
///   fetch → Foundation Models (when available) → page; `briefingFeed` scrolls to the feed.
/// - `connectionsSettings`: the Connections sheet with the workspace picker.
@MainActor
public enum ConnectionScenarios {
  public static let names = ["briefingEmpty", "connectToast", "briefing", "briefingFeed", "connectionsSettings"]
  static var mock: MockServices?

  public static func apply(_ name: String, runtime rt: DenRuntime) {
    let m = MockServices()
    try? m.start()
    mock = m
    rt.call("storage", "set", ["ns": "slack", "key": "endpoints", "value": [
      "api": .string(m.base + "/api/"), "origin": .string(m.base), "domain": "127.0.0.1", "signIn": .string(m.base + "/slack/signin")]])
    rt.call("storage", "set", ["ns": "github", "key": "base", "value": .string(m.base)])
    rt.permissions.grant("slack", ["session:127.0.0.1"])
    rt.permissions.grant("github", ["session:127.0.0.1"])
    // Tabs opened by the connect flow use this space's profile: keep it in memory.
    let space = rt.call("spaces", "current").str("id")
    rt.call("spaces", "update", ["id": .string(space), "profile": "private"])

    whenProviders(rt) {
      switch name {
      case "briefingEmpty":
        rt.call("briefing", "open")
      case "connectToast":
        // Explicit URL: the plugin may have registered its sign-in page before the mock existed.
        rt.call("connections", "connect", ["id": "slack", "url": .string(m.base + "/slack/signin")])
      case "connectionsSettings":
        connectBoth(rt, m) {
          rt.call("connections", "open")
        }
      default:
        connectBoth(rt, m) {
          rt.call("briefing", "open")
          if name == "briefingFeed" { scrollWhenReady(rt, to: "briefing.feed") }
        }
      }
    }
  }

  /// Waits until the slack and github plugins have registered with `connections`.
  static func whenProviders(_ rt: DenRuntime, tries: Int = 0, _ go: @escaping () -> Void) {
    let n = rt.call("connections", "list").array?.count ?? 0
    if n >= 2 || tries > 40 { return go() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenProviders(rt, tries: tries + 1, go) }
  }

  /// Signs in to both fake sites in the private profile (as the user would in a tab), then connects.
  static func connectBoth(_ rt: DenRuntime, _ m: MockServices, _ then: @escaping () -> Void) {
    var loaded = 0
    for url in [m.base + "/slack/signin", m.base + "/login"] {
      let id = rt.call("webviews", "create", ["url": .string(url), "profile": "private"]).str("id")
      _ = rt.webviews.materialize(id)
      poll({ rt.webviews.record(id)?.webView.map { !$0.isLoading && $0.url != nil } ?? false }) {
        rt.call("webviews", "close", ["id": .string(id)])
        loaded += 1
        guard loaded == 2 else { return }
        rt.call("connections", "connect", ["id": "slack"])
        rt.call("connections", "connect", ["id": "github"])
        poll({ (rt.call("connections", "list").array ?? []).filter { $0.flag("connected") }.count == 2 }) {
          // The first connect opens the settings sheet for the workspace picker; keep the page clean.
          rt.call("connections", "close")
          then()
        }
      }
    }
  }

  static func poll(_ cond: @escaping () -> Bool, tries: Int = 0, _ then: @escaping () -> Void) {
    if cond() || tries > 150 { return then() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll(cond, tries: tries + 1, then) }
  }

  /// Scrolls the briefing page so the node `id` is at the top, once the AI summary has landed.
  static func scrollWhenReady(_ rt: DenRuntime, to id: String) {
    poll({ rt.call("briefing", "state").str("summaryState") == "ai" || rt.call("briefing", "state").str("summaryState") == "plain" }) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        guard let sheet = rt.ui.sheets["overlay.briefing"], let target = HostScenarios.find(id, in: sheet.doc) else { return }
        sheet.layoutSubtreeIfNeeded()
        let y = target.convert(NSPoint.zero, to: sheet.doc).y - 16
        sheet.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        sheet.scroll.reflectScrolledClipView(sheet.scroll.contentView)
      }
    }
  }
}
#endif
