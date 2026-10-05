// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue
import WebKit

/// `--scenario extensionMenus` (needs `--demo`): a local probe extension with keyboard `commands`
/// and `contextMenus` items for every context, checked in the running app, where WebKit pops up
/// its real context menu and AppKit dispatches real key events. Prints `ext.menus …` lines
/// (`result ok=…` last) and exits. With `DEN_EXT_STORE=<chrome web store id>,…` it also installs
/// those extensions from the store and lists their commands and right-click items.
@MainActor
public enum ExtensionMenuScenarios {
  public static let names = ["extensionMenus"]

  public static func apply(_ name: String, runtime rt: DenRuntime) {
    Task { @MainActor in await run(rt) }
  }

  static func log(_ s: String) { print("ext.menus " + s) }

  /// The probe extension (also the tests' fixture: ExtensionMenusTests).
  public static let manifest = """
    {"manifest_version": 3, "name": "Menu Probe", "version": "1.0",
     "permissions": ["contextMenus", "scripting", "tabs"],
     "host_permissions": ["http://127.0.0.1/*"],
     "action": {"default_popup": "popup.html", "default_title": "Menu Probe"},
     "background": {"service_worker": "bg.js"},
     "commands": {
       "_execute_action": {"suggested_key": {"default": "Alt+Shift+P"}},
       "probe-alt": {"suggested_key": {"default": "Alt+Shift+Y"}, "description": "Probe Alt"},
       "probe-mac": {"suggested_key": {"default": "Ctrl+Shift+9", "mac": "MacCtrl+Shift+U"}, "description": "Probe MacCtrl"},
       "probe-conflict": {"suggested_key": {"default": "Ctrl+T"}, "description": "Probe Conflict"},
       "probe-nokey": {"description": "Probe No Key"}
     }}
    """

  /// Reports into the page (`data-cmd`, `data-clicked`) so the scenario and tests can read what
  /// the extension received; the badge says it too (`cmd:<last 3>`, `C`).
  public static let background = """
    const report = async (tabId, key, val) => {
      try { await chrome.scripting.executeScript({target: {tabId}, func: (k, v) => { document.documentElement.dataset[k] = v; }, args: [key, JSON.stringify(val)]}); }
      catch (e) { console.log('report', e); }
    };
    chrome.commands.onCommand.addListener(async (command, tab) => {
      chrome.action.setBadgeText({text: command.slice(-3)});
      const t = tab || (await chrome.tabs.query({active: true, currentWindow: true}))[0];
      if (t) report(t.id, 'cmd', {command, tabId: tab ? tab.id : null, url: tab ? tab.url : null});
    });
    chrome.contextMenus.onClicked.addListener((info, tab) => {
      chrome.action.setBadgeText({text: 'C'});
      if (tab) report(tab.id, 'clicked', {info, tabId: tab.id, tabUrl: tab.url});
    });
    const made = [];
    const mk = (o) => new Promise((res) => chrome.contextMenus.create(o, () => { made.push(o.id + (chrome.runtime.lastError ? '!' + chrome.runtime.lastError.message : '')); res(); }));
    chrome.contextMenus.removeAll(async () => {
      for (const c of ['page', 'link', 'image', 'selection', 'editable', 'frame', 'video', 'action', 'all']) await mk({id: 'ctx-' + c, title: 'Probe ' + c, contexts: [c]});
      await mk({id: 'parent', title: 'Probe Parent', contexts: ['page']});
      await mk({id: 'child1', parentId: 'parent', title: 'Probe Child 1', contexts: ['page']});
      await mk({id: 'child2', parentId: 'parent', title: 'Probe Child 2', contexts: ['page']});
      await mk({id: 'check', type: 'checkbox', checked: true, title: 'Probe Check', contexts: ['page']});
      await mk({id: 'radio1', type: 'radio', checked: true, title: 'Probe Radio 1', contexts: ['page']});
      await mk({id: 'radio2', type: 'radio', checked: false, title: 'Probe Radio 2', contexts: ['page']});
      await mk({id: 'doc', title: 'Probe Doc Match', contexts: ['page'], documentUrlPatterns: ['http://127.0.0.1/*']});
      await mk({id: 'docno', title: 'Probe Doc NoMatch', contexts: ['page'], documentUrlPatterns: ['https://example.com/*']});
      await mk({id: 'tgt', title: 'Probe Target Match', contexts: ['link'], targetUrlPatterns: ['*://*/target*']});
      await mk({id: 'tgtno', title: 'Probe Target NoMatch', contexts: ['link'], targetUrlPatterns: ['https://nomatch.example/*']});
      await mk({id: 'sel', title: 'Probe Sel "%s"', contexts: ['selection']});
      await mk({id: 'tab', title: 'Probe tab', contexts: ['tab']});
      globalThis.denMade = made;
      chrome.action.setBadgeText({text: 'M' + made.length});
    });
    """

