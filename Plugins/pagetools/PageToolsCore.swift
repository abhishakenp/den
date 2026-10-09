// The `pagetools` plugin: reader (with read aloud), on-device page translation, capture, Zap,
// and "Copy Link to Highlight" (docs/plugin-services.md#pagetools). Zoom (remembered per site) is
// the host's page actions (webviews.zoom, the View menu).
//
// All of it is composed from generic host blocks: `webviews.inject` runs this plugin's scripts
// (resources/) in a page, in its own isolated world; `webviews.message` brings the page UI's
// clicks back; `webviews.snapshot` captures; `webviews.setContentRules` hides zapped elements;
// `webviews.setMenu` adds the context-menu item; `speech` and `translate` do the on-device work.
//
// Cost: at start it only binds keys, registers commands and the menu item, and (when some site
// has zapped elements) sets the content rules. Scripts are injected when a feature is used,
// except the small readability check, which runs once after each load of the page you're on.

#if !hasFeature(Embedded)
  import CordisValue
#endif

final class PageToolsCore {
  static let ns = "pagetools"
  static let id = "pagetools"
  static let speechRates: [Double] = [0.8, 1, 1.25, 1.5, 2]
  static let translateBatch = 120
  static let firstBatch = 30  // the first answer comes back fast: what's on screen

  struct Probe {
    var url: String
    var readable: Bool
    var lang: String
    var translatable: Bool
  }

  /// A page translation in progress: the page's text, sent to `translate.run` in batches.
  struct Translation {
    var webview: String
    var texts: [String]
    var order: [Int]  // node indexes, on-screen text first
    var title: String
    var from: String
    var fromName: String
    var to: String
    var next: Int
  }

  let env: PluginEnv

  // Settings (storage ns "pagetools")
  var font = "serif"  // reader font: serif | sans
  var size: Int64 = 19  // reader text size (px)
  var rate: Double = 1  // read-aloud speed
  var readerSites: [String] = []  // "Always use Reader on this site"
  var zaps: [String: [String]] = [:]  // host -> hidden CSS selectors
  var captureDest = "copy"  // copy | save
  var captureFolder = ""  // "" = Downloads
  var voiceLast: VoiceRef?  // read-aloud voice picked last (ReaderVoices.swift)
  var voiceLangs: [String: VoiceRef] = [:]  // base language -> its voice
  var voiceLangNames: [String: String] = [:]  // base language -> its name ("French")

  // Runtime
  var probes: [String: Probe] = [:]  // webview -> last probe
  var probing: Set<String> = []
  var readerOpen: Set<String> = []
  var translated: [String: String] = [:]  // webview -> source language name
  var translation: Translation?
  var pageVoice: [String: VoiceRef] = [:]  // webview -> a voice picked for that page only
  var speaking: String?  // webview being read aloud
  var speechState = "stopped"
  var hosts: [String: String] = [:]  // webview -> host of its current page
  var pages: [String: String] = [:]  // webview -> URL without fragment
  var capturing: Set<String> = []
  var pending: [String: String] = [:]  // inject request -> what it was for
  var nextRequest: Int64 = 1
  var userLang = ""
  var commandsRegistered = false
  var settingsRegistered = false
  var started = false
  var registerAttempts = 0

  init(env: PluginEnv) { self.env = env }

  // MARK: - Lifecycle

  /// Nothing is needed before the first window: keys, menu item, rules and commands are set up a
  /// moment after launch (`startNow` for tests).
  func start() {
    env.timer(Self.startDelayMs, false) { [self] in startNow() }
  }

  static let startDelayMs: UInt64 = 1500

  /// The page context menu's items (`webviews.setMenu`): Copy Link to Highlight on selected
  /// text; Translate Page and Zap Elements on the page itself (after View Page Source).
  static let menuItems: [Value] = [
    ["id": "pagetools.highlight", "title": "Copy Link to Highlight", "when": "selection", "icon": "sf:link"],
    ["id": "pagetools.translate", "title": "Translate Page", "when": "page", "icon": "sf:translate"],
    ["id": "pagetools.zap", "title": "Zap Elements…", "when": "page", "icon": "sf:bolt"],
  ]

  func startNow() {
    guard !started else { return }
    started = true
    load()
    bindKeys()
    env.call("webviews", "setMenu", ["plugin": .string(Self.id), "items": .array(Self.menuItems)])
    if !zaps.isEmpty { syncZapRules() }
    subscribe()
    registerCommands()
    registerSettings()
    // The tab restored at launch may have loaded already: check it now, since the events for it
    // came before we listened.
    if let w = focused() {
      let url = env.call("webviews", "get", ["id": .string(w)]).s("url")
      if !url.isEmpty { urlChanged(w, url) }
      selectedChanged(w)
    }
  }

  func stop() {
    registerAttempts = Int.max / 2
    if speaking != nil { env.call("speech", "stop") }
    env.call("webviews", "setMenu", ["plugin": .string(Self.id), "items": []])
    env.call("settings", "unregister", ["id": .string(Self.ns)])
    for c in ["cmd+ctrl+r", "cmd+shift+2"] { env.call("keys", "unbind", ["chord": .string(c)]) }
    for w in Array(probes.keys) { env.call("tabs", "pillButtons", ["webview": .string(w), "owner": .string(Self.id), "buttons": []]) }
  }

  func load() {
    let s = env.call("storage", "get", ["ns": .string(Self.ns), "key": "reader"])
    if let f = s["font"].string { font = f }
    if let v = s["size"].int { size = v }
    if let v = s["rate"].double { rate = v }
    readerSites = env.call("storage", "get", ["ns": .string(Self.ns), "key": "readerSites"]).array?.compactMap { $0.string } ?? []
    for (k, v) in env.call("storage", "get", ["ns": .string(Self.ns), "key": "zaps"]).objectPairs {
      let list = v.array?.compactMap { $0.string } ?? []
      if !list.isEmpty { zaps[k] = list }
    }
    loadVoices()
  }

