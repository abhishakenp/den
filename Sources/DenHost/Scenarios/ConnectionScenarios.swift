// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue
import WebKit

/// `--scenario` states for connections and the briefing, run against the real plugins with the
/// local fakes (`MockServices`: Slack, GitHub, Gmail, Google Calendar, Notion) and a private
/// (in-memory) profile, so snapshots never touch a real account or den's real website data.
///
/// - `briefingEmpty`: no connection yet, the first-run page with the Connect buttons.
/// - `connectToast`: "Connect Slack" through the real flow (sign-in tab → session detected →
///   toast), snapshotted while the toast shows.
/// - `briefing` / `briefingFeed`: every connection signed in (Slack with 2 workspaces, GitHub,
///   Gmail with 2 accounts, Calendar through its address, Notion), then the briefing: fetch →
///   Foundation Models (when available) → page; `briefingFeed` scrolls to the feed.
/// - `connectionsSettings`: the Connections sheet with the workspace and account pickers.
/// - `meetingReminder`: Calendar connected; a meeting starts in about a minute, so the reminder
///   card shows with Join.
@MainActor
public enum ConnectionScenarios {
  public static let names = ["briefingEmpty", "connectToast", "autoConnectToast", "briefing", "briefingFeed", "connectionsSettings", "meetingReminder", "liveFolder"]
  static var mock: MockServices?
  static let providerCount = 5

  public static func apply(_ name: String, runtime rt: DenRuntime) {
    // The reminder scenario shifts the fixtures so "Design review" (now + 10 min) starts in ~1 min.
    let m = MockServices(now: name == "meetingReminder" ? Date().addingTimeInterval(-9 * 60) : Date())
    try? m.start()
    mock = m
    rt.call("storage", "set", ["ns": "slack", "key": "endpoints", "value": [
      "api": .string(m.base + "/api/"), "origin": .string(m.base), "domain": "127.0.0.1", "signIn": .string(m.base + "/slack/signin")]])
    rt.call("storage", "set", ["ns": "github", "key": "base", "value": .string(m.base)])
    rt.call("storage", "set", ["ns": "gmail", "key": "endpoints", "value": [
      "base": .string(m.base), "domain": "127.0.0.1", "signIn": .string(m.base + "/google/signin")]])
    rt.call("storage", "set", ["ns": "calendar", "key": "endpoints", "value": [
      "domain": "127.0.0.1", "host": "127.0.0.1", "web": .string(m.base + "/calendar/r")]])
    rt.call("storage", "set", ["ns": "notion", "key": "endpoints", "value": [
      "api": .string(m.base + "/api/v3/"), "web": .string(m.base), "domain": "127.0.0.1", "signIn": .string(m.base + "/notion/signin")]])
    for p in ["slack", "github", "gmail", "calendar", "notion"] { rt.permissions.grant(p, ["session:127.0.0.1"]) }
    // Tabs opened by the connect flow use this space's profile: keep it in memory.
    let space = rt.call("spaces", "current").str("id")
    rt.call("spaces", "update", ["id": .string(space), "profile": "private"])

    if name == "connectToast" {
      // The snapshot waits for the sign-in to be detected (the "Slack connected" toast).
      SnapshotGate.settle = 0.6
      SnapshotGate.ready = { rt.call("connections", "get", ["id": "slack"]).flag("connected") }
    }
    whenProviders(rt) {
      switch name {
      case "briefingEmpty":
        rt.call("briefing", "open")
      case "connectToast":
        // Explicit URL: the plugin may have registered its sign-in page before the mock existed.
        rt.call("connections", "connect", ["id": "slack", "url": .string(m.base + "/slack/signin")])
      case "autoConnectToast":
        // Auto-connect, the real path: the github plugin watches its cookie domain (here the
        // mock, in the private profile), the user signs in on a page, the host's cookie watch
        // fires, the plugin probes and `connections` shows "GitHub connected" with Undo.
        rt.call("session", "watchCookies", ["plugin": "github", "domain": "127.0.0.1", "profile": "private"])
        let id = rt.call("webviews", "create", ["url": .string(m.base + "/login"), "profile": "private"]).str("id")
        _ = rt.webviews.materialize(id)
        poll({ (rt.call("connections", "get", ["id": "github"]).flag("connected")) }) {
          print("scenario.autoConnectToast connected=\(rt.call("connections", "get", ["id": "github"]).flag("connected"))")
        }
      case "connectionsSettings":
        connectAll(rt, m) {
          rt.call("connections", "open")
        }
      case "liveFolder":
        // GitHub signed in, then a live folder: the first feed primes it, one row is marked
        // done (the "1 ✓" chip) and one new item arrives (its dot), next to a stack of 3 PRs.
        let id = rt.call("webviews", "create", ["url": .string(m.base + "/login"), "profile": "private"]).str("id")
        _ = rt.webviews.materialize(id)
        poll({ rt.webviews.record(id)?.webView.map { !$0.isLoading && $0.url != nil } ?? false }) {
          rt.call("webviews", "close", ["id": .string(id)])
          rt.call("connections", "connect", ["id": "github"])
          poll({ rt.call("connections", "get", ["id": "github"]).flag("connected") }) {
            let fid = rt.call("tabs", "newLiveFolder", ["source": "github"]).str("id")
            var latest: [Value] = []
            _ = rt.plugins.on("feed.items") { v in if v.str("source") == "github", !v.list("items").isEmpty { latest = v.list("items") } }
            poll({ !latest.isEmpty }) {
              rt.plugins.emit("ui.action", ["id": .string("live:" + fid + ":github:acme/api#77"), "action": "close"])
              let fresh: Value = ["id": "github:acme/design#40", "key": "acme/design#40", "source": "github", "kind": "review",
                                  "title": "Icon set v3: final glyphs", "url": .string(m.base + "/acme/design/pull/40"), "where": "acme/design"]
              rt.plugins.emit("feed.items", ["source": "github", "items": .array(latest + [fresh])])
              rt.call("ui", "set", ["slot": "toast", "tree": nil])
            }
          }
        }
      case "meetingReminder":
        // The real Calendar host, so the seeded Calendar favorite shows the countdown chip.
        rt.call("storage", "set", ["ns": "calendar", "key": "endpoints", "value": ["domain": "127.0.0.1", "web": .string(m.base + "/calendar/r")]])
        rt.call("settings", "set", ["id": "calendar", "key": "address", "value": .string(m.base + "/calendar/ical/basic.ics")])
        poll({ rt.call("connections", "get", ["id": "calendar"]).flag("connected") }) {
          // The reminder follows the calendar's first read (a briefing refresh reads it).
          rt.call("briefing", "refresh")
        }
      default:
        connectAll(rt, m) {
          rt.call("briefing", "open")
          if name == "briefingFeed" { scrollWhenReady(rt, to: "briefing.feed") }
        }
      }
    }
  }

