// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue

/// `--scenario` states for hover cards, the PR peek, ⇧-hover link cards and the Library sheet.
/// They run the real path (sidebar hover intent → tabs → previews → `ui.card`) with the real
/// plugins; GitHub's API and the linked page come from the local `MockServices`, so snapshots need
/// no network, no account and no sign-in.
@MainActor
public enum PreviewScenarios {
  public static let names = ["previewTab", "previewPinned", "previewSplit", "previewPlaying", "prPassing", "prFailing", "prConflicts",
                             "prPrivate", "linkCard", "linkStatus", "previewCalendar", "previewFolder", "libraryFooter"]
  static var mock: MockServices?

  public static func apply(_ name: String, runtime rt: DenRuntime, appearance: String) -> NSWindow? {
    guard names.contains(name) else { return nil }
    guard rt.plugins.serviceNames.contains("tabs"), rt.plugins.serviceNames.contains("previews") else {
      print("scenario.\(name) needs the tabs and previews plugins")
      return rt.window.window
    }
    let m = MockServices()
    try? m.start()
    mock = m
    serveGitHub(m)
    // The previews plugin reads GitHub from the mock, with its usual permissions plus the mock's host.
    rt.call("storage", "set", ["ns": "previews", "key": "endpoints", "value": ["githubApi": .string(m.base + "/gh"), "githubWeb": .string(m.base)]])
    rt.permissions.grant("previews", rt.permissions.list("previews") + ["net:127.0.0.1", "session:127.0.0.1"])
    let today = { tabIds(rt).filter { $0.2 == "today" } }
    switch name {
    case "previewTab":
      // A today tab that isn't selected: its card has the compact page snapshot.
      let sel = rt.call("tabs", "selected").str("id")
      guard let other = today().first(where: { $0.0 != sel }) else { return rt.window.window }
      rt.call("tabs", "select", ["id": .string(other.0)])
      after(5) {
        rt.call("tabs", "select", ["id": .string(sel)])
        hover(rt, other.0)
      }
    case "previewPinned":
      guard let p = tabIds(rt).first(where: { $0.2 == "pinned" }) else { return rt.window.window }
      rt.call("tabs", "select", ["id": .string(p.0)])
      after(0.8) { hover(rt, p.0) }
    case "previewSplit":
      let ids = today().prefix(2).map { Value.string($0.0) }
      guard ids.count == 2 else { return rt.window.window }
      let r = rt.call("tabs", "split", ["ids": .array(ids), "layout": "horizontal"])
      after(0.8) { hover(rt, r.str("id")) }
    case "previewPlaying":
      guard let t = today().first else { return rt.window.window }
      rt.call("tabs", "select", ["id": .string(t.0)])
      // What WebKit's media script reports for a tab playing sound.
      after(0.6) {
        rt.plugins.emit("webviews.audio", ["id": .string(t.0), "playing": true])
        hover(rt, t.0)
      }
    case "prPassing", "prFailing", "prConflicts", "prPrivate":
      let (url, title) = [
        "prPassing": ("https://github.com/denhq/den/pull/481", "Sidebar: keep the hovered row's card while scrolling"),
        "prFailing": ("https://github.com/denhq/den/pull/482", "Parser: accept trailing commas in tuple patterns"),
        "prConflicts": ("https://github.com/denhq/den/pull/483", "Previews: cache OpenGraph heads per URL"),
        "prPrivate": ("https://github.com/acme/platform/pull/7", "Billing: prorate seat changes"),
      ][name]!
      // In the background: the tab's page never loads (nothing reaches github.com).
      let id = rt.call("tabs", "open", ["url": .string(url), "background": true]).str("id")
      rt.call("tabs", "rename", ["id": .string(id), "title": .string(title)])
      after(0.8) { hover(rt, id) }
    case "linkCard":
      m.page("/blog/rendering", """
        <html><head><title>Rendering</title>
        <meta property="og:title" content="How the web renders a frame">
        <meta property="og:description" content="Style, layout, paint and composite: a tour of the steps between a DOM change and pixels on screen, and what makes each one fast.">
        <meta property="og:site_name" content="The Rendering Blog">
        <meta property="og:image" content="\(writeOGImage())">
        </head><body>Post</body></html>
        """)
      m.page("/reading", """
        <html><head><title>Reading list</title><style>
        body{font:16px -apple-system;margin:48px 56px;color:#222} a{color:#0a5bd8} h1{font-size:26px}
        </style></head><body><h1>Reading list</h1>
        <p>Next up: <a id="l" href="\(m.base)/blog/rendering">How the web renders a frame</a>, then the WebKit blog.</p>
        <p>Hold ⇧ over a link to preview it.</p></body></html>
        """)
      let id = rt.call("tabs", "open", ["url": .string(m.base + "/reading")]).str("id")
      rt.call("tabs", "select", ["id": .string(id)])
      after(2.5) { shiftHover(rt, id, selector: "#l") }
    case "linkStatus":
      // Arc's status pill: a plain hover over a link shows its address at the bottom of the page;
      // after 1.5 s on the same link, the whole address (the snapshot is taken after that).
      m.page("/notes", """
        <html><head><title>Notes</title><style>
        body{font:16px -apple-system;margin:48px 56px;color:#222} a{color:#0a5bd8} h1{font-size:26px}
        </style></head><body><h1>Rendering notes</h1>
        <p>Start with <a id="l" href="https://webkit.org/blog/16301/how-a-frame-renders/?ref=notes#paint">how a frame renders</a>,
        then read about compositing.</p></body></html>
        """)
      let id = rt.call("tabs", "open", ["url": .string(m.base + "/notes")]).str("id")
      rt.call("tabs", "select", ["id": .string(id)])
      after(2.5) { plainHover(rt, id, selector: "#l") }
    case "previewCalendar":
      guard let cal = tabIds(rt).first(where: { $0.1.contains("calendar.google.com") }) else { return rt.window.window }
      after(0.8) { hover(rt, cal.0) }
    case "previewFolder":
      guard let f = (rt.call("tabs", "list")["pinned"].array ?? []).first(where: { $0.flag("folder") }) else { return rt.window.window }
      after(0.8) { hover(rt, f.str("id")) }
    case "libraryFooter":
      for e in (HostScenarios.archiveItems().array ?? []).reversed() {
        rt.call("tabs", "addToArchive", ["url": e["url"], "title": e["title"]])
      }
      after(0.8) {
        guard let b = HostScenarios.find("spaces.library", in: rt.ui.sidebarView) as? ButtonNode else { print("scenario.libraryFooter no button"); return }
        b.button.action()
        print("scenario.libraryFooter overlays=\(rt.call("ui", "get")["overlays"])")
      }
    default: break
    }
    return rt.window.window
  }

