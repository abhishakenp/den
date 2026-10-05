import AppKit
import CordisValue
import DenTestSupport
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// The extension APIs den answers itself (ExtensionAPIs): a local extension that asks for
/// `bookmarks`, `history`, `sessions`, `search`, `downloads`, `sidePanel` and `identity` calls them
/// from its own page, through the shim's native-messaging bridge, against den's real tabs,
/// archive, downloads, web panels and a sign-in window; its background gets the events.
@MainActor
@Suite(.serialized, .watchdog(seconds: 240))
struct ExtensionAPIsTests {
  struct Outcome: @unchecked Sendable {
    let value: Any?
    let error: Error?
  }

  static func fixture() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("den-ext-apis-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    let files: [String: String] = [
      "manifest.json": """
        {"manifest_version": 3, "name": "Den APIs", "version": "1.0",
         "permissions": ["storage", "tabs", "bookmarks", "history", "sessions", "search", "downloads", "sidePanel", "identity"],
         "host_permissions": ["http://127.0.0.1/*"],
         "background": {"service_worker": "bg.js"},
         "side_panel": {"default_path": "panel.html"},
         "action": {"default_title": "Den APIs"}}
        """,
      // The background keeps what its events said, for the page to read back.
      "bg.js": """
        const log = (k, v) => chrome.storage.local.get({events: []}).then(({events}) => chrome.storage.local.set({events: events.concat([k + ' ' + JSON.stringify(v)])}));
        chrome.bookmarks.onCreated.addListener((id, n) => log('bookmarks.onCreated', n.url || n.title));
        chrome.bookmarks.onRemoved.addListener((id, info) => log('bookmarks.onRemoved', info.node.url));
        chrome.history.onVisited.addListener((h) => log('history.onVisited', h.url));
        chrome.downloads.onCreated.addListener((d) => log('downloads.onCreated', d.url));
        chrome.downloads.onChanged.addListener((d) => d.state && log('downloads.onChanged', d.state.current));
        """,
      "probe.html": "<!doctype html><title>probe</title><script src='probe.js'></script>",
      "probe.js": "window.ready = true;",
      "panel.html": "<!doctype html><title>Den APIs Panel</title><script src='probe.js'></script><body>panel</body>",
    ]
    for (k, v) in files { try v.write(to: d.appendingPathComponent(k), atomically: true, encoding: .utf8) }
    return d
  }

  func wait(_ seconds: Double = 45, file: StaticString = #fileID, line: UInt = #line, _ cond: () async -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: seconds, file: file, line: line) { await cond() }
  }

  /// Installs the fixture (accepting the prompt) and returns its id.
  func install(_ h: Harness) async throws -> String {
    let dir = try Self.fixture()
    h.record(["webext.installed", "webext.failed"])
    _ = h.rt.call("webext", "install", ["path": .string(dir.path)])
    #expect(await wait { h.rt.ui.dialogOpen })
    let msg = h.rt.ui.dialog.message.stringValue
    #expect(msg.contains("Read and change your bookmarks") && msg.contains("Manage your downloads"), "\(msg)")
    #expect(!msg.contains("Not available in den"), "den provides all of them: \(msg)")
    #expect(!msg.contains("native apps"), "den's own nativeMessaging isn't shown: \(msg)")
    h.action(try #require(h.rt.extensions.prompts.first?.id), "button", ["button": "ok"])
    #expect(await wait { h.events.contains { $0.0 == "webext.installed" } })
    let id = try #require(h.events.first { $0.0 == "webext.installed" }?.1.str("id"))
    #expect(await wait { h.rt.extensions.contexts[id]?.isLoaded == true })
    let d = h.rt.call("webext", "get", ["id": .string(id)])
    #expect(d.list("unsupported").isEmpty, "\(d)")
    return id
  }

  /// The extension's own page, where `chrome.*` and the shim are.
  func page(_ h: Harness, _ id: String, _ path: String = "probe.html") async throws -> WKWebView {
    let ctx = try #require(h.rt.extensions.contexts[id])
    let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: try #require(ctx.webViewConfiguration))
    w.load(URLRequest(url: ctx.baseURL.appendingPathComponent(path)))
    #expect(await wait(20) {
      if w.isLoading { return false }
      let ready = await Wait.js(w, "String(window.ready)") as? String
      return ready == "true"
    })
    return w
  }

  /// Runs an async function body in the page; returns its JSON-decoded result (or "error: …").
  func run(_ w: WKWebView, _ body: String, line: UInt = #line) async -> Value {
    let r: Outcome? = await Wait.callback("js", seconds: 30, line: line) { done in
      w.callAsyncJavaScript("try { return JSON.stringify(await (async () => { \(body) })()); } catch (e) { return JSON.stringify({thrown: String(e && e.message || e)}); }",
                            arguments: [:], in: nil, in: .page) { res in
        switch res {
        case .success(let v): done(Outcome(value: v, error: nil))
        case .failure(let e): done(Outcome(value: nil, error: e))
        }
      }
    }
    if let e = r?.error { return ["thrown": .string(e.localizedDescription)] }
    return (r?.value as? String).flatMap { ValueJSON.parse($0) } ?? .null
  }

  func events(_ w: WKWebView) async -> [String] {
    (await run(w, "return (await chrome.storage.local.get({events: []})).events;")).array?.compactMap(\.string) ?? []
  }

  @Test func bookmarksHistoryAndSessions() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/visited", "<!doctype html><title>Visited Page</title><body>hi</body>")
    let h = Harness()
    NSApp.mainMenu = NSMenu()
    h.startTabs()
    let id = try await install(h)
    let w = try await page(h, id)

    // The tree: Favorites (1) and Pinned (2) with a folder per space holding its pinned tabs.
    let tree = await run(w, "return await chrome.bookmarks.getTree();")
    let root = tree[0]
    #expect(root.list("children").map { $0.str("id") } == ["1", "2"], "\(tree)")
    #expect(root.list("children")[0].str("folderType") == "bookmarks-bar")
    let favIds = h.ids("favorites")
    #expect(root.list("children")[0].list("children").map { $0.str("id") } == favIds)
    let space = try #require(root.list("children")[1].list("children").first)
    #expect(space.str("id") == "space:" + h.rt.call("spaces", "current").str("id"))
    #expect(space.list("children").map { $0.str("id") } == h.ids("pinned"))

    // create pins a tab (not loaded), in that space; the background hears onCreated.
    let made = await run(w, "return await chrome.bookmarks.create({parentId: '\(space.str("id"))', title: 'Den Docs', url: '\(mock.base)/docs'});")
    let bid = try #require(made["id"].string, "\(made)")
    #expect(made.str("parentId") == space.str("id") && made.str("title") == "Den Docs" && made.str("url") == mock.base + "/docs")
    #expect(h.ids("pinned").contains(bid))
    #expect(h.rt.webviews.record(bid)?.webView == nil, "a new bookmark isn't loaded")
    #expect(await wait { await events(w).contains("bookmarks.onCreated \"\(mock.base)/docs\"") })
    // search, update (title and the pinned address), move into a folder, remove (archived).
    #expect((await run(w, "return (await chrome.bookmarks.search('den docs')).map(b => b.id);")).array == [.string(bid)])
    let up = await run(w, "return await chrome.bookmarks.update('\(bid)', {title: 'Docs', url: '\(mock.base)/docs2'});")
    #expect(up.str("title") == "Docs" && up.str("url") == mock.base + "/docs2", "\(up)")
    #expect(h.tabs("list")["pinned"].array?.first { $0.str("id") == bid }?.str("pinnedUrl") == mock.base + "/docs2")
    let folder = await run(w, "return await chrome.bookmarks.create({parentId: '2', title: 'Reading'});")
    let fid = try #require(folder["id"].string, "\(folder)")
    let moved = await run(w, "return await chrome.bookmarks.move('\(bid)', {parentId: '\(fid)'});")
    #expect(moved.str("parentId") == fid, "\(moved)")
    #expect((await run(w, "return (await chrome.bookmarks.getChildren('\(fid)')).map(b => b.id);")).array == [.string(bid)])
    let notEmpty = await run(w, "return await chrome.bookmarks.remove('\(fid)');")
    #expect(notEmpty.str("thrown").contains("non-empty"), "\(notEmpty)")
    _ = await run(w, "return await chrome.bookmarks.remove('\(bid)');")
    #expect(h.tabs("archive").array?.first?.str("url").hasPrefix(mock.base + "/docs") == true, "removed bookmarks go to the archive")
    #expect(await wait { await events(w).contains { $0.hasPrefix("bookmarks.onRemoved") } })
    _ = await run(w, "return await chrome.bookmarks.removeTree('\(fid)');")
    #expect((await run(w, "return await chrome.bookmarks.get('\(fid)');")).str("thrown").contains("Can't find"))
    #expect((await run(w, "return await chrome.bookmarks.remove('1');")).str("thrown").contains("root"))

    // history: a page a tab visits is recorded (the extension has `history`) and onVisited fires.
    let tab = h.tabs("open", ["url": .string(mock.base + "/visited")]).str("id")
    h.tabs("select", ["id": .string(tab)])
    #expect(await wait { h.rt.webviews.record(tab)?.title == "Visited Page" })
    #expect(await wait { await events(w).contains("history.onVisited \"\(mock.base)/visited\"") })
    let found = await run(w, "return await chrome.history.search({text: 'visited'});")
    #expect(found[0].str("url") == mock.base + "/visited" && found[0].str("title") == "Visited Page", "\(found)")
    #expect((found[0]["visitCount"].int ?? 0) >= 1)
    #expect(((await run(w, "return await chrome.history.getVisits({url: '\(mock.base)/visited'});")).array?.count ?? 0) >= 1)
    // The archive is history too (the removed bookmark), and deleteUrl clears it from the Library.
    let archived = await run(w, "return (await chrome.history.search({text: 'docs2', startTime: 0})).map(h => h.url);")
    #expect(archived.array == [.string(mock.base + "/docs2")], "\(archived)")
    _ = await run(w, "return await chrome.history.deleteUrl({url: '\(mock.base)/docs2'});")
    #expect(h.tabs("archive").array?.contains { $0.str("url") == mock.base + "/docs2" } == false)

    // sessions: the archive; restore reopens the newest entry.
    h.tabs("close", ["id": .string(tab)])
    let closed = await run(w, "return await chrome.sessions.getRecentlyClosed({maxResults: 5});")
    #expect(closed[0]["tab"].str("url") == mock.base + "/visited", "\(closed)")
    let restored = await run(w, "return await chrome.sessions.restore();")
    #expect(restored["tab"].str("url").hasPrefix(mock.base + "/visited"), "\(restored)")
    #expect(h.ids("today").contains { h.rt.webviews.record($0)?.url.hasPrefix(mock.base + "/visited") == true })
    // An extension without the permission is refused by den, whatever it sends.
    w.stopLoading()
  }

  @Test func downloadsAndSearch() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.files = ["/report.zip": ("application/zip", Data(repeating: 7, count: 40_000))]
    let h = Harness()
    let folder = h.root.appendingPathComponent("Downloads", isDirectory: true)
    h.rt.downloads.folder = { folder }
    NSApp.mainMenu = NSMenu()
    h.startTabs()
    let id = try await install(h)
    let w = try await page(h, id)

    let n = await run(w, "return await chrome.downloads.download({url: '\(mock.base)/report.zip', filename: 'den tests/q3.zip'});")
    let num = try #require(n.int, "\(n)")
    #expect(await wait { h.rt.downloads.items.first?.state == "done" })
    let item = await run(w, "return (await chrome.downloads.search({id: \(num)}))[0];")
    #expect(item.str("state") == "complete" && item["exists"] == true, "\(item)")
    #expect(item.str("filename") == folder.appendingPathComponent("den tests/q3.zip").path)
    #expect(item["fileSize"].int == 40_000 && item.str("mime") == "application/zip")
    #expect(item.str("byExtensionId") == id)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("den tests/q3.zip").path))
    let heard = await wait { let e = await events(w); return e.contains("downloads.onCreated \"\(mock.base)/report.zip\"") && e.contains("downloads.onChanged \"complete\"") }
    let log = await events(w)
    #expect(heard, "\(log)")
    // The same name again: Finder's "q3 2.zip" (uniquify), or replaced (overwrite).
    _ = await run(w, "return await chrome.downloads.download({url: '\(mock.base)/report.zip', filename: 'den tests/q3.zip'});")
    #expect(await wait { h.rt.downloads.items.first?.state == "done" && h.rt.downloads.items.count == 2 })
    #expect(h.rt.downloads.items[0].name == "q3 2.zip")
    #expect((await run(w, "return await chrome.downloads.download({url: '\(mock.base)/report.zip', filename: '../escape.zip'});")).str("thrown").contains("bad file name"))
    // search by query and state; erase takes it off den's list; removeFile deletes the file.
    #expect(((await run(w, "return await chrome.downloads.search({query: ['q3'], state: 'complete'});")).array?.count) == 2)
    #expect((await run(w, "return await chrome.downloads.getFileIcon(\(num));")).string?.hasPrefix("data:image/png;base64,") == true)
    _ = await run(w, "return await chrome.downloads.removeFile(\(num));")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("den tests/q3.zip").path))
    let erased = await run(w, "return await chrome.downloads.erase({id: \(num)});")
    #expect(erased.array == [.int(Int64(num))])
    #expect(!h.rt.downloads.items.contains { $0.id == "d\(num)" })
    #expect((await run(w, "return await chrome.downloads.pause(9999);")).str("thrown").contains("Invalid download id"))

    // search.query: den's default engine in a new tab.
    let before = h.ids("today").count
    _ = await run(w, "return await chrome.search.query({text: 'den browser', disposition: 'NEW_TAB'});")
    #expect(await wait { h.ids("today").count == before + 1 })
    let opened = try #require(h.ids("today").first)
    #expect(await wait { (h.rt.webviews.record(opened)?.url ?? "").contains("den%20browser") }, "\(h.rt.webviews.record(opened)?.url ?? "")")
  }

  @Test func sidePanelAndIdentity() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    let h = Harness()
    NSApp.mainMenu = NSMenu()
    h.startTabs()
    let panels = PanelsCore(env: h.env)
    h.rt.plugins.provide("panels") { m, a in panels.handle(m, a) }
    panels.start()
    let id = try await install(h)
    let w = try await page(h, id)

    // sidePanel.open: the extension's page in den's panel column, with its icon in the switcher.
    #expect((await run(w, "return await chrome.sidePanel.getOptions({});")).str("path") == "panel.html")
    _ = await run(w, "return await chrome.sidePanel.open({windowId: 1});")
    #expect(panels.open == "panel-ext-" + id && h.rt.content.sideId == "panel-ext-" + id)
    #expect(await wait { h.rt.webviews.record("panel-ext-" + id)?.title == "Den APIs Panel" })
    #expect((await run(w, "return await chrome.sidePanel.close({windowId: 1});")).isNull)
    #expect(panels.open == nil)
    // openPanelOnActionClick: the toolbar button toggles the panel instead of the action.
    _ = await run(w, "return await chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true});")
    #expect((await run(w, "return await chrome.sidePanel.getPanelBehavior();"))["openPanelOnActionClick"] == true)
    #expect(h.rt.call("webext", "action", ["id": .string(id)]) == .ok)
    #expect(panels.open == "panel-ext-" + id)
    #expect(h.rt.call("webext", "action", ["id": .string(id)]) == .ok)
    #expect(panels.open == nil)
    // Kept across launches (apis.json), and its panel goes with the extension.
    #expect((try? String(contentsOf: h.rt.extensions.root.appendingPathComponent("apis.json"), encoding: .utf8))?.contains("openOnAction\":true") == true)

    // identity: the redirect URL is Chrome's form for this id; a sign-in page that sends the
    // browser there hands the URL back, with nothing requested from the redirect host.
    let redirect = await run(w, "return chrome.identity.getRedirectURL('cb');")
    #expect(redirect.string == "https://\(id).chromiumapp.org/cb")
    let to = "https://\(id).chromiumapp.org/cb?code=42"
    let enc = to.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let silent = await run(w, "return await chrome.identity.launchWebAuthFlow({url: '\(mock.base)/redirect-to?to=\(enc)', interactive: false});")
    #expect(silent.string == to, "\(silent)")
    // A page that needs the user: non-interactive fails, interactive shows a window; the user
    // approving (a click that navigates to the redirect) finishes it.
    mock.page("/consent", "<!doctype html><title>Consent</title><a id=ok href='\(to)&state=ok'>Allow</a>")
    let needs = await run(w, "return await chrome.identity.launchWebAuthFlow({url: '\(mock.base)/consent', interactive: false});")
    #expect(needs.str("thrown") == "User interaction required.", "\(needs)")
    var result: Value = .null
    let pending = Task { @MainActor in result = await run(w, "return await chrome.identity.launchWebAuthFlow({url: '\(mock.base)/consent', interactive: true});") }
    #expect(await wait { h.rt.extensions.apis.identity.flows[id]?.window != nil })
    let flow = try #require(h.rt.extensions.apis.identity.flows[id])
    #expect(flow.window?.title == "Sign in · 127.0.0.1")
    flow.web.evaluateJavaScript("document.getElementById('ok').click()") { _, _ in }
    await pending.value
    #expect(result.string == to + "&state=ok", "\(result)")
    #expect(h.rt.extensions.apis.identity.flows[id] == nil)
    // Closing the window is a refusal.
    let refused = Task { @MainActor in result = await run(w, "return await chrome.identity.launchWebAuthFlow({url: '\(mock.base)/consent', interactive: true});") }
    #expect(await wait { h.rt.extensions.apis.identity.flows[id]?.window != nil })
    h.rt.extensions.apis.identity.flows[id]?.window?.performClose(nil)
    await refused.value
    #expect(result.str("thrown") == "The user did not approve access.", "\(result)")
    #expect((await run(w, "return await chrome.identity.getAuthToken({interactive: true});")).str("thrown").contains("getAuthToken"))

    // Removing the extension removes its panel.
    #expect(h.rt.call("webext", "uninstall", ["id": .string(id)]) == .ok)
    #expect(!panels.panels.contains { $0.owner == id })
    panels.stop()
  }
}