  /// Capture settings are read when a capture is taken (nothing to load before).
  func loadCapture() {
    let c = env.call("storage", "get", ["ns": .string(Self.ns), "key": "capture"])
    if let d = c["dest"].string { captureDest = d }
    if let f = c["folder"].string { captureFolder = f }
  }

  func save(_ key: String, _ value: Value) { env.call("storage", "set", ["ns": .string(Self.ns), "key": .string(key), "value": value]) }

  func saveReader() {
    save("reader", ["font": .string(font), "size": .int(size), "rate": .double(rate)])
    for (k, v) in [("font", Value.string(font)), ("size", .int(size)), ("rate", .double(rate))] {
      env.call("settings", "set", ["id": .string(Self.ns), "key": .string(k), "value": v])
    }
  }

  // MARK: - Settings

  /// Settings > Reading (the host `settings` service; values in storage ns `pagetools`, `prefs`,
  /// mirrored into this plugin's own keys). Registering only stores the section until Settings opens.
  func registerSettings() {
    loadCapture()
    let rates: [Value] = [["value": 0.8, "title": "0.8×"], ["value": 1.0, "title": "1×"], ["value": 1.25, "title": "1.25×"],
                          ["value": 1.5, "title": "1.5×"], ["value": 2.0, "title": "2×"]]
    var sites: [Value] = []
    for h in readerSites { sites.append(["id": .string(h), "title": .string(h), "icon": "sf:doc.plaintext", "buttons": [["id": "remove", "title": "Remove"]]]) }
    var zapped: [Value] = []
    for (h, sels) in zaps {
      zapped.append(["id": .string(h), "title": .string(h), "subtitle": .string(String(sels.count) + (sels.count == 1 ? " element hidden" : " elements hidden")),
                     "icon": "sf:bolt", "buttons": [["id": "clear", "title": "Show All"]]])
    }
    let r = env.call("settings", "register", [
      "id": .string(Self.ns), "title": "Reading", "icon": "sf:doc.plaintext", "order": 45,
      "controls": [
        ["key": "font", "type": "choice", "title": "Reader font", "options": [["value": "serif", "title": "Serif"], ["value": "sans", "title": "Sans serif"]],
         "default": .string(font)],
        ["key": "size", "type": "number", "title": "Reader text size", "min": 14, "max": 30, "step": 2, "unit": "px", "default": .int(size)],
        ["key": "rate", "type": "choice", "title": "Read-aloud speed", "options": .array(rates), "default": .double(rate)],
        ["key": "voices", "type": "list", "title": "Read-aloud voices", "items": .array(voiceSettingsItems()),
         "empty": "Your Mac’s voice for each language. Pick another from the voice button next to Listen."],
        ["key": "readerSites", "type": "list", "title": "Always open in Reader", "items": .array(sites),
         "empty": "No sites yet. Use “Always” in the reader’s toolbar."],
        ["key": "captureDest", "type": "choice", "title": "Captures (⇧⌘2)", "subtitle": "Region, element, visible area or full page.",
         "options": [["value": "copy", "title": "Copy to the clipboard"], ["value": "save", "title": "Save as a PNG file"]], "default": .string(captureDest)],
        ["key": "captureFolder", "type": "info", "title": "Save captures in", "value": .string(captureFolder.isEmpty ? "Downloads" : captureFolder),
         "buttons": [["id": "choose", "title": "Choose…"], ["id": "downloads", "title": "Use Downloads"]]],
        ["key": "zaps", "type": "list", "title": "Zapped elements", "items": .array(zapped), "empty": "Nothing zapped yet. Use “Zap Elements” from the command bar."],
      ],
    ])
    guard !r.isErr, !settingsRegistered else { return }
    settingsRegistered = true
    let v = env.call("settings", "get", ["id": .string(Self.ns)])
    for k in ["font", "size", "rate", "captureDest"] where !v[k].isNull { applySetting(k, v[k]) }
    env.on("settings.changed") { [self] v in if v.s("id") == Self.ns { applySetting(v.s("key"), v["value"]) } }
    env.on("settings.action") { [self] v in
      guard v.s("id") == Self.ns else { return }
      switch (v.s("key"), v.s("button")) {
      case ("voices", "forget"):
        voiceLangs[v.s("item")] = nil
        if let l = voiceLast, Self.baseLang(l.lang) == v.s("item") { voiceLast = nil }
        saveVoices()
      case ("readerSites", "remove"):
        readerSites.removeAll { $0 == v.s("item") }
        save("readerSites", .array(readerSites.map { .string($0) }))
        registerSettings()
      case ("zaps", "clear"):
        zaps[v.s("item")] = nil
        saveZaps()
        syncZapRules()
        registerSettings()
      case ("captureFolder", "choose"):
        env.call("app", "chooseFolder", ["request": "pagetools.folder", "message": "Where should den save captures?"])
      case ("captureFolder", "downloads"):
        captureFolder = ""
        save("capture", ["dest": .string(captureDest), "folder": ""])
        registerSettings()
      default: break
      }
    }
  }

  func applySetting(_ key: String, _ v: Value) {
    switch key {
    case "font": if let f = v.string, f != font { font = f; save("reader", ["font": .string(font), "size": .int(size), "rate": .double(rate)]) }
    case "size": if let s = v.int, s != size { size = s; save("reader", ["font": .string(font), "size": .int(size), "rate": .double(rate)]) }
    case "rate": if let r = v.double, r != rate { rate = r; save("reader", ["font": .string(font), "size": .int(size), "rate": .double(rate)]) }
    case "captureDest":
      if let d = v.string {
        loadCapture()
        captureDest = d
        save("capture", ["dest": .string(d), "folder": .string(captureFolder)])
      }
    default: break
    }
  }