  static func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
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

  /// Hovers node `id` through the real intent path (its own dwell skipped) and reports how long
  /// the card took to appear after intent.
  static func hover(_ rt: DenRuntime, _ id: String) {
    rt.window.root.layoutSubtreeIfNeeded()
    guard let row = HostScenarios.find(id, in: rt.ui.sidebarView) else { print("scenario.preview no row \(id)"); return }
    let target: NodeView = (row as? FolderNode)?.header ?? row
    (target as? HoverNode)?.hovering = true
    let cards = rt.ui.cards!
    cards.onShown = { ms in print(String(format: "scenario.card intentToVisibleMs=%.2f", ms)) }
    cards.intent.enter(target.nodeId, delayMs: 0)
    // Hold it as if the pointer rested on the card: a snapshot run's window is transparent and
    // click-through, and the real pointer moving over its place must not close the card.
    after(0.1) { cards.intent.enterCard() }
  }

  /// Holds ⇧ over the link `selector` in tab `id`'s page, the way a person would: the page sees a
  /// Shift keydown and a mouseover with `shiftKey`. The host's link listener reports it.
  static func shiftHover(_ rt: DenRuntime, _ id: String, selector: String) {
    let js = """
      const a = document.querySelector('\(selector)');
      document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Shift', shiftKey: true, bubbles: true}));
      a.dispatchEvent(new MouseEvent('mouseover', {shiftKey: true, bubbles: true, clientX: a.getBoundingClientRect().left + 4, clientY: a.getBoundingClientRect().top + 4}));
      """
    rt.webviews.record(id)?.webView?.evaluateJavaScript(js) { _, e in if let e { print("scenario.linkCard js error \(e)") } }
    rt.plugins.on("webviews.linkHover") { v in print("scenario.linkHover url=\(v.str("url")) rect=\(v["rect"])") }
  }

  /// A plain mouseover on the link `selector` in tab `id`'s page (the status pill's trigger).
  static func plainHover(_ rt: DenRuntime, _ id: String, selector: String) {
    let js = "document.querySelector('\(selector)').dispatchEvent(new MouseEvent('mouseover', {bubbles: true}))"
    rt.webviews.record(id)?.webView?.evaluateJavaScript(js) { _, e in if let e { print("scenario.linkStatus js error \(e)") } }
    rt.plugins.on("webviews.linkStatus") { v in print("scenario.linkStatus url=\(v.str("url"))") }
  }

