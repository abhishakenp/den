import AppKit
import CordisValue
import DenTestSupport
@preconcurrency import LocalAuthentication
import Testing

@testable import DenHost
@testable import PluginCores

/// The `importer` plugin end to end: real host services (`files` on a synthetic home built by
/// `ImportFixtures`, never the user's data), the real `spaces`, `tabs` and `commandbar` cores, and
/// the importer core with its declared permissions (Plugins/importer/permissions.json).
@MainActor
@Suite(.serialized, .watchdog)
struct ImporterTests {
  final class Approve: VaultAuth {
    func authenticate(reason: String, _ done: @escaping @MainActor (Bool, LAContext?) -> Void) { DispatchQueue.main.async { done(true, nil) } }
  }

  struct Setup {
    let h: Harness
    let core: ImporterCore
    let home: URL
    var opened: [URL] = []
  }

  /// Spaces, tabs, the command bar and the importer on a fixture home.
  func start(home: URL? = nil, chromeHistory: Int = 1200) throws -> (Harness, ImporterCore, URL) {
    let h = Harness()
    h.startCommandBar()
    let fixtures = try home ?? ImportFixtures.makeHome(chromeHistory: chromeHistory)
    h.rt.files.home = fixtures
    h.rt.files.openURL = { [weak h] u in h?.events.append(("opened", .string(u.absoluteString))) }
    let plugins = Permissions.repoPlugins!.appendingPathComponent("importer/permissions.dylib")
    #expect(!h.rt.permissions.loadSidecar(plugin: "importer", dylib: plugins).isEmpty)
    h.record(["importer.done", "importer.undone", "importer.passwords"])
    let core = ImporterCore(env: h.env)
    h.rt.plugins.provide("importer") { m, a in core.handle(m, a) }
    core.start()
    h.fireTimers()  // the delayed start: Settings row and command
    return (h, core, fixtures)
  }

  func runAndWait(_ h: Harness, _ source: String, line: UInt = #line) async -> Value {
    let before = h.events.filter { $0.0 == "importer.done" }.count
    let r = h.rt.call("importer", "run", ["source": .string(source)])
    #expect(!r.isError, "run \(source): \(r)")
    _ = await Wait.until("import from \(source)", seconds: 60, line: line) { h.events.filter { $0.0 == "importer.done" }.count > before }
    return h.events.last { $0.0 == "importer.done" }?.1 ?? .null
  }

  func toast(_ h: Harness) -> String { h.rt.ui.toasts.last { $0.toastId == ImporterCore.toastId }?.label.stringValue ?? "" }
  func space(_ h: Harness, _ name: String) -> Value? { (h.rt.call("spaces", "list").array ?? []).first { $0.str("name") == name } }
  func items(_ h: Harness, _ sid: String, _ section: String) -> [Value] { h.tabs("list", ["spaceId": .string(sid)])[section].array ?? [] }
  func flat(_ items: [Value]) -> [Value] { items.flatMap { $0["folder"] == true || $0["split"] == true ? flat($0.list("children")) : [$0] } }
  func folder(_ items: [Value], _ title: String) -> Value? {
    for i in items where i["folder"] == true {
      if i.str("title") == title { return i }
      if let f = folder(i.list("children"), title) { return f }
    }
    return nil
  }
  func tabCount(_ h: Harness) -> Int {
    var n = flat(h.tabs("list")["favorites"].array ?? []).count
    for s in h.spaceIds { n += flat(items(h, s, "pinned")).count + flat(items(h, s, "today")).count }
    return n
  }

  @Test func findsEveryBrowserAndCostsNothingUntilUsed() throws {
    let (h, core, _) = try start()
    #expect(core.job == nil && core.pending.isEmpty)
    #expect(h.rt.settings.entries["importer"]?.section == "general")
    let ids = (h.rt.call("importer", "sources").array ?? []).map { $0.str("id") }
    #expect(ids == ["arc", "safari", "chrome", "firefox", "zen"])
    // Undeclared paths are refused by the host, whatever the plugin asks for.
    #expect(h.rt.call("files", "list", ["plugin": "importer", "path": "~/Documents"]).isError)
    #expect(h.rt.call("files", "list", ["plugin": "importer", "path": "~/Library/Application Support/Arc/../../Mail"]).isError)
  }