  func bindKeys() {
    let keys: [(String, String, String)] = [
      ("cmd+ctrl+r", "pagetools.key.reader", "Reader"),
      ("cmd+shift+2", "pagetools.key.capture", "Capture…"),
    ]
    for (chord, event, title) in keys {
      env.call("keys", "bind", ["chord": .string(chord), "event": .string(event), "title": .string(title), "menu": "View"])
    }
  }

  func subscribe() {
    env.on("pagetools.key.reader") { [self] _ in run("pagetools.reader") }
    env.on("pagetools.key.capture") { [self] _ in run("pagetools.capture.region") }
    env.on("commands.run") { [self] v in
      let id = v.s("id")
      if Text.hasPrefix(id, "pagetools.") { run(id) }
    }
    env.on("webviews.url") { [self] v in urlChanged(v.s("id"), v.s("url")) }
    env.on("webviews.progress") { [self] v in
      if v["loading"] == false, v.s("id") == focused() { probe(v.s("id")) }
    }
    env.on("tabs.selected") { [self] v in selectedChanged(v.s("id")) }
    env.on("content.focus") { [self] v in selectedChanged(v.s("id")) }
    env.on("webviews.closed") { [self] v in forget(v.s("id")) }
    env.on("webviews.detached") { [self] v in forget(v.s("id")) }
    env.on("webviews.injectResult") { [self] v in
      guard v.s("plugin") == Self.id, let what = pending.removeValue(forKey: v.s("request")) else { return }
      injected(what, v.s("webview"), v)
    }
    env.on("webviews.message") { [self] v in
      if v.s("plugin") == Self.id { message(v.s("webview"), v["value"]) }
    }
    env.on("webviews.menu") { [self] v in
      guard v.s("plugin") == Self.id else { return }
      let w = v.s("webview")
      switch v.s("id") {
      case "pagetools.highlight": highlight(w)
      case "pagetools.translate": if translated[w] != nil { showOriginal(w) } else { translate(w) }
      case "pagetools.zap": zap(w)
      default: break
      }
    }
    env.on("webviews.snapshot") { [self] v in
      if capturing.contains(v.s("id")), !v["bytes"].isNull || v["ok"] == false { captured(v) }
    }
    env.on("speech.progress") { [self] v in
      guard let w = speaking, v.s("request") == "pagetools:" + w else { return }
      script(w, "mark", "return window.__denReader && window.__denReader.mark(i)", ["i": .int(v.i("index"))])
    }
    env.on("speech.state") { [self] v in
      guard let w = speaking, v.s("request") == "pagetools:" + w else { return }
      speechState = v.s("state")
      let playing = speechState == "playing"
      script(w, "state", "return window.__denReader && window.__denReader.state(s)", ["s": ["playing": .bool(playing), "rate": .double(rate)]])
      if speechState == "done" || speechState == "stopped" {
        script(w, "mark", "return window.__denReader && window.__denReader.mark(-1)")
        speaking = nil
      }
    }
    env.on("translate.result") { [self] v in translatedBatch(v) }
    env.on("app.saved") { [self] v in
      if v.s("request") == "pagetools.qr", !v.s("path").isEmpty { toast("Saved " + lastComponent(v.s("path")), icon: "sf:qrcode") }
    }
    env.on("app.folder") { [self] v in
      guard v.s("request") == "pagetools.folder" else { return }
      let path = v.s("path")
      guard !path.isEmpty else { return }
      captureFolder = path
      captureDest = "save"
      save("capture", ["dest": "save", "folder": .string(path)])
      env.call("settings", "set", ["id": .string(Self.ns), "key": "captureDest", "value": "save"])
      if settingsRegistered { registerSettings() }
      toast("Captures will be saved to " + lastComponent(path), icon: "sf:folder")
    }
    env.on("ui.action") { [self] v in
      switch v.s("id") {
      case "pagetools.pill.reader": run("pagetools.reader")
      case "pagetools.pill.translate": run(translated[focused() ?? ""] != nil ? "pagetools.showOriginal" : "pagetools.translate")
      case Self.qrPanel: if v.s("action") == "dismiss" { closeQR() }
      case "pagetools.qr.copy": if v.s("action") == "click" { copyQR() }
      case "pagetools.qr.save": if v.s("action") == "click" { saveQR() }
      default: break
      }
    }
  }

  // MARK: - Commands

