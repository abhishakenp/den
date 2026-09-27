import AppKit
import CordisValue

/// `--scenario` states for hover previews and the Library sheet. The cards are the trees the
/// `previews` plugin builds from the mock site data below (PluginTests/PreviewsTests checks they
/// stay identical), so snapshots need no network or sign-in.
@MainActor
public enum PreviewScenarios {
  public static let names = ["previewGitHub", "previewCalendar", "previewPage", "previewFolder", "libraryFooter"]

  public static func apply(_ name: String, runtime rt: DenRuntime, appearance: String) -> NSWindow? {
    guard names.contains(name) else { return nil }
    // With the plugins loaded (the app), the sidebar is the real one from `tabs`: cards anchor to
    // real rows. The data cards (GitHub, Calendar) are answered here with the mock data, so the
    // live `previews` plugin is kept out of those two (it would ask the real sites).
    let plugins = rt.plugins.serviceNames.contains("tabs")
    if !plugins { HostScenarios.seedSidebar(rt, appearance: appearance) }
    switch name {
    case "previewGitHub":
      if plugins {
        let id = rt.call("tabs", "open", ["url": "https://github.com/denhq/den/pull/482", "background": true]).str("id")
        rt.call("tabs", "rename", ["id": .string(id), "title": "Parser: accept trailing commas in tuple patterns"])
        hover(rt, id, prCard, live: false)
      } else {
        rows(rt, [("t1", "Example Domain", "sf:globe", true), ("pr", "Parser: accept trailing commas…", "sf:arrow.triangle.pull", false)])
        HostScenarios.showContent(rt)
        hover(rt, "pr", prCard, live: false)
      }
    case "previewCalendar":
      if plugins, let cal = tabIds(rt).first(where: { $0.1.contains("calendar.google.com") }) {
        hover(rt, cal.0, calendarCard, live: false)
      } else {
        pinned(rt, [("cal", "Calendar", "sf:calendar"), ("mail", "Inbox", "sf:envelope.fill")])
        HostScenarios.showContent(rt)
        hover(rt, "cal", calendarCard, live: false)
      }
    case "previewFolder":
      // The whole real path: tabs → previews (a folder card needs no network).
      if plugins, let f = (rt.call("tabs", "list")["pinned"].array ?? []).first(where: { $0.flag("folder") }) {
        hover(rt, f.str("id"), .null, live: true)
      } else {
        HostScenarios.showContent(rt)
        hover(rt, "f1", folderCard, live: false)
      }
    case "previewPage":
      if plugins {
        // The real path: tabs → previews → webviews.snapshot {width: 320, format: jpeg}. Show the
        // tab once so its page is loaded and can be snapshotted, then go back.
        let sel = rt.call("tabs", "selected").str("id")
        guard let other = tabIds(rt).first(where: { $0.2 == "today" && $0.0 != sel }) else { return rt.window.window }
        rt.call("tabs", "select", ["id": .string(other.0)])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
          rt.call("tabs", "select", ["id": .string(sel)])
          hover(rt, other.0, .null, live: true)
        }
      } else {
        let id = HostScenarios.page(rt, id: "t3", title: "Design review", host: "figma.com",
                                    body: "Hover a tab to glimpse it without switching. den keeps a small snapshot of the page, taken only when you hover.",
                                    tint: "#eef4ff")
        rt.call("content", "show", ["panes": [.string(id)]])
        let path = NSTemporaryDirectory() + "den-preview-scenario.jpg"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
          rt.call("webviews", "snapshot", ["id": .string(id), "path": .string(path), "width": 320, "format": "jpeg"])
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            HostScenarios.showContent(rt)
            hover(rt, "t3", pageCard.with("image", .string(path)).with("imageVersion", 1), live: false)
          }
        }
      }
    case "libraryFooter":
      // The real path: the footer's Library button (spaces plugin) → spaces.library → the tabs
      // plugin opens its archive in `overlay.library`. Needs the plugins.
      guard plugins else { return rt.window.window }
      for e in (HostScenarios.archiveItems().array ?? []).reversed() {
        rt.call("tabs", "addToArchive", ["url": e["url"], "title": e["title"]])
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        guard let b = HostScenarios.find("spaces.library", in: rt.ui.sidebarView) as? ButtonNode else { print("scenario.libraryFooter no button"); return }
        b.button.action()
        print("scenario.libraryFooter overlays=\(rt.call("ui", "get")["overlays"])")
      }
    default: break
    }
    return rt.window.window
  }

  /// (id, url, kind) of every tab in the current space, pinned first.
  static func tabIds(_ rt: DenRuntime) -> [(String, String, String)] {
    let l = rt.call("tabs", "list")
    var out: [(String, String, String)] = []
    for (section, kind) in [("favorites", "favorite"), ("pinned", "pinned"), ("today", "today")] {
      var stack = l.list(section)
      while !stack.isEmpty {
        let i = stack.removeFirst()
        if i.flag("folder") || i.flag("split") { stack = i.list("children") + stack } else { out.append((i.str("id"), i.str("url"), kind)) }
      }
    }
    return out
  }

  static func rows(_ rt: DenRuntime, _ rows: [(String, String, String, Bool)]) {
    rt.call("ui", "set", ["slot": "sidebar.today", "tree": ["type": "list", "id": "today", "children": .array(
      [["type": "divider", "id": "div", "action": "Clear"], ["type": "newTabRow", "id": "newtab"]]
        + rows.map { ["type": "tabRow", "id": .string($0.0), "title": .string($0.1), "icon": .string($0.2), "selected": .bool($0.3)] }
    )]])
  }

  static func pinned(_ rt: DenRuntime, _ rows: [(String, String, String)]) {
    rt.call("ui", "set", ["slot": "sidebar.pinned", "tree": ["type": "list", "id": "pinned", "children": .array(
      rows.map { ["type": "tabRow", "id": .string($0.0), "title": .string($0.1), "icon": .string($0.2)] }
        + [["type": "folder", "id": "f1", "title": "Reading", "open": true, "children": [["type": "tabRow", "id": "p2", "title": "The Swift Book", "icon": "sf:swift"]]]]
    )]])
  }

  /// Hovers row `id` through the real intent path. `live`: the row's plugin answers (tabs →
  /// previews); otherwise `card` answers, as the plugin would for the mock data.
  static func hover(_ rt: DenRuntime, _ id: String, _ card: Value, live: Bool) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      rt.window.root.layoutSubtreeIfNeeded()
      guard let row = HostScenarios.find(id, in: rt.ui.sidebarView) else { print("scenario.preview no row \(id)"); return }
      let target: NodeView = (row as? FolderNode)?.header ?? row
      (target as? HoverNode)?.hovering = true
      let hc = rt.ui.hoverCard!
      if !live { hc.intent.onShow = { _ in } }  // keep the live plugin out; the card below answers
      if live { hc.onShown = { ms in print(String(format: "scenario.hoverCard intentToVisibleMs=%.2f", ms)) } }
      hc.intent.delayMs = 0
      hc.entered(target)
      if !live {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          rt.call("ui", "set", ["slot": "hoverCard", "tree": card.with("anchor", .string(id)).with("type", "hoverCard")])
        }
      }
    }
  }

  // MARK: Mock site data (what the providers read)

  static let prJSON: Value = [
    "title": "Parser: accept trailing commas in tuple patterns", "state": "open", "draft": false, "merged": false, "merged_at": nil,
    "mergeable": false, "mergeable_state": "dirty", "head": ["ref": "fix/tuple-trailing-comma", "sha": "9f3c2e1"], "base": ["ref": "main"],
    "user": ["login": "abhi"], "additions": 214, "deletions": 37, "changed_files": 6, "updated_at": "2026-09-27T09:12:00Z",
    "requested_reviewers": [["login": "jonas"]], "requested_teams": [],
  ]

  /// `net.fetch` answers by URL substring, most specific first.
  public static let githubFixtures: [(String, Value)] = [
    ("/pulls/482/reviews", ["status": 200, "json": [["user": ["login": "mira"], "state": "COMMENTED"], ["user": ["login": "mira"], "state": "CHANGES_REQUESTED"]]]),
    ("/check-runs", ["status": 200, "json": ["check_runs": [
      ["name": "build (macOS)", "status": "completed", "conclusion": "failure", "html_url": "https://github.com/denhq/den/runs/1"],
      ["name": "test (linux)", "status": "completed", "conclusion": "failure", "html_url": "https://github.com/denhq/den/runs/2"],
      ["name": "test (macOS)", "status": "in_progress", "conclusion": nil, "html_url": "https://github.com/denhq/den/runs/3"],
      ["name": "lint", "status": "completed", "conclusion": "success", "html_url": "https://github.com/denhq/den/runs/4"],
      ["name": "docs", "status": "completed", "conclusion": "skipped", "html_url": "https://github.com/denhq/den/runs/5"],
    ]]]),
    ("/status", ["status": 200, "json": ["state": "pending", "statuses": []]]),
    ("/pulls/482", ["status": 200, "json": prJSON]),
  ]

  /// What the Calendar tab's page script returns at 10:20 am.
  public static let calendarEval: Value = [
    "now": 620, "date": "Sunday, September 27",
    "events": [
      ["title": "Company offsite", "start": 0, "end": 1440, "label": "All day", "link": "", "allDay": true],
      ["title": "Standup", "start": 540, "end": 555, "label": "9 – 9:15am", "link": "https://meet.google.com/std-abcd-efg", "allDay": false],
      ["title": "Design review", "start": 600, "end": 660, "label": "10 – 11am", "link": "https://meet.google.com/abc-defg-hij", "allDay": false],
      ["title": "1:1 with Mira", "start": 690, "end": 720, "label": "11:30am – 12pm", "link": "https://acme.zoom.us/j/123456", "allDay": false],
      ["title": "Ship den 0.2", "start": 840, "end": 900, "label": "2 – 3pm", "link": "", "allDay": false],
      ["title": "Dinner", "start": 1140, "end": 1260, "label": "7 – 9pm", "link": "", "allDay": false],
    ],
  ]

  public static let gmailAtom = """
    <?xml version="1.0" encoding="UTF-8"?><feed version="0.3" xmlns="http://purl.org/atom/ns#"><title>Gmail - Inbox for abhi@example.com</title>\
    <tagline>New messages in your Gmail Inbox</tagline><fullcount>3</fullcount><link rel="alternate" href="https://mail.google.com/mail/u/1" type="text/html" />\
    <modified>2026-09-27T10:05:00Z</modified>\
    <entry><title>Offsite agenda &amp; travel</title><summary>Here is the plan for Thursday</summary>\
    <link rel="alternate" href="https://mail.google.com/mail/u/1?account_id=abhi@example.com&amp;message_id=1&amp;view=conv" type="text/html" />\
    <modified>2026-09-27T09:58:00Z</modified><issued>2026-09-27T09:58:00Z</issued><id>tag:gmail.google.com,2004:1</id>\
    <author><name>Mira Chen</name><email>mira@example.com</email></author></entry>\
    <entry><title>[denhq/den] CI failed on main</title><summary>build (macOS) failed</summary>\
    <link rel="alternate" href="https://mail.google.com/mail/u/1?account_id=abhi@example.com&amp;message_id=2&amp;view=conv" type="text/html" />\
    <issued>2026-09-27T09:40:00Z</issued><author><name>GitHub</name><email>notifications@github.com</email></author></entry>\
    <entry><title>Invoice #2031</title><summary>Your invoice is ready</summary>\
    <link rel="alternate" href="https://mail.google.com/mail/u/1?account_id=abhi@example.com&amp;message_id=3&amp;view=conv" type="text/html" />\
    <issued>2026-09-26T18:00:00Z</issued><author><name>Jonas &amp; Co</name><email>billing@example.com</email></author></entry></feed>
    """

  // MARK: Cards (the plugin's output for the data above)

  static func row(_ title: String, subtitle: String? = nil, icon: String, status: String? = nil, accessory: String? = nil, url: String? = nil, id: String) -> Value {
    var r: Value = ["title": .string(title), "icon": .string(icon), "id": .string(id)]
    if let subtitle { r = r.with("subtitle", .string(subtitle)) }
    if let status { r = r.with("status", .string(status)) }
    if let accessory { r = r.with("accessory", .string(accessory)) }
    if let url { r = r.with("url", .string(url)) }
    return r
  }

  public static let prCard: Value = [
    "type": "hoverCard", "icon": "https://github.com/favicon.ico", "title": "Parser: accept trailing commas in tuple patterns",
    "subtitle": "denhq/den", "accessory": "#482",
    "badges": [
      ["text": "Open", "style": "success", "icon": "sf:arrow.triangle.pull"],
      ["text": "2 failing", "style": "failure", "icon": "sf:xmark.circle.fill"],
      ["text": "Conflicts", "style": "attention", "icon": "sf:exclamationmark.triangle.fill"],
      ["text": "Changes requested", "style": "failure", "icon": "sf:exclamationmark.bubble.fill"],
    ],
    "sections": [
      ["rows": [
        row("fix/tuple-trailing-comma", icon: "sf:arrow.triangle.branch", accessory: "into main", id: "branch"),
        row("Merge conflicts", subtitle: "Resolve them before this can merge", icon: "sf:exclamationmark.triangle.fill", status: "attention",
            url: "https://github.com/denhq/den/pull/482/conflicts", id: "conflicts"),
      ]],
      ["title": "Checks · 2 failing, 1 pending, 2 passing", "rows": [
        row("build (macOS)", icon: "sf:xmark.circle.fill", status: "failure", accessory: "Failed", url: "https://github.com/denhq/den/runs/1", id: "check:build (macOS)"),
        row("test (linux)", icon: "sf:xmark.circle.fill", status: "failure", accessory: "Failed", url: "https://github.com/denhq/den/runs/2", id: "check:test (linux)"),
        row("test (macOS)", icon: "sf:clock.fill", status: "pending", accessory: "Running", url: "https://github.com/denhq/den/runs/3", id: "check:test (macOS)"),
        row("2 more checks", icon: "sf:ellipsis.circle", url: "https://github.com/denhq/den/pull/482/checks", id: "checks"),
      ]],
      ["title": "Reviews", "rows": [
        row("mira", icon: "sf:exclamationmark.circle.fill", status: "failure", accessory: "Changes requested", id: "review:mira"),
        row("jonas", icon: "sf:clock", status: "pending", accessory: "Requested", id: "review:jonas"),
      ]],
    ],
    "footer": "+214 −37 · 6 files · abhi · 1h",
  ]

  public static let calendarCard: Value = [
    "type": "hoverCard", "icon": "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_27.ico",
    "title": "Rest of today", "subtitle": "Sunday, September 27",
    "badges": [["text": "Now · Design review", "style": "success", "icon": "sf:circle.fill"]],
    "sections": [["rows": [
      row("Company offsite", subtitle: "All day", icon: "sf:calendar", id: "event:0"),
      row("Design review", subtitle: "10 – 11am", icon: "sf:video.fill", status: "success", accessory: "Now", url: "https://meet.google.com/abc-defg-hij", id: "event:1"),
      row("1:1 with Mira", subtitle: "11:30am – 12pm", icon: "sf:video.fill", status: "accent", accessory: "in 1h 10m", url: "https://acme.zoom.us/j/123456", id: "event:2"),
      row("Ship den 0.2", subtitle: "2 – 3pm", icon: "sf:calendar", status: "accent", id: "event:3"),
      row("Dinner", subtitle: "7 – 9pm", icon: "sf:calendar", status: "accent", id: "event:4"),
    ]]],
    "actions": [["id": "join", "title": "Join Design review", "icon": "sf:video.fill", "style": "primary", "url": "https://meet.google.com/abc-defg-hij"]],
  ]

  static let pageCard: Value = [
    "type": "hoverCard", "icon": "sf:paintbrush.pointed.fill", "title": "Design review", "subtitle": "figma.com",
  ]

  static let folderCard: Value = [
    "type": "hoverCard", "icon": "sf:folder.fill", "title": "Reading", "subtitle": "3 tabs",
    "sections": [["rows": [
      row("The Swift Book", subtitle: "docs.swift.org", icon: "sf:swift", id: "p2"),
      row("Parser: accept trailing commas…", subtitle: "github.com", icon: "sf:arrow.triangle.pull", status: "failure", accessory: "CI failing", id: "pr"),
      row("Inbox", subtitle: "mail.google.com", icon: "sf:envelope.fill", status: "accent", accessory: "3", id: "mail"),
    ]]],
  ]
}