  @Test func arcSpacesPinnedTabsFoldersFavoritesAndHistory() async throws {
    let (h, _, _) = try start()
    let current = h.rt.call("spaces", "current").str("id")
    let tabsBefore = tabCount(h)
    let done = await runAndWait(h, "arc")
    #expect(done["spaces"] == 4 && done["pinned"] == 23 && done["today"] == 2 && done["favorites"] == 3 && done["history"] == 300, "\(done)")
    #expect(toast(h) == "Imported 4 spaces, 23 pinned tabs, 3 favorites, 2 open tabs and 300 history entries")

    // den's own "Personal", "Work" and "Side Project" take Arc's tabs and look; "Research" is new.
    let names = (h.rt.call("spaces", "list").array ?? []).map { $0.str("name") }
    #expect(names == ["Personal", "Work", "Side Project", "Research"])
    let personal = try #require(space(h, "Personal"))
    #expect(personal.str("icon") == "🏠")
    #expect(personal["theme"]["colors"] == ["#f69e7a", "#fad48d"])
    #expect(personal["theme"]["grain"] == 0.25)
    #expect(space(h, "Research")?.str("icon") == "🔬")
    #expect(space(h, "Side Project")?["theme"]["colors"].array?.count == 3)
    #expect(space(h, "Side Project")?.str("profile") == "Side Project")  // Arc's second profile
    #expect(h.rt.call("spaces", "current").str("id") == current)

    // Nested folders, custom titles, a split's tabs, Today tabs; internal pages left out.
    let pinned = items(h, personal.str("id"), "pinned")
    let reading = try #require(folder(pinned, "Reading"))
    let longreads = try #require(folder(reading.list("children"), "Longreads"))
    #expect(longreads.list("children").map { $0.str("url") } == ["https://aeon.co/essays/what-is-it-like-to-be-a-bat", "https://longform.org/best"])
    #expect(flat(pinned).contains { $0.str("title") == "Journal" && $0.str("url").hasPrefix("https://www.notion.so/") })
    #expect(flat(pinned).contains { $0.str("url") == "https://www.airbnb.com/s/Lisbon/homes" })
    #expect(flat(pinned).allSatisfy { $0.str("pinnedUrl") == $0.str("url") })
    let today = flat(items(h, personal.str("id"), "today")).map { $0.str("url") }
    #expect(today.contains("https://news.ycombinator.com/") && !today.contains { $0.hasPrefix("arc:") })
    let work = items(h, try #require(space(h, "Work")).str("id"), "pinned")
    #expect(folder(work, "Incidents")?.list("children").first?.str("url") == "https://acme.pagerduty.com/incidents")
    // Favorites: Slack, Spotify, Discord; Gmail and Calendar were already there.
    let favs = flat(h.tabs("list")["favorites"].array ?? []).map { URLs.host($0.str("url")) }
    #expect(favs.filter { $0 == "mail.google.com" }.count == 1)
    #expect(favs.contains("app.slack.com") && favs.contains("open.spotify.com") && favs.contains("discord.com"))
    // Nothing loads: imported tabs are lazy web view records.
    let imported = try #require(flat(pinned).first { $0.str("title") == "Journal" })
    #expect(h.rt.call("webviews", "get", ["id": imported["id"]])["live"] == false)

    // History feeds the command bar.
    #expect(h.rt.call("commands", "history")["count"] == 300)
    h.key("cmd+t")
    h.type("wikipedia lisbon")
    #expect(h.barRowIds.contains { $0.hasPrefix("hist:en.wikipedia.org/wiki/lisbon") }, "\(h.barRowIds)")
    h.key("cmd+t")

    // Again: nothing doubles.
    let afterFirst = tabCount(h)
    #expect(afterFirst == tabsBefore + 23 + 2 + 3)
    let again = await runAndWait(h, "arc")
    #expect(again["spaces"] == 0 && again["pinned"] == 0 && again["favorites"] == 0 && again["history"] == 0, "\(again)")
    #expect(toast(h) == "Nothing new to import from Arc.")
    #expect(tabCount(h) == afterFirst && (h.rt.call("spaces", "list").array ?? []).count == 4)

    // Undo takes the import back out: tabs, history, the new space and the look it gave den's.
    let batch = done.str("batch")
    #expect(!h.rt.call("importer", "undo", ["batch": .string(batch)]).isError)
    #expect(tabCount(h) == tabsBefore)
    #expect((h.rt.call("spaces", "list").array ?? []).map { $0.str("name") } == ["Personal", "Work", "Side Project"])
    #expect(space(h, "Personal")?.str("icon") != "🏠")
    #expect(space(h, "Side Project")?.str("profile") == "default")
    #expect(h.rt.call("commands", "history")["count"] == 0)
    #expect(toast(h) == "Import undone")
  }

  @Test func chromeBookmarksOpenTabsAndHistory() async throws {
    let (h, _, _) = try start()
    let sid = h.rt.call("spaces", "current").str("id")
    let done = await runAndWait(h, "chrome")
    #expect(done["bookmarks"] == 9 && done["openTabs"] == 3 && done["history"] == 1200, "\(done)")
    #expect(toast(h) == "Imported 9 bookmarks, 3 open tabs and 1,200 history entries")
    let pinned = items(h, sid, "pinned")
    let bookmarks = try #require(folder(pinned, "Chrome Bookmarks"))
    #expect(bookmarks["open"] == false)
    #expect(bookmarks.list("children").first?.str("url") == "https://developer.mozilla.org/en-US/")
    let apple = try #require(folder(bookmarks.list("children"), "Apple"))
    #expect(apple.list("children").map { $0.str("title") } == ["Apple Developer Forums", "App Store Connect"])
    #expect(folder(bookmarks.list("children"), "Other Bookmarks") != nil)
    #expect(!flat([bookmarks]).contains { $0.str("url").hasPrefix("javascript:") })
    // The last session's open tabs, each at the page it was on, closed tabs and windows left out.
    let group = try #require(folder(items(h, sid, "today"), "From Chrome"))
    #expect(group.list("children").map { $0.str("url") } == [
      "https://github.com/abhishakenp/den", "https://webkit.org/blog/", "https://www.swift.org/documentation/",
    ])
    // Hidden and internal history entries aren't imported.
    #expect(h.rt.call("commands", "history")["count"] == 1200)
  }

  @Test func safariBookmarksAndHistory() async throws {
    let (h, _, _) = try start()
    let done = await runAndWait(h, "safari")
    #expect(done["bookmarks"] == 5 && done["history"] == 150, "\(done)")
    let bm = try #require(folder(items(h, h.rt.call("spaces", "current").str("id"), "pinned"), "Safari Bookmarks"))
    #expect(bm.list("children").first?.str("url") == "https://www.apple.com/")
    #expect(folder(bm.list("children"), "News")?.list("children").count == 2)
    #expect(folder(bm.list("children"), "Reading List")?.list("children").first?.str("title") == "How WebKit renders a frame")
  }

  @Test func safariWithoutFullDiskAccessOpensThatSettingOnce() async throws {
    let home = try ImportFixtures.makeHome()
    let safari = home.appendingPathComponent("Library/Safari")
    // What macOS does to den without Full Disk Access: the folder exists, reading it fails.
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: safari.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path) }
    let (h, _, _) = try start(home: home)
    let src = (h.rt.call("importer", "sources").array ?? []).first { $0.str("id") == "safari" }
    #expect(src?["denied"] == true)
    let r = h.rt.call("importer", "run", ["source": "safari"])
    #expect(r["needsAccess"] == true)
    #expect(h.events.filter { $0.0 == "opened" }.map { $0.1.string ?? "" } == ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
    #expect(toast(h) == "Turn on den in Full Disk Access, then import from Safari again.")
    #expect(!h.events.contains { $0.0 == "importer.done" })
    // The dialog says it in one line instead of nagging.
    h.rt.call("importer", "open")
    let choice = h.rt.ui.dialog.node.list("choices").first { $0.str("id") == "safari" }
    #expect(choice?.str("subtitle") == "Needs Full Disk Access: Import opens that setting")
  }

  @Test func firefoxBookmarksAndHistoryFromTheProfileInUse() async throws {
    let (h, _, _) = try start()
    let done = await runAndWait(h, "firefox")
    #expect(done["bookmarks"] == 5 && done["history"] == 250, "\(done)")
    let bm = try #require(folder(items(h, h.rt.call("spaces", "current").str("id"), "pinned"), "Firefox Bookmarks"))
    #expect(folder(bm.list("children"), "Rust")?.list("children").map { $0.str("title") } == ["Rust", "The Book"])
    #expect(!flat([bm]).contains { $0.str("url").hasPrefix("place:") })
  }

  @Test func zenWorkspacesEssentialsAndPins() async throws {
    let (h, _, _) = try start()
    let done = await runAndWait(h, "zen")
    #expect(done["spaces"] == 2 && done["pinned"] == 3 && done["favorites"] == 2 && done["bookmarks"] == 2 && done["history"] == 60, "\(done)")
    let home = try #require(space(h, "Home"))
    #expect(home.str("icon") == "🌿" && home["theme"]["colors"] == ["#2e8b57", "#90ee90"])
    let study = items(h, try #require(space(h, "Study")).str("id"), "pinned")
    #expect(folder(study, "Notes")?.list("children").map { $0.str("url") } == ["https://www.notion.so/zen-notes", "https://excalidraw.com/"])
  }

  @Test func theImportDialogAndTheTipsCard() async throws {
    let (h, core, _) = try start()
    h.rt.call("commands", "run", ["id": .string(ImporterCore.openCommand)])
    #expect(h.rt.ui.dialogOpen && core.dialogOpen)
    let ids = h.rt.ui.dialog.node.list("choices").map { $0.str("id") }
    #expect(ids == ["arc", "safari", "chrome", "firefox", "zen", "passwords"])
    h.action(ImporterCore.dialogId, "button", ["button": "import", "choices": ["firefox"]])
    #expect(!h.rt.ui.dialogOpen)
    _ = await Wait.until("firefox import", seconds: 60) { h.events.contains { $0.0 == "importer.done" } }
    #expect(h.events.last { $0.0 == "importer.done" }?.1["source"] == "firefox")

    // The tips plugin's one-click card names what was found and runs the import.
    let tips = TipsCore(env: h.env)
    tips.start()
    h.fireTimers()
    let card = h.rt.ui.sidebarView.notice.root?.node ?? .null
    #expect(ValueJSON.string(card).contains("Bring your tabs and bookmarks from Arc, Safari, Chrome, Firefox or Zen in one click."))
    h.action("tips.import.run", "click", "chrome")
    _ = await Wait.until("chrome import from the card", seconds: 60) { h.events.last { $0.0 == "importer.done" }?.1["source"] == "chrome" }
    #expect(h.storage("tips", "import") == "done")
  }

  @Test func passwordsFromACSVExport() async throws {
    let (h, _, _) = try start()
    let store = MemoryVaultStore()
    _ = store.save(origin: "https://github.com", username: "jdoe", password: Data("old".utf8))
    h.rt.vault.store = store
    h.rt.vault.auth = Approve()
    let csv = FileManager.default.temporaryDirectory.appendingPathComponent("den-passwords-\(UUID()).csv")
    try Data("""
      name,url,username,password,note
      GitHub,https://github.com/login,jdoe,hunter2,
      Example,https://accounts.example.com/signin,"jane, doe",p@ss "quoted",
      App,android://abc@com.example.app/,jd,x,
      Linear,linear.app,jd@acme.test,s3cret,"multi
      line note"
      """.utf8).write(to: csv)
    h.rt.vault.pickFile = { done in DispatchQueue.main.async { done(csv) } }
    h.rt.call("importer", "run", ["source": "passwords"])
    _ = await Wait.until("passwords", seconds: 20) { h.events.contains { $0.0 == "importer.passwords" } }
    let r = h.events.last { $0.0 == "importer.passwords" }?.1 ?? .null
    #expect(r["added"] == 2 && r["existing"] == 1 && r["skipped"] == 1, "\(r)")
    #expect(!ValueJSON.string(r).contains("hunter2") && !ValueJSON.string(r).contains("s3cret"))
    #expect(toast(h) == "Imported 2 passwords · 1 already saved")
    #expect(store.accounts().count == 3)
    #expect(FileManager.default.fileExists(atPath: csv.path))  // read, never deleted
  }

  /// A 20,000-entry history: the database is read and converted off the main thread; what stays
  /// on it (merging into the command bar's history and the sidebar) is measured.
  @Test func bigHistoryStaysOffTheMainThread() async throws {
    let (h, _, _) = try start(chromeHistory: 20000)
    final class Gaps { var last = Date(); var max = 0.0 }
    let gaps = Gaps()
    let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
      let now = Date()
      gaps.max = Swift.max(gaps.max, now.timeIntervalSince(gaps.last))
      gaps.last = now
    }
    RunLoop.main.add(timer, forMode: .common)
    let t0 = Date()
    let done = await runAndWait(h, "chrome")
    let total = Date().timeIntervalSince(t0)
    timer.invalidate()
    print("importer.bigHistory total=\(Int(total * 1000)) ms, longest main-thread stall=\(Int(gaps.max * 1000)) ms, history=\(done["history"])")
    #expect(done["history"] == 20000)
    #expect(h.rt.call("commands", "history")["count"] == 20000)
    #expect(gaps.max < 3.0)
  }
}