  static let commands: [(String, String, String, [Value], String)] = [
    ("pagetools.reader", "Toggle Reader", "sf:doc.plaintext", ["reader", "read", "article", "safari"], "⌃⌘R"),
    ("pagetools.readerAlways", "Always Use Reader on This Site", "sf:doc.plaintext.fill", ["reader", "site", "always", "auto"], ""),
    ("pagetools.readAloud", "Read Aloud", "sf:speaker.wave.2", ["speak", "listen", "tts", "voice", "reader"], ""),
    ("pagetools.voice", "Choose Read-Aloud Voice…", "sf:person.wave.2", ["voice", "speech", "listen", "tts", "reader", "siri"], ""),
    ("pagetools.translate", "Translate Page", "sf:translate", ["translate", "language", "translation"], ""),
    ("pagetools.showOriginal", "Show Original Page", "sf:arrow.uturn.backward", ["translate", "original", "untranslate"], ""),
    ("pagetools.capture.region", "Capture Region", "sf:camera.viewfinder", ["capture", "screenshot", "region", "area"], "⇧⌘2"),
    ("pagetools.capture.element", "Capture Element", "sf:square.dashed", ["capture", "screenshot", "element"], ""),
    ("pagetools.capture.visible", "Capture Visible Area", "sf:rectangle.dashed", ["capture", "screenshot", "visible", "window"], ""),
    ("pagetools.capture.full", "Capture Full Page", "sf:doc.richtext", ["capture", "screenshot", "full", "page", "long"], ""),
    ("pagetools.capture.toClipboard", "Copy Captures to Clipboard", "sf:doc.on.clipboard", ["capture", "clipboard", "copy", "setting"], ""),
    ("pagetools.capture.toFolder", "Save Captures to Folder…", "sf:folder", ["capture", "save", "folder", "downloads", "setting"], ""),
    ("pagetools.zap", "Zap Elements", "sf:bolt", ["zap", "hide", "element", "boost", "remove"], ""),
    ("pagetools.unstick", "Remove Sticky Headers", "sf:pin.slash", ["sticky", "header", "fixed", "banner", "zap"], ""),
    ("pagetools.zapClear", "Show Zapped Elements on This Site", "sf:bolt.slash", ["zap", "restore", "unhide", "reset"], ""),
    ("pagetools.highlight", "Copy Link to Highlight", "sf:link", ["highlight", "text fragment", "quote", "link", "selection"], ""),
    ("pagetools.share", "Share…", "sf:square.and.arrow.up", ["share", "airdrop", "messages", "send", "mail"], ""),
    ("pagetools.qrCode", "QR Code for This Page", "sf:qrcode", ["qr", "code", "phone", "share", "scan"], ""),
  ]

  /// `commands` is optional (plugin `commandbar`) and may load later: retry every 500 ms for 30 s.
  func registerCommands() {
    if tryRegister() { return }
    env.timer(500, false) { [self] in
      registerAttempts += 1
      if !tryRegister(), registerAttempts < 60 { registerCommands() }
    }
  }

  @discardableResult
  func tryRegister() -> Bool {
    if commandsRegistered { return true }
    for (id, title, icon, keywords, shortcut) in Self.commands {
      var args: Value = ["id": .string(id), "title": .string(title), "icon": .string(icon), "keywords": .array(keywords), "owner": .string(Self.id)]
      if !shortcut.isEmpty { args.put("shortcut", .string(shortcut)) }
      if env.call("commands", "register", args).isErr { return false }
    }
    commandsRegistered = true
    return true
  }

  func run(_ command: String) {
    guard let w = focused() else { return }
    switch command {
    case "pagetools.reader": readerOpen.contains(w) ? closeReader(w) : openReader(w)
    case "pagetools.readerAlways": toggleAlways(w)
    case "pagetools.readAloud":
      if !readerOpen.contains(w) {
        pendingSpeak = w
        openReader(w)
      } else { toggleSpeech(w) }
    case "pagetools.voice":
      if !readerOpen.contains(w) {
        pendingVoices = w
        openReader(w)
      } else { openVoices(w) }
    case "pagetools.translate": translate(w)
    case "pagetools.showOriginal": showOriginal(w)
    case "pagetools.capture.region": capture(w, "region")
    case "pagetools.capture.element": capture(w, "element")
    case "pagetools.capture.visible": capture(w, "visible")
    case "pagetools.capture.full": capture(w, "full")
    case "pagetools.capture.toClipboard":
      captureDest = "copy"
      save("capture", ["dest": "copy", "folder": .string(captureFolder)])
      env.call("settings", "set", ["id": .string(Self.ns), "key": "captureDest", "value": "copy"])
      toast("Captures will be copied to the clipboard", icon: "sf:doc.on.clipboard")
    case "pagetools.capture.toFolder":
      env.call("app", "chooseFolder", ["request": "pagetools.folder", "message": "Where should den save captures?"])
    case "pagetools.zap": zap(w)
    case "pagetools.unstick": unstick(w)
    case "pagetools.zapClear": clearZaps(w)
    case "pagetools.highlight": highlight(w)
    case "pagetools.share": share(w)
    case "pagetools.qrCode": showQR(w)
    default: break
    }
  }

  var pendingSpeak: String?
  var pendingVoices: String?

  // MARK: - Pages

  /// The web view the user is looking at (the focused pane).
  func focused() -> String? {
    let f = env.call("content", "get")["focus"].string ?? ""
    return f.isEmpty ? nil : f
  }

  func urlChanged(_ w: String, _ url: String) {
    let host = URLs.host(url)
    hosts[w] = host
    let page = Self.stripFragment(url)
    if pages[w] != page {
      pages[w] = page
      // A new page: the reader, translation and read-aloud of the old one are gone.
      readerOpen.remove(w)
      translated[w] = nil
      probes[w] = nil
      pageVoice[w] = nil
      if speaking == w { env.call("speech", "stop") }
      if translation?.webview == w { translation = nil }
      capturing.remove(w)
      updatePill(w)
    }
  }

  func selectedChanged(_ w: String) {
    guard !w.isEmpty else { return }
    if probes[w] == nil {
      let st = env.call("webviews", "get", ["id": .string(w)])
      if st["live"] == true, st["loading"] == false { probe(w) }
    }
    updatePill(w)
  }

  func forget(_ w: String) {
    probes[w] = nil
    pageVoice[w] = nil
    readerOpen.remove(w)
    translated[w] = nil
    pages[w] = nil
    if speaking == w { env.call("speech", "stop") }
  }