  public static let page = """
    <!doctype html><title>Probe</title><style>body{margin:0;font:16px -apple-system}.x{position:absolute;width:150px;height:150px;margin:0}</style>
    <a class=x id=l href="/target?x=1" style="left:0;top:0;display:block">A link text</a>
    <img class=x id=i src="/i.png" style="left:160px;top:0">
    <p id=t class=x style="left:320px;top:0">selected words here</p>
    <textarea id=f class=x style="left:480px;top:0">some text</textarea>
    <iframe id=fr class=x src="/frame" style="left:0;top:200px;width:300px;height:150px;border:0"></iframe>
    """

  public static func fixture() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("den-ext-menus-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    let files = ["manifest.json": manifest, "bg.js": background,
                 "popup.html": "<!doctype html><title>Probe Popup</title><body style='margin:0;width:200px;height:100px'>Probe</body>"]
    for (k, v) in files { try v.write(to: d.appendingPathComponent(k), atomically: true, encoding: .utf8) }
    return d
  }

  static let png: Data = {
    let img = NSImage(size: NSSize(width: 8, height: 8))
    img.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    img.unlockFocus()
    return NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
  }()

  static func wait(_ s: Double, _ c: () async -> Bool) async -> Bool { await ExtensionScenarios.wait(s, c) }
  static func eval(_ w: WKWebView?, _ js: String) async -> Any? { await ExtensionScenarios.eval(w, js) }

  /// Every item title, submenus indented, with key equivalents and state.
  static func dump(_ m: NSMenu, _ indent: String = "") -> [String] {
    m.items.flatMap { i -> [String] in
      if i.isSeparatorItem { return [indent + "-"] }
      var s = indent + i.title
      if !i.keyEquivalent.isEmpty { s += " [\(i.keyEquivalentModifierMask.rawValue >> 16):\(i.keyEquivalent)]" }
      if i.state == .on { s += " (on)" }
      return [s] + (i.submenu.map { dump($0, indent + "  ") } ?? [])
    }
  }

  static func find(_ m: NSMenu, _ title: String) -> NSMenuItem? {
    for i in m.items {
      if i.title == title { return i }
      if let s = i.submenu, let f = find(s, title) { return f }
    }
    return nil
  }

  static func key(_ chars: String, _ ign: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags, _ win: NSWindow, _ type: NSEvent.EventType = .keyDown) -> NSEvent? {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                     context: nil, characters: chars, charactersIgnoringModifiers: ign, isARepeat: false, keyCode: code)
  }

  /// Which den menu item holds each extension command's key, if any.
  static func logOwners(_ rt: DenRuntime) {
    guard let main = NSApp.mainMenu else { return }
    func all(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map { $0 === rt.extensions.commandsMenu ? [] : all($0) } ?? []) } }
    let den = all(main)
    for (id, ctx) in rt.extensions.contexts {
      for c in ctx.commands {
        let k = ExtensionsService.chord(c.menuItem)
        let owner = k.flatMap { k in den.first { ExtensionsService.chord($0) == k } }
        log("command \(id) \(c.id) key=\(k ?? "none") denOwner=\(owner.map { "\($0.title) (\($0.menu?.title ?? ""))" } ?? "none")")
      }
    }
  }

  /// A real right-click at the point `js` returns; the menu as den finished it (then closed).
  static func storeMenu(_ w: DenWebView, _ js: String) async -> NSMenu? {
    nonisolated(unsafe) var got: NSMenu?
    DenWebView.menuOpened = { _, m in got = m; DispatchQueue.main.async { m.cancelTracking() } }
    defer { DenWebView.menuOpened = nil }
    guard let xy = await eval(w, js) as? [NSNumber], xy.count == 2 else { return nil }
    DevToolsScenarios.rightClick(w, at: NSPoint(x: CGFloat(xy[0].doubleValue) * w.pageZoom, y: CGFloat(xy[1].doubleValue) * w.pageZoom))
    _ = await wait(10) { got != nil }
    return got
  }

  static func run(_ rt: DenRuntime) async {
    var ok = true
    func check(_ name: String, _ v: Bool, _ note: String = "") { ok = ok && v; log("\(v ? "PASS" : "FAIL") \(name) \(note)") }
    let mock = MockServices()
    do { try mock.start() } catch { log("mock failed \(error)"); exit(1) }
    mock.page("/p", page)
    mock.page("/frame", "<!doctype html><body style='margin:0;background:#eef'>frame text</body>")
    mock.files = ["/i.png": ("image/png", png)]
    guard await wait(15, { rt.call("tabs", "selected")["id"].string != nil }) else { log("no tabs"); exit(1) }
    let tab = rt.call("tabs", "open", ["url": .string(mock.base + "/p")]).str("id")
    rt.call("tabs", "select", ["id": .string(tab)])
    ExtensionScenarios.tab = tab

    // Install the probe through the real dialog.
    guard let dir = try? fixture() else { exit(1) }
    rt.call("webext", "install", ["path": .string(dir.path)])
    guard await wait(60, { !rt.extensions.prompts.isEmpty }), let p = rt.extensions.prompts.first else { log("no prompt"); exit(1) }
    rt.plugins.emit("ui.action", ["id": .string(p.id), "action": "button", "value": ["button": "ok"]])
    guard await wait(60, { !rt.extensions.contexts.isEmpty }), let (extId, ctx) = rt.extensions.contexts.first.map({ ($0.key, $0.value) }) else { log("not loaded"); exit(1) }
    log("installed \(extId)")
    do { try await ctx.loadBackgroundContent() } catch { log("bg \(error)") }
    _ = await wait(20) { (ctx.action(for: nil)?.badgeText ?? "").hasPrefix("M") }
    log("badge after menus=\(ctx.action(for: nil)?.badgeText ?? "")")

    guard let w = rt.webviews.record(tab)?.webView as? DenWebView, await wait(20, { !w.isLoading && w.url?.path == "/p" }) else { log("page"); exit(1) }
    let win = rt.window.window

    // MARK: commands
    log("ctx.commands=" + ctx.commands.map { "\($0.id)|\($0.title)|\($0.activationKey ?? "nil")|\($0.modifierFlags.rawValue >> 16)" }.joined(separator: " ; "))
    if let m = rt.extensions.commandsMenu { log("Extensions menu: " + dump(m).joined(separator: " ; ")) } else { log("Extensions menu: none") }
    let topTitles = NSApp.mainMenu?.items.map(\.title) ?? []
    logOwners(rt)
    log("menu bar: \(topTitles)")

    func fired(_ expect: String) async -> Bool {
      await wait(8) { (await eval(w, "document.documentElement.dataset.cmd || ''") as? String ?? "").contains(expect) }
    }
    func reset() async { _ = await eval(w, "delete document.documentElement.dataset.cmd; 1") }

    let alt = key("Á", "Y", 16, [.option, .shift], win)!
    // 1. NSApp.sendEvent (the real AppKit path; needs den's window key).
    Presentation.activate()
    Presentation.show(win)
    win.makeKeyAndOrderFront(nil)
    win.makeFirstResponder(w)
    try? await Task.sleep(for: .milliseconds(500))
    log("key window is den=\(NSApp.keyWindow === win) active=\(NSApp.isActive) firstResponder=\(type(of: win.firstResponder as Any))")
    await reset()
    NSApp.sendEvent(alt)
    NSApp.sendEvent(key("Á", "Y", 16, [.option, .shift], win, .keyUp)!)
    check("⌥⇧Y via NSApp.sendEvent, page focused", await fired("probe-alt"), "data=\(await eval(w, "document.documentElement.dataset.cmd || ''") ?? "")")

    // 2. Page listening for and swallowing every keydown (like Vimium does for its own keys).
    _ = await eval(w, "window.addEventListener('keydown', e => { window.__seen = (window.__seen||'') + e.key + ','; e.preventDefault(); e.stopPropagation(); }, true); 1")
    await reset()
    NSApp.sendEvent(alt)
    check("⌥⇧Y while the page preventDefaults keydown", await fired("probe-alt"), "pageSaw=\(await eval(w, "window.__seen || ''") ?? "")")

    // 3. A text field focused in the page.
    _ = await eval(w, "document.getElementById('f').focus(); 1")
    await reset()
    NSApp.sendEvent(alt)
    check("⌥⇧Y in a page text field", await fired("probe-alt"), "value=\(await eval(w, "document.getElementById('f').value") ?? "")")

    // 4. den's sidebar / command bar focused.
    rt.call("commands", "open", ["mode": "new"])
    try? await Task.sleep(for: .milliseconds(600))
    log("command bar firstResponder=\(type(of: NSApp.keyWindow?.firstResponder as Any)) keyWindow=\(type(of: NSApp.keyWindow as Any))")
    await reset()
    NSApp.sendEvent(key("Á", "Y", 16, [.option, .shift], NSApp.keyWindow ?? win)!)
    check("⌥⇧Y with the command bar focused", await fired("probe-alt"))
    rt.call("commands", "close")
    try? await Task.sleep(for: .milliseconds(300))
    win.makeFirstResponder(rt.ui.sidebarView)
    await reset()
    NSApp.sendEvent(alt)
    check("⌥⇧Y with the sidebar focused", await fired("probe-alt"), "fr=\(type(of: win.firstResponder as Any))")

    // 5. MacCtrl → ⌃.
    win.makeFirstResponder(w)
    await reset()
    NSApp.sendEvent(key("\u{15}", "U", 32, [.control, .shift], win)!)
    check("⌃⇧U (MacCtrl) fires", await fired("probe-mac"))

    // 6. Conflict: Ctrl+T is ⌘T, den's New Tab. den's must win.
    let tabsBefore = rt.webviews.records.count
    await reset()
    NSApp.sendEvent(key("t", "t", 17, [.command], win)!)
    try? await Task.sleep(for: .milliseconds(1500))
    let cmdFired = (await eval(w, "document.documentElement.dataset.cmd || ''") as? String ?? "").contains("probe-conflict")
    log("⌘T: extension fired=\(cmdFired) webviews \(tabsBefore)->\(rt.webviews.records.count) commandBarOpen=\(rt.call("commands", "state"))")
    check("⌘T stays den's (extension's Ctrl+T doesn't fire)", !cmdFired)
    rt.call("commands", "close")
    rt.call("tabs", "select", ["id": .string(tab)])
    try? await Task.sleep(for: .milliseconds(500))
    win.makeFirstResponder(w)

    // 7. _execute_action opens the popup.
    rt.call("webext", "closePopup")
    NSApp.sendEvent(key("π", "P", 35, [.option, .shift], win)!)
    check("⌥⇧P (_execute_action) opens the popup", await wait(30) { rt.extensions.ui.popupFor == extId })
    rt.call("webext", "closePopup")

    // MARK: context menus
    var captured: NSMenu?
    DenWebView.menuOpened = { _, m in
      captured = m
      DispatchQueue.main.async { m.cancelTracking() }
    }
    func menuAt(_ js: String, _ label: String) async -> NSMenu? {
      captured = nil
      guard let xy = await eval(w, js) as? [NSNumber], xy.count == 2 else { log("\(label): no target"); return nil }
      DevToolsScenarios.rightClick(w, at: NSPoint(x: CGFloat(xy[0].doubleValue) * w.pageZoom, y: CGFloat(xy[1].doubleValue) * w.pageZoom))
      _ = await wait(10) { captured != nil }
      try? await Task.sleep(for: .milliseconds(200))
      if let m = captured { log("\(label) menu: " + dump(m).joined(separator: " ; ")) } else { log("\(label): no menu") }
      return captured
    }
    func click(_ m: NSMenu?, _ title: String) async -> [String: Any]? {
      guard let m, let it = find(m, title), let parent = it.menu else { return nil }
      _ = await eval(w, "delete document.documentElement.dataset.clicked; 1")
      parent.performActionForItem(at: parent.index(of: it))
      _ = await wait(8) { (await eval(w, "document.documentElement.dataset.clicked || ''") as? String ?? "") != "" }
      let s = await eval(w, "document.documentElement.dataset.clicked || ''") as? String ?? ""
      log("clicked \(title): \(s)")
      return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }
    func center(_ sel: String) -> String { "var r=document.querySelector('\(sel)').getBoundingClientRect();[r.x+r.width/2,r.y+r.height/2]" }
    func titles(_ m: NSMenu?) -> [String] { m.map { dump($0).map { $0.trimmingCharacters(in: .whitespaces) } } ?? [] }
    func has(_ m: NSMenu?, _ t: String) -> Bool { titles(m).contains { $0.hasPrefix(t) } }
    func count(_ m: NSMenu?, _ t: String) -> Int { titles(m).filter { $0.hasPrefix(t) }.count }

    let pm = await menuAt("[700,500]", "page")
    check("page: page item", has(pm, "Probe page"))
    check("page: not link/image/selection/editable", !has(pm, "Probe link") && !has(pm, "Probe image") && !has(pm, "Probe selection") && !has(pm, "Probe editable"))
    check("page: all item once", count(pm, "Probe all") == 1, "count=\(count(pm, "Probe all"))")
    check("page: submenu", pm.flatMap { find($0, "Probe Parent")?.submenu.map { $0.items.map(\.title) } } == ["Probe Child 1", "Probe Child 2"])
    check("page: checkbox on", pm.flatMap { find($0, "Probe Check")?.state } == .on)
    check("page: radio", pm.flatMap { find($0, "Probe Radio 1")?.state } == .on && pm.flatMap { find($0, "Probe Radio 2")?.state } == .off)
    check("page: documentUrlPatterns", has(pm, "Probe Doc Match") && !has(pm, "Probe Doc NoMatch"))
    check("page: no action/tab items", !has(pm, "Probe action") && !has(pm, "Probe tab"))
    if let i = await click(pm, "Probe page"), let info = i["info"] as? [String: Any] {
      check("page: onClicked", (info["menuItemId"] as? String) == "ctx-page" && (info["pageUrl"] as? String)?.hasSuffix("/p") == true && (i["tabUrl"] as? String)?.hasSuffix("/p") == true)
    } else { check("page: onClicked", false) }
    if let i = await click(pm, "Probe Check"), let info = i["info"] as? [String: Any] {
      check("checkbox: onClicked checked flips", (info["wasChecked"] as? Bool) == true && (info["checked"] as? Bool) == false, "\(info)")
    } else { check("checkbox: onClicked", false) }
    if let i = await click(pm, "Probe Child 2"), let info = i["info"] as? [String: Any] {
      check("submenu child: onClicked", (info["menuItemId"] as? String) == "child2" && (info["parentMenuItemId"] as? String) == "parent", "\(info)")
    } else { check("submenu child: onClicked", false) }

    let lm = await menuAt(center("#l"), "link")
    check("link: link item", has(lm, "Probe link"))
    check("link: targetUrlPatterns", has(lm, "Probe Target Match") && !has(lm, "Probe Target NoMatch"))
    if let i = await click(lm, "Probe link"), let info = i["info"] as? [String: Any] {
      check("link: onClicked linkUrl", (info["linkUrl"] as? String)?.hasSuffix("/target?x=1") == true && (info["pageUrl"] as? String)?.hasSuffix("/p") == true, "\(info)")
    } else { check("link: onClicked", false) }

    let im = await menuAt(center("#i"), "image")
    check("image: image item", has(im, "Probe image"))
    if let i = await click(im, "Probe image"), let info = i["info"] as? [String: Any] {
      check("image: onClicked srcUrl", (info["srcUrl"] as? String)?.hasSuffix("/i.png") == true && (info["mediaType"] as? String) == "image", "\(info)")
    } else { check("image: onClicked", false) }

    let selJS = "var p=document.getElementById('t'),r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,14);getSelection().removeAllRanges();getSelection().addRange(r);var b=r.getBoundingClientRect();[b.x+10,b.y+b.height/2]"
    let sm = await menuAt(selJS, "selection")
    check("selection: selection item", has(sm, "Probe selection"))
    check("selection: %s replaced", has(sm, "Probe Sel “selected words”") || has(sm, "Probe Sel \"selected words\""), "\(titles(sm).filter { $0.hasPrefix("Probe Sel") })")
    if let i = await click(sm, "Probe selection"), let info = i["info"] as? [String: Any] {
      check("selection: onClicked selectionText", (info["selectionText"] as? String) == "selected words", "\(info)")
    } else { check("selection: onClicked", false) }

    _ = await eval(w, "getSelection().removeAllRanges(); 1")
    let em = await menuAt(center("#f"), "editable")
    check("editable: editable item", has(em, "Probe editable"))
    if let i = await click(em, "Probe editable"), let info = i["info"] as? [String: Any] {
      check("editable: onClicked editable", (info["editable"] as? Bool) == true, "\(info)")
    } else { check("editable: onClicked", false) }

    let fm = await menuAt(center("#fr"), "frame")
    check("frame: frame item", has(fm, "Probe frame"))
    if let i = await click(fm, "Probe frame"), let info = i["info"] as? [String: Any] {
      check("frame: onClicked frameUrl", (info["frameUrl"] as? String)?.hasSuffix("/frame") == true, "\(info)")
    } else { check("frame: onClicked", false) }
    DenWebView.menuOpened = nil

    // MARK: action (toolbar button) right-click
    if let a = ctx.action(for: rt.extensions.tab(tab)) { log("action.menuItems: " + dump({ let m = NSMenu(); a.menuItems.forEach(m.addItem); return m }()).joined(separator: " ; ")) }
    log("menuItems(for: tab): " + ctx.menuItems(for: rt.extensions.tab(tab)).map(\.title).joined(separator: " ; "))
    if let m = rt.extensions.ui.actionMenu(extId) {
      log("pill right-click menu: " + dump(m).joined(separator: " ; "))
      check("action: right-click menu has the action item", find(m, "Probe action") != nil)
    } else { check("action: right-click menu", false) }

    // MARK: the tab's right-click menu in the sidebar (`contexts: ["tab"]`)
    func rowView(_ v: NSView) -> NodeView? {
      if let n = v as? NodeView, n.node.str("type") == "tabRow", n.nodeId == tab { return n }
      return v.subviews.lazy.compactMap(rowView).first
    }
    // A right-click on the row asks the tabs plugin for its menu (`ui.menu`), shown at the pointer.
    // It pops up on a later turn (a main-queue block that tracks until closed): close it as soon
    // as it shows.
    let closer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
      nonisolated(unsafe) let m = n.object as? NSMenu
      RunLoop.main.perform(inModes: [.eventTracking, .common]) { MainActor.assumeIsolated { m?.cancelTracking() } }
    }
    rt.ui.lastMenu = nil
    if rowView(rt.ui.sidebarView) != nil { rt.plugins.emit("ui.action", ["id": .string(tab), "action": "contextMenu"]) } else { log("no tab row view") }
    _ = await wait(5) { rt.ui.lastMenu != nil }
    try? await Task.sleep(for: .milliseconds(500))
    if let m = rt.ui.lastMenu {
      log("tab row menu: " + dump(m).joined(separator: " ; "))
      check("tab row: tab item", find(m, "Probe tab") != nil)
      if let it = find(m, "Probe tab"), let parent = it.menu {
        _ = await eval(w, "delete document.documentElement.dataset.clicked; 1")
        parent.performActionForItem(at: parent.index(of: it))
        _ = await wait(8) { (await eval(w, "document.documentElement.dataset.clicked || ''") as? String ?? "") != "" }
        let s = await eval(w, "document.documentElement.dataset.clicked || ''") as? String ?? ""
        log("clicked Probe tab: \(s)")
        check("tab row: onClicked with the tab", s.contains("\"menuItemId\":\"tab\"") && s.contains("/p"))
      }
    } else { check("tab row menu", false, "no row/menu") }

    NotificationCenter.default.removeObserver(closer)

    // MARK: the Extensions menu's own items (key equivalents through the menu bar)
    await reset()
    let viaMenu = NSApp.mainMenu?.performKeyEquivalent(with: alt) ?? false
    log("info: ⌥⇧Y offered to the menu bar alone (no window first): handled=\(viaMenu) fired=\(await fired("probe-alt"))")
    await reset()
    if let m = rt.extensions.commandsMenu, let it = find(m, "Menu Probe: Probe No Key") { m.performActionForItem(at: m.index(of: it)) }
    check("Probe No Key from the Extensions menu", await fired("probe-nokey"))

    // MARK: disable / enable / uninstall update the Extensions menu
    rt.call("webext", "setEnabled", ["id": .string(extId), "enabled": false])
    check("disabled: Extensions menu gone", await wait(10) { rt.extensions.commandsMenu == nil && !(NSApp.mainMenu?.items.contains { $0.title == "Extensions" } ?? false) })
    rt.call("webext", "setEnabled", ["id": .string(extId), "enabled": true])
    check("enabled: Extensions menu back", await wait(30) { rt.extensions.commandsMenu.map { find($0, "Menu Probe: Probe Alt") != nil } ?? false })
    rt.call("webext", "uninstall", ["id": .string(extId)])
    check("uninstalled: Extensions menu gone", await wait(10) { rt.extensions.commandsMenu == nil })

    // MARK: real store extensions
    let store = (ProcessInfo.processInfo.environment["DEN_EXT_STORE"] ?? "").split(separator: ",").map(String.init)
    for id in store {
      let ok2 = await ExtensionScenarios.installFromStorePage(rt, "https://chromewebstore.google.com/detail/x/\(id)", id: id, snapshot: nil, promptSnapshot: nil)
      guard ok2, let (eid, c) = rt.extensions.contexts.first(where: { $0.key == id || rt.extensions.registry.item($0.key)?.storeId == id }).map({ ($0.key, $0.value) }) else { log("store \(id) install failed"); continue }
      do { try await c.loadBackgroundContent() } catch { log("store \(id) bg \(error)") }
      try? await Task.sleep(for: .seconds(3))
      logOwners(rt)
      log("store \(c.webExtension.displayName ?? id) commands=" + c.commands.map { "\($0.id)|\($0.title)|\($0.activationKey ?? "nil")|\($0.modifierFlags.rawValue >> 16)" }.joined(separator: " ; "))
      if let m = rt.extensions.commandsMenu { log("store Extensions menu: " + dump(m).joined(separator: " ; ")) }
      log("store contexts=\(rt.extensions.contexts.mapValues { $0.commands.count }) bar=\(NSApp.mainMenu?.items.filter { $0.title == "Extensions" }.map { ($0.submenu === rt.extensions.commandsMenu, $0.submenu?.items.count ?? -1) } ?? [])")
      rt.extensions.syncCommands()
      if let m = rt.extensions.commandsMenu { log("store Extensions menu after sync: n=\(m.numberOfItems) " + m.items.map { "\($0.title)|\($0.keyEquivalentModifierMask.rawValue >> 16):\($0.keyEquivalent)" }.joined(separator: " ; ")) }
      _ = await ExtensionScenarios.navigate(rt, mock.base + "/p")
      ExtensionScenarios.tab = tab
      rt.call("tabs", "select", ["id": .string(tab)])
      _ = await wait(10) { rt.webviews.record(tab)?.webView?.window != nil }
      try? await Task.sleep(for: .milliseconds(500))
      guard let sw = rt.webviews.record(tab)?.webView as? DenWebView else { continue }
      log("store \(id): tab web view replaced=\(sw !== w) url=\(sw.url?.absoluteString ?? "nil") window=\(sw.window != nil)")
      if id == "eimadpbcbfnmbkopoojfekhnkhdbieeh" {
        // Dark Reader's ⌥⇧D ("Toggle extension") with the page focused: its styles go or come.
        let styles = "document.querySelectorAll('style.darkreader').length"
        _ = await wait(20) { (await eval(sw, styles) as? Int ?? 0) > 0 }
        let before = await eval(sw, styles) as? Int ?? -1
        win.makeFirstResponder(sw)
        NSApp.sendEvent(key("Î", "D", 2, [.option, .shift], win)!)
        let changed = await wait(20) { (await eval(sw, styles) as? Int ?? -1) != before }
        check("Dark Reader ⌥⇧D toggles it on the page", changed, "darkreader styles \(before) -> \(await eval(sw, styles) ?? "?")")
      }
      for (js, label) in [("[700,500]", "page"), (selJS, "selection"), (center("#l"), "link")] {
        log("store \(id) \(label) menu: " + ((await storeMenu(sw, js)).map { dump($0).joined(separator: " ; ") } ?? "none"))
      }
      if let m = rt.extensions.ui.actionMenu(eid) { log("store \(id) pill right-click: " + dump(m).joined(separator: " ; ")) }
    }

    log("result ok=\(ok)")
    fflush(stdout)
    exit(ok ? 0 : 1)
  }
}
#endif