  /// A small picture for the OpenGraph card, written to a temporary file.
  static func writeOGImage() -> String {
    let img = NSImage(size: NSSize(width: 600, height: 300), flipped: false) { r in
      NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.36, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.55, green: 0.3, blue: 0.9, alpha: 1)])?.draw(in: r, angle: 20)
      NSColor(white: 1, alpha: 0.9).setFill()
      for i in 0..<5 { NSBezierPath(roundedRect: NSRect(x: 60 + CGFloat(i) * 100, y: 90 + CGFloat(i % 2) * 40, width: 80, height: 80), xRadius: 14, yRadius: 14).fill() }
      return true
    }
    let path = NSTemporaryDirectory() + "den-og-scenario.png"
    if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
      try? png.write(to: URL(fileURLWithPath: path))
    }
    return "file://" + path
  }

  // MARK: Mock GitHub (what api.github.com returns)

  static func serveGitHub(_ m: MockServices) {
    for (path, v) in githubFixtures {
      m.page("/gh/repos/denhq/den" + path, ValueJSON.string(v["json"]), type: "application/json")
    }
  }

  static func pr(_ n: Int, _ title: String, mergeable: Bool, state: String = "clean", additions: Int, deletions: Int, files: Int, login: String, avatar: Int) -> Value {
    ["title": .string(title), "state": "open", "draft": false, "merged": false, "merged_at": nil, "mergeable": .bool(mergeable),
     "mergeable_state": .string(state), "head": ["ref": "work", "sha": .string("sha\(n)")], "base": ["ref": "main"],
     "user": ["login": .string(login), "avatar_url": .string("https://avatars.githubusercontent.com/u/\(avatar)?v=4")],
     "additions": .int(Int64(additions)), "deletions": .int(Int64(deletions)), "changed_files": .int(Int64(files)),
     "comments": 3, "review_comments": 4, "updated_at": "2026-09-27T09:12:00Z"]
  }

  public static let prJSON: Value = pr(482, "Parser: accept trailing commas in tuple patterns", mergeable: false, state: "dirty",
                                       additions: 214, deletions: 37, files: 6, login: "abhi", avatar: 1)

  static func run(_ name: String, _ status: String, _ conclusion: Value, _ n: Int) -> Value {
    ["name": .string(name), "status": .string(status), "conclusion": conclusion, "html_url": .string("https://github.com/denhq/den/runs/\(n)")]
  }

  /// `net.fetch` answers by URL path under /repos/denhq/den (tests match by substring).
  public static let githubFixtures: [(String, Value)] = [
    // #482: two failures, one running, a merge conflict.
    ("/commits/sha482/check-runs", ["status": 200, "json": ["check_runs": [
      run("build (macOS)", "completed", "failure", 1), run("test (linux)", "completed", "failure", 2), run("test (macOS)", "in_progress", nil, 3),
      run("lint", "completed", "success", 4), run("docs", "completed", "skipped", 5),
    ]]]),
    ("/commits/sha482/status", ["status": 200, "json": ["state": "pending", "statuses": []]]),
    ("/pulls/482", ["status": 200, "json": prJSON]),
    // #481: all green.
    ("/commits/sha481/check-runs", ["status": 200, "json": ["check_runs": [
      run("build (macOS)", "completed", "success", 11), run("test (linux)", "completed", "success", 12), run("test (macOS)", "completed", "success", 13),
      run("lint", "completed", "success", 14),
    ]]]),
    ("/commits/sha481/status", ["status": 200, "json": ["state": "success", "statuses": []]]),
    ("/pulls/481", ["status": 200, "json": pr(481, "Sidebar: keep the hovered row's card while scrolling", mergeable: true, additions: 1521, deletions: 36, files: 22, login: "mira", avatar: 2)]),
    // #483: checks passing but a conflict with main, one still running.
    ("/commits/sha483/check-runs", ["status": 200, "json": ["check_runs": [
      run("build (macOS)", "completed", "success", 21), run("test (linux)", "completed", "success", 22), run("test (macOS)", "in_progress", nil, 23),
      run("lint", "queued", nil, 24),
    ]]]),
    ("/commits/sha483/status", ["status": 200, "json": ["state": "pending", "statuses": []]]),
    ("/pulls/483", ["status": 200, "json": pr(483, "Previews: cache OpenGraph heads per URL", mergeable: false, state: "dirty", additions: 88, deletions: 12, files: 3, login: "jonas", avatar: 3)]),
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
}
#endif