  /// After load, once per page: is it an article (Readability's check), and in which language?
  func probe(_ w: String) {
    let url = env.call("webviews", "get", ["id": .string(w)]).s("url")
    guard Text.hasPrefix(url, "http"), !probing.contains(w), probes[w]?.url != url else { return }
    probing.insert(w)
    inject(w, "probe", files: ["vendor/Readability-readerable.js"], global: "isProbablyReaderable", script: Self.probeScript)
  }

  static let probeScript = """
    var t = '', ps = document.querySelectorAll('p');
    for (var i = 0; i < ps.length && t.length < 1200; i++) t += ' ' + ps[i].textContent;
    if (t.replace(/\\s/g, '').length < 80 && document.body) t = document.body.innerText.slice(0, 1200);
    return { url: location.href, readable: typeof isProbablyReaderable === 'function' && document.body ? isProbablyReaderable(document) : false,
      sample: t.replace(/\\s+/g, ' ').trim().slice(0, 1200), lang: document.documentElement.lang || '' };
    """

  func probed(_ w: String, _ v: Value) {
    probing.remove(w)
    guard v["ok"] == true else { return }
    let r = v["value"]
    if userLang.isEmpty { userLang = env.call("translate", "userLanguage").s("lang") }
    let d = env.call("translate", "detect", ["text": r["sample"], "hint": r["lang"]])
    let lang = d.s("lang")
    probes[w] = Probe(url: r.s("url"), readable: r.b("readable"), lang: lang, translatable: !lang.isEmpty && !userLang.isEmpty && lang != userLang)
    if r.b("readable"), readerSites.contains(URLs.host(r.s("url"))), !readerOpen.contains(w) { openReader(w) }
    updatePill(w)
  }

  /// Buttons in the URL pill (through `tabs`): Reader when the page is readable, Translate when
  /// it's in another language.
  func updatePill(_ w: String) {
    var buttons: [Value] = []
    let p = probes[w]
    if p?.readable == true || readerOpen.contains(w) {
      buttons.append(["id": "pagetools.pill.reader", "icon": "sf:doc.plaintext", "tooltip": "Reader", "shortcutFor": "pagetools.key.reader", "shortcut": "ctrl+cmd+r", "active": .bool(readerOpen.contains(w))])
    }
    if p?.translatable == true || translated[w] != nil {
      buttons.append(["id": "pagetools.pill.translate", "icon": "sf:translate", "tooltip": .string(translated[w] != nil ? "Show Original" : "Translate Page"),
                      "active": .bool(translated[w] != nil)])
    }
    env.call("tabs", "pillButtons", ["webview": .string(w), "owner": .string(Self.id), "buttons": .array(buttons)])
  }

  /// Updates the translate pill with a progress percentage while translation is in flight.
  private func updatePillProgress(_ w: String, pct: Int) {
    let p = probes[w]
    guard p?.translatable == true else { return }
    let btn: Value = ["id": .string("pagetools.pill.translate"), "icon": .string("sf:translate.circle"),
                      "tooltip": .string("Translating… \(pct)%"), "active": .bool(true),
                      "progress": .int(Int64(pct))]
    env.call("tabs", "pillButtons", ["webview": .string(w), "owner": .string(Self.id), "buttons": .array([btn])])
  }

  // MARK: - Injection

  func inject(_ w: String, _ what: String, files: [String] = [], global: String = "", script: String = "", args: Value = .null) {
    let request = "pagetools-" + String(nextRequest)
    nextRequest += 1
    var a: Value = ["id": .string(w), "plugin": .string(Self.id), "request": .string(request),
                    "files": .array(files.map { .string($0) }), "global": .string(global), "script": .string(script)]
    if !args.isNull { a.put("args", args) }
    let r = env.call("webviews", "inject", a)
    if r.isErr {
      if what == "probe" { probing.remove(w) }
      return
    }
    pending[request] = what
  }

  /// A call into an already-loaded script (no answer needed unless `what` handles it).
  func script(_ w: String, _ what: String, _ body: String, _ args: Value = .null) { inject(w, what, script: body, args: args) }

  func injected(_ what: String, _ w: String, _ v: Value) {
    switch what {
    case "probe": probed(w, v)
    case "reader": readerOpened(w, v)
    case "sentences": sentences(w, v)
    case "collect": collected(w, v)
    case "highlight": highlighted(w, v)
    case "capture", "zap":
      if v["ok"] != true { toast("This page can't be changed", icon: "sf:exclamationmark.triangle") }
    default: break
    }
  }

  func message(_ w: String, _ m: Value) {
    let action = m.s("action")
    switch m.s("tool") {
    case "reader":
      switch action {
      case "close": closeReader(w)
      case "font":
        font = font == "serif" ? "sans" : "serif"
        saveReader()
        restyle(w)
      case "smaller", "larger":
        size = max(14, min(30, size + (action == "larger" ? 2 : -2)))
        saveReader()
        restyle(w)
      case "always": toggleAlways(w)
      case "speak": toggleSpeech(w)
      case "rate": cycleRate(w)
      case "voices", "pickVoice", "previewVoice", "systemVoice", "pinVoice", "moreVoices", "personalVoice": voiceMessage(w, action, m["value"])
      default: break
      }
    case "capture":
      switch action {
      case "shot":
        shoot(w, rect: m["value"]["rect"])
      case "visible", "full": capture(w, action)
      default: capturing.remove(w)
      }
    case "zap": zapped(w, m["value"], done: action == "done")
    default: break
    }
  }

  // MARK: - Reader

  func openReader(_ w: String) {
    let args: Value = ["o": ["vars": env.call("ui", "tokens"), "font": .string(font), "size": .int(size),
                             "state": ["always": .bool(readerSites.contains(hosts[w] ?? "")), "rate": .double(rate), "voice": .string(voiceLabel(w))]]]
    inject(w, "reader", files: ["vendor/Readability.js", "reader.js"], global: "__denReader", script: "return window.__denReader.open(o)", args: args)
  }