  /// Waits until the provider plugins have registered with `connections`.
  static func whenProviders(_ rt: DenRuntime, tries: Int = 0, _ go: @escaping () -> Void) {
    let n = rt.call("connections", "list").array?.count ?? 0
    if n >= providerCount || tries > 60 { return go() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenProviders(rt, tries: tries + 1, go) }
  }

  /// Signs in to every fake site in the private profile (as the user would in a tab), then connects.
  static func connectAll(_ rt: DenRuntime, _ m: MockServices, _ then: @escaping () -> Void) {
    var loaded = 0
    let pages = ["/slack/signin", "/login", "/google/signin", "/notion/signin"]
    rt.call("settings", "set", ["id": "calendar", "key": "address", "value": .string(m.base + "/calendar/ical/basic.ics")])
    for path in pages {
      let id = rt.call("webviews", "create", ["url": .string(m.base + path), "profile": "private"]).str("id")
      _ = rt.webviews.materialize(id)
      poll({ rt.webviews.record(id)?.webView.map { !$0.isLoading && $0.url != nil } ?? false }) {
        rt.call("webviews", "close", ["id": .string(id)])
        loaded += 1
        guard loaded == pages.count else { return }
        for p in ["slack", "github", "gmail", "calendar", "notion"] { rt.call("connections", "connect", ["id": .string(p)]) }
        poll({ (rt.call("connections", "list").array ?? []).filter { $0.flag("connected") }.count == providerCount }) {
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