  func readerOpened(_ w: String, _ v: Value) {
    let r = v["value"]
    guard v["ok"] == true, r["ok"] == true else {
      pendingSpeak = nil
      pendingVoices = nil
      toast("This page can't be shown in Reader", icon: "sf:doc.plaintext")
      return
    }
    readerOpen.insert(w)
    updatePill(w)
    if pendingSpeak == w {
      pendingSpeak = nil
      toggleSpeech(w)
    }
    if pendingVoices == w {
      pendingVoices = nil
      openVoices(w)
    }
  }

  func restyle(_ w: String) {
    script(w, "style", "return window.__denReader && window.__denReader.style(o)", ["o": ["font": .string(font), "size": .int(size)]])
  }

  func closeReader(_ w: String) {
    if speaking == w { env.call("speech", "stop") }
    script(w, "close", "return window.__denReader ? window.__denReader.close() : true")
    readerOpen.remove(w)
    updatePill(w)
  }

  func toggleAlways(_ w: String) {
    let host = hosts[w] ?? URLs.host(env.call("webviews", "get", ["id": .string(w)]).s("url"))
    guard !host.isEmpty else { return }
    let on = !readerSites.contains(host)
    if on { readerSites.append(host) } else { readerSites.removeAll { $0 == host } }
    save("readerSites", .array(readerSites.map { .string($0) }))
    if settingsRegistered { registerSettings() }
    script(w, "state", "return window.__denReader && window.__denReader.state(s)", ["s": ["always": .bool(on)]])
    toast(on ? "Reader will open on " + host : "Reader won’t open automatically on " + host, icon: "sf:doc.plaintext")
    if on, !readerOpen.contains(w) { openReader(w) }
  }

  // MARK: - Read aloud

  func toggleSpeech(_ w: String) {
    if speaking == w {
      env.call("speech", speechState == "playing" ? "pause" : "resume")
      return
    }
    inject(w, "sentences", script: "return window.__denReader ? window.__denReader.sentences() : []")
  }

  func sentences(_ w: String, _ v: Value) {
    let list = v["value"].array ?? []
    guard !list.isEmpty else { return }
    if speaking != nil { env.call("speech", "stop") }
    speaking = w
    speechState = "playing"
    let lang = probes[w]?.lang ?? ""
    var a: Value = ["utterances": .array(list), "lang": .string(lang), "rate": .double(rate), "request": .string("pagetools:" + w)]
    voiceArgs(w, into: &a)
    env.call("speech", "speak", a)
  }

  func cycleRate(_ w: String) {
    var next = Self.speechRates[0]
    for r in Self.speechRates where r > rate + 0.01 {
      next = r
      break
    }
    rate = next
    saveReader()
    if speaking != nil { env.call("speech", "setRate", ["rate": .double(rate)]) }
    script(w, "state", "return window.__denReader && window.__denReader.state(s)", ["s": ["rate": .double(rate)]])
  }

  // MARK: - Translation

  func translate(_ w: String) {
    guard translation == nil else { return }
    inject(w, "collect", files: ["translate.js"], global: "__denTranslate", script: "return window.__denTranslate.collect(4000)")
  }

  /// Shows a persistent "Translating…" overlay so the user sees instant feedback.
  private func showTranslateOverlay(_ w: String) {
    script(w, "translateOverlay", "return window.__denTranslate.showOverlay()", [])
  }

  /// Hides the "Translating…" overlay.
  private func hideTranslateOverlay(_ w: String) {
    script(w, "translateOverlayHide", "return window.__denTranslate.hideOverlay()", [])
  }

  func collected(_ w: String, _ v: Value) {
    let texts = (v["value"]["texts"].array ?? []).map { $0.string ?? "" }
    var order = (v["value"]["order"].array ?? []).compactMap { $0.int.map { Int($0) } }
    if order.count != texts.count { order = Array(0..<texts.count) }
    guard !texts.isEmpty else { return toast("There’s no text to translate", icon: "sf:translate") }
    var sample = ""
    for t in texts where t.utf8.count > 20 {
      sample += t + " "
      if sample.utf8.count > 1500 { break }
    }
    if sample.isEmpty { for t in texts.prefix(50) { sample += t + " " } }
    let d = env.call("translate", "detect", ["text": .string(sample), "hint": .string(probes[w]?.lang ?? "")])
    if userLang.isEmpty { userLang = env.call("translate", "userLanguage").s("lang") }
    let from = d.s("lang")
    guard !from.isEmpty else { return toast("den can’t tell which language this page is in", icon: "sf:translate") }
    guard from != userLang else { return toast("This page is already in " + d.s("name"), icon: "sf:translate") }
    translation = Translation(webview: w, texts: texts, order: order, title: v["value"].s("title"), from: from, fromName: d.s("name"), to: userLang, next: 0)
    // Show persistent overlay + instant toast so the user sees translation started immediately.
    showTranslateOverlay(w)
    toast("Translating from " + d.s("name") + "…", icon: "sf:translate")
    nextBatch()
  }

  func nextBatch() {
    guard let t = translation else { return }
    let end = min(t.texts.count, t.next + (t.next == 0 ? Self.firstBatch : Self.translateBatch))
    var batch = t.order[t.next..<end].map { t.texts[$0] }
    // The page title rides along with the first batch.
    if t.next == 0 { batch.insert(t.title, at: 0) }
    env.call("translate", "run", ["texts": .array(batch.map { .string($0) }), "from": .string(t.from), "to": .string(t.to),
                                  "request": .string("pagetools:" + t.webview + ":" + String(t.next))])
  }

  func translatedBatch(_ v: Value) {
    guard var t = translation, v.s("request") == "pagetools:" + t.webview + ":" + String(t.next) else { return }
    guard v["ok"] == true else {
      translation = nil
      hideTranslateOverlay(t.webview)
      let e = v.s("error")
      if e == "notInstalled" { return toast("Translating " + t.fromName + " needs its language download", icon: "sf:arrow.down.circle") }
      if e == "unsupported" { return toast(t.fromName + " can’t be translated on this Mac", icon: "sf:translate") }
      return toast("Translation failed", icon: "sf:exclamationmark.triangle")
    }
    var out = v["texts"].array ?? []
    var title: Value = ""
    if t.next == 0, !out.isEmpty { title = out.removeFirst() }
    let at = t.order[t.next..<min(t.order.count, t.next + out.count)].map { Value.int(Int64($0)) }
    script(t.webview, "apply", "return window.__denTranslate.apply(s, t, n)", ["s": .array(at), "t": .array(out), "n": title])
    t.next += out.count
    let done = out.isEmpty || t.next >= t.texts.count
    if done {
      translation = nil
      hideTranslateOverlay(t.webview)
      translated[t.webview] = t.fromName
      updatePill(t.webview)
      toast("Translated from " + t.fromName, icon: "sf:translate")
    } else {
      // Update pill with progress while keeping overlay visible.
      let pct = min(99, Int(Double(t.next) / Double(t.texts.count) * 100))
      translation = t
      updatePillProgress(t.webview, pct: pct)
      nextBatch()
    }
  }

  func showOriginal(_ w: String) {
    guard translated[w] != nil else { return }
    hideTranslateOverlay(w)
    script(w, "restore", "return window.__denTranslate ? window.__denTranslate.restore() : false")
    translated[w] = nil
    updatePill(w)
  }

  // MARK: - Capture

  func capture(_ w: String, _ mode: String) {
    if mode == "visible" || mode == "full" {
      script(w, "captureStop", "return window.__denCapture ? window.__denCapture.stop() : true")
      shoot(w, rect: .null, full: mode == "full")
      return
    }
    inject(w, "capture", files: ["capture.js"], global: "__denCapture", script: "return window.__denCapture.start(m, o)",
           args: ["m": .string(mode), "o": ["vars": env.call("ui", "tokens")]])
  }

  func shoot(_ w: String, rect: Value, full: Bool = false) {
    loadCapture()
    capturing.insert(w)
    var a: Value = ["id": .string(w), "full": .bool(full)]
    if !rect.isNull { a.put("rect", rect) }
    if captureDest == "save" {
      a.put("folder", .string(captureFolder.isEmpty ? env.call("app", "paths").s("downloads") : captureFolder))
      a.put("name", .string(captureName()))
    } else {
      a.put("clipboard", true)
    }
    if env.call("webviews", "snapshot", a).isErr { capturing.remove(w) }
  }

  func captured(_ v: Value) {
    capturing.remove(v.s("id"))
    guard v["ok"] == true else { return toast("Capture failed", icon: "sf:exclamationmark.triangle") }
    if let path = v["path"].string {
      toast("Saved " + lastComponent(path), icon: "sf:camera.viewfinder")
    } else {
      let size = v.i("width") > 0 ? String(v.i("width")) + " × " + String(v.i("height")) + " px" : ""
      toast(Copied.text("image", size), icon: "sf:camera.viewfinder")
    }
  }

  /// "den Capture 2026-09-27 at 21.40.05.png" in local time, like macOS screenshots.
  func captureName() -> String {
    let c = env.call("schedule", "clock")
    var ms = c.i("ms", env.now())
    if c.isErr { ms = env.now() }
    let local = ms / 1000 + c.i("offsetMinutes") * 60
    let (y, mo, d) = Self.civil(local / 86400)
    let secs = ((local % 86400) + 86400) % 86400
    return "den Capture " + String(y) + "-" + Self.two(mo) + "-" + Self.two(d) + " at " + Self.two(secs / 3600) + "." + Self.two(secs / 60 % 60) + "." + Self.two(secs % 60) + ".png"
  }

  static func two(_ n: Int64) -> String { n < 10 ? "0" + String(n) : String(n) }

  /// Days since 1970-01-01 -> (year, month, day). Howard Hinnant's civil_from_days.
  static func civil(_ days: Int64) -> (Int64, Int64, Int64) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
  }

  // MARK: - Zap

  func zap(_ w: String) {
    let host = hosts[w] ?? ""
    inject(w, "zap", files: ["zap.js"], global: "__denZap", script: "return window.__denZap.start(o)",
           args: ["o": ["vars": env.call("ui", "tokens"), "selectors": .array((zaps[host] ?? []).map { .string($0) })]])
  }

  func unstick(_ w: String) {
    let host = hosts[w] ?? ""
    inject(w, "zap", files: ["zap.js"], global: "__denZap", script: "return window.__denZap.unstick(o)",
           args: ["o": ["selectors": .array((zaps[host] ?? []).map { .string($0) })]])
  }

  func zapped(_ w: String, _ v: Value, done: Bool) {
    let host = hosts[w] ?? ""
    guard !host.isEmpty else { return }
    let list = v["selectors"].array?.compactMap { $0.string } ?? []
    let before = zaps[host]?.count ?? 0
    if list.isEmpty { zaps[host] = nil } else { zaps[host] = list }
    saveZaps()
    // Rules apply from the next load; the page already shows the change. A restored element
    // stays hidden by the old rules until the page reloads.
    if done || list.count != before { syncZapRules() }
    if done, v.b("restored") { env.call("webviews", "reload", ["id": .string(w)]) }
    if !done, list.count > before, before == 0 || list.count - before > 1 {
      toast(String(list.count) + (list.count == 1 ? " element hidden on " : " elements hidden on ") + host, icon: "sf:bolt")
    }
  }

  func clearZaps(_ w: String) {
    let host = hosts[w] ?? ""
    guard zaps[host] != nil else { return toast("Nothing is zapped on " + (host.isEmpty ? "this site" : host), icon: "sf:bolt.slash") }
    zaps[host] = nil
    saveZaps()
    syncZapRules()
    env.call("webviews", "reload", ["id": .string(w)])
    toast("Showing everything on " + host + " again", icon: "sf:bolt.slash")
  }

  func saveZaps() {
    var pairs: [(String, Value)] = []
    for (k, v) in zaps { pairs.append((k, .array(v.map { .string($0) }))) }
    save("zaps", .object(pairs))
    if settingsRegistered { registerSettings() }
  }

  /// One `css-display-none` content rule per zapped selector, scoped to its site.
  func syncZapRules() {
    var rules: [Value] = []
    for (host, sels) in zaps {
      for s in sels {
        rules.append(["trigger": ["url-filter": ".*", "if-domain": [.string("*" + host)]], "action": ["type": "css-display-none", "selector": .string(s)]])
      }
    }
    env.call("webviews", "setContentRules", ["plugin": .string(Self.id), "rules": .array(rules)])
  }

  // MARK: - Copy Link to Highlight

  func highlight(_ w: String) {
    inject(w, "highlight", files: ["vendor/fragment-generation.js", "highlight.js"], global: "__denHighlight", script: "return window.__denHighlight.link()")
  }

  func highlighted(_ w: String, _ v: Value) {
    let r = v["value"]
    guard v["ok"] == true, r["ok"] == true, let url = r["url"].string else {
      return toast(r.s("error") == "no selection" ? "Select some text first" : "Couldn’t make a link to that text", icon: "sf:link")
    }
    env.call("app", "copy", ["text": .string(url)])
    let quote = r.s("text")
    toast(Copied.text("link to highlight", quote.isEmpty ? "" : "“" + Copied.clip(quote, max: 40) + "”"), icon: "sf:link")
  }

  // MARK: - Share and QR code

  static let qrPanel = "pagetools.qr"
  static let pillId = "tabs.url"
  var qr: (webview: String, url: String, path: String)?

  /// The page's web address, or nil (with a toast) when it has none worth sharing.
  func shareable(_ w: String) -> (String, String)? {
    let st = env.call("webviews", "get", ["id": .string(w)])
    let url = st.s("url")
    guard URLs.isWeb(url) else {
      toast("This page has no web address to share", icon: "sf:square.and.arrow.up")
      return nil
    }
    return (url, st.s("title"))
  }

  /// macOS's share sheet (AirDrop, Messages, Mail…) next to the URL pill.
  func share(_ w: String) {
    guard let page = shareable(w) else { return }
    let (url, title) = page
    env.call("app", "share", ["url": .string(url), "title": .string(title), "anchor": .string(Self.pillId)])
  }

  /// A QR code for the page in a popover beside the URL pill: scan it with a phone, copy or save it.
  func showQR(_ w: String) {
    guard let page = shareable(w) else { return }
    let url = page.0
    let r = env.call("app", "qrCode", ["text": .string(url)])
    guard let path = r["path"].string else { return toast("Couldn’t make a QR code", icon: "sf:exclamationmark.triangle") }
    qr = (w, url, path)
    env.call("ui", "set", ["slot": "popover", "tree": qrTree(url, path)])
  }

  func qrTree(_ url: String, _ path: String) -> Value {
    ["type": "panel", "id": .string(Self.qrPanel), "anchor": .string(Self.pillId), "width": 280, "icon": "sf:qrcode",
     "title": "Scan to open on your phone", "subtitle": .string(Copied.short(url, max: 40)),
     "children": [
       ["type": "image", "id": "pagetools.qr.image", "src": .string(path), "radius": 10, "aspect": 1],
       ["type": "buttonRow", "id": "pagetools.qr.buttons", "children": [
         ["type": "actionButton", "id": "pagetools.qr.copy", "title": "Copy Image", "style": "secondary"],
         ["type": "actionButton", "id": "pagetools.qr.save", "title": "Save…", "style": "primary"],
       ]],
     ]]
  }

  func closeQR() {
    qr = nil
    env.call("ui", "set", ["slot": "popover", "tree": .null])
  }

  func copyQR() {
    guard let q = qr else { return }
    if !env.call("app", "copyImage", ["path": .string(q.path)]).isErr {
      toast(Copied.text("QR code", Copied.short(q.url)), icon: "sf:qrcode")
    }
    closeQR()
  }

  func saveQR() {
    guard let q = qr else { return }
    closeQR()
    env.call("app", "saveFile", ["path": .string(q.path), "name": .string("QR code " + URLs.host(q.url) + ".png"), "request": "pagetools.qr"])
  }

  // MARK: - Helpers

  func toast(_ text: String, icon: String) {
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": .string(icon)]])
  }

  func lastComponent(_ path: String) -> String {
    var bytes = Array(path.utf8)
    while bytes.last == 47 { bytes.removeLast() }
    if let i = bytes.lastIndex(of: 47) { bytes = Array(bytes[(i + 1)...]) }
    return String(decoding: bytes, as: UTF8.self)
  }

  static func stripFragment(_ url: String) -> String {
    let b = Array(url.utf8)
    if let i = b.firstIndex(of: 35) { return String(decoding: b[..<i], as: UTF8.self) }
    return url
  }
}

extension Value {
  var objectPairs: [(String, Value)] {
    if case let .object(p) = self { return p }
    return []
  }
}
