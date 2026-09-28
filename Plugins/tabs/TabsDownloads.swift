#if !hasFeature(Embedded)
  import CordisValue
#endif

// The Library's Downloads section (⌥⌘L), download toasts and the auto-archive of old downloads.
// The files, progress and the list itself are the host's `downloads` service; this is only what
// they look like and when finished ones move under "Archived". Nothing here runs until a download
// starts or the section is opened.
extension TabsCore {
  static let downloadsSettingsId = "tabs.downloads"
  static let downloadToastId = "tabs.downloadToast"
  static let defaultDownloadsArchiveMs: Int64 = 24 * 3_600_000
  static let downloadsArchiveChoices: [(Int64, String)] = [
    (0, "Never"), (24 * 3_600_000, "After 1 day"), (7 * 86_400_000, "After 7 days"), (30 * 86_400_000, "After 30 days"),
  ]
  /// The Library's sections, with their shortcuts (shown on the tabs).
  static let librarySections: Value = [
    ["id": "archive", "title": "Archive", "keycap": "⌘Y"],
    ["id": "downloads", "title": "Downloads", "keycap": "⌥⌘L"],
  ]

  /// The host has a `downloads` service (an older host doesn't): a cheap call that reads nothing.
  var hasDownloads: Bool { !env.call("downloads", "summary").isErr }

  func startDownloads() {
    env.call("keys", "bind", ["chord": "cmd+opt+l", "event": "tabs.key.downloads", "title": "Downloads", "menu": "History"])
    env.on("tabs.key.downloads") { [self] _ in
      if libraryOpen && librarySection == "downloads" { closeLibrary() } else { openLibrary(section: "downloads") }
    }
    env.on("downloads.show") { [self] _ in openLibrary(section: "downloads") }
    env.on("downloads.changed") { [self] _ in if libraryOpen && librarySection == "downloads" { renderLibrary() } }
    env.on("downloads.started") { [self] v in
      toastDownload = v.s("id")
      env.call("ui", "set", ["slot": "toast", "tree": [
        "type": "toast", "id": .string(Self.downloadToastId), "text": .string("Downloading “" + v.s("name") + "”"),
        "icon": "sf:arrow.down.circle", "action": "Show", "duration": 4000,
      ]])
    }
    env.on("downloads.finished") { [self] v in
      toastDownload = v.s("id")
      let ok = v.b("ok")
      env.call("ui", "set", ["slot": "toast", "tree": [
        "type": "toast", "id": .string(Self.downloadToastId),
        "text": .string(ok ? "Downloaded “" + v.s("name") + "”" : "Couldn’t download “" + v.s("name") + "”"),
        "icon": .string(ok ? "sf:checkmark.circle.fill" : "sf:exclamationmark.triangle.fill"), "action": .string(ok ? "Show in Finder" : "Show"),
        "duration": 5000,
      ]])
      archiveOldDownloads()
    }
    registerDownloadsSettings()
  }

  func registerDownloadsSettings() {
    let options: [Value] = Self.downloadsArchiveChoices.map { ["value": .int($0.0), "title": .string($0.1)] }
    let r = env.call("settings", "register", [
      "id": .string(Self.downloadsSettingsId), "section": .string(Self.ns), "title": "Downloads", "order": 20,
      "controls": [["key": "archiveAfterMs", "type": "choice", "title": "Archive finished downloads",
                    "subtitle": "Finished downloads older than this move under Archived in Library ▸ Downloads (Option-Command-L). The files stay where they are.",
                    "options": .array(options),
                    "default": .int(Self.defaultDownloadsArchiveMs)]],
    ])
    guard !r.isErr else { return }
    let v = env.call("settings", "get", ["id": .string(Self.downloadsSettingsId), "key": "archiveAfterMs"])
    if let n = v.int ?? v.double.map({ Int64($0) }) { downloadsArchiveMs = max(0, n) }
    env.on("settings.changed") { [self] v in
      guard v.s("id") == Self.downloadsSettingsId, v.s("key") == "archiveAfterMs" else { return }
      if let n = v["value"].int ?? v["value"].double.map({ Int64($0) }) { downloadsArchiveMs = max(0, n) }
      archiveOldDownloads()
    }
  }

  /// Finished downloads past the setting move under "Archived" (checked when one finishes and
  /// when the section opens; no timer).
  func archiveOldDownloads() {
    guard downloadsArchiveMs > 0 else { return }
    env.call("downloads", "archive", ["before": .int(env.now() - downloadsArchiveMs)])
  }

  func downloadToastAction() {
    let id = toastDownload
    guard !id.isEmpty else { return }
    let d = env.call("downloads", "get", ["id": .string(id)])
    if d.s("state") == "done", d.b("exists") { env.call("downloads", "reveal", ["id": .string(id)]) } else { openLibrary(section: "downloads") }
  }

  // MARK: The section

  func downloadsTree() -> Value {
    let list = env.call("downloads", "list")
    if list.i("unseen") > 0 { env.call("downloads", "seen") }
    var running: [Value] = [], recent: [Value] = [], old: [Value] = []
    for d in list.a("items") {
      let st = d.s("state")
      if st == "downloading" || st == "paused" { running.append(downloadItem(d)) } else if d.b("archived") { old.append(downloadItem(d)) } else { recent.append(downloadItem(d)) }
    }
    let items = running + recent + old
    var tree: Value = [
      "type": "library", "id": .string(Self.libraryId), "title": "Downloads", "icon": "sf:arrow.down.circle",
      "placeholder": "Search downloads", "empty": "Files you download show up here. Drag one out to use it anywhere.",
      "sections": Self.librarySections, "section": "downloads", "items": .array(items),
    ]
    // Clear List only when something finished can go; the files stay.
    tree.put("clearTitle", .string(recent.isEmpty && old.isEmpty ? "" : "Clear List"))
    return tree
  }

  func downloadItem(_ d: Value) -> Value {
    let st = d.s("state"), path = d.s("path"), exists = d.b("exists")
    let got = d.i("received"), total = d.i("total")
    var it: Value = ["id": d["id"], "title": .string(d.sOpt("name") ?? "Download"), "url": d["url"], "pill": ""]
    it.put("icon", .string(path.isEmpty ? "sf:arrow.down.circle" : "file:" + path))
    let when = d.i("finished") > 0 ? d.i("finished") : d.i("started")
    it.put("closedAt", .int(when))
    var buttons: [Value] = []
    switch st {
    case "downloading":
      it.put("section", "In Progress")
      it.put("subtitle", .string(Self.progressText(got, total, rate: d.i("rate"))))
      it.put("progress", .double(total > 0 ? Double(got) / Double(total) : -1))
      buttons = [["id": "pause", "icon": "sf:pause.fill", "title": "Pause"], ["id": "cancel", "icon": "sf:xmark", "title": "Cancel"]]
    case "paused":
      it.put("section", "In Progress")
      it.put("subtitle", .string("Paused · " + Self.sizeText(got, total)))
      it.put("progress", .double(total > 0 ? Double(got) / Double(total) : 0))
      buttons = [["id": "resume", "icon": "sf:play.fill", "title": "Resume"], ["id": "cancel", "icon": "sf:xmark", "title": "Cancel"]]
    case "failed", "cancelled":
      it.put("subtitle", .string(st == "cancelled" ? "Cancelled · {time}" : "Failed: " + (d.sOpt("error") ?? "Download failed") + " · {time}"))
      it.put("dimmed", true)
      buttons = [["id": "retry", "icon": "sf:arrow.clockwise", "title": "Try Again"], ["id": "remove", "icon": "sf:xmark", "title": "Remove from List"]]
    default:
      if exists {
        it.put("subtitle", .string(Self.bytes(total > 0 ? total : got) + " · {time}"))
        it.put("file", .string(path))
        buttons = [["id": "reveal", "icon": "sf:magnifyingglass", "title": "Show in Finder"], ["id": "remove", "icon": "sf:xmark", "title": "Remove from List"]]
      } else {
        it.put("subtitle", "Moved or deleted · {time}")
        it.put("dimmed", true)
        buttons = [["id": "retry", "icon": "sf:arrow.clockwise", "title": "Download Again"], ["id": "remove", "icon": "sf:xmark", "title": "Remove from List"]]
      }
    }
    if d.b("archived"), st != "downloading", st != "paused" { it.put("section", "Archived") }
    it.put("buttons", .array(buttons))
    return it
  }

  func downloadsAction(_ action: String, _ value: Value) {
    switch action {
    case "restore":
      let id = value.s("item")
      let d = env.call("downloads", "get", ["id": .string(id)])
      guard d.s("state") == "done", d.b("exists") else { return }
      closeLibrary()
      env.call("downloads", "open", ["id": .string(id)])
    case "button":
      let b = value.s("button")
      guard ["pause", "resume", "cancel", "retry", "remove", "reveal"].contains(b) else { return }
      let r = env.call("downloads", b, ["id": value["item"]])
      if r.isErr { env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(Self.errorText(r.s("error"))), "icon": "sf:exclamationmark.triangle"]]) }
      renderLibrary()
    case "clear":
      let r = env.call("downloads", "clear")
      let n = r.i("removed")
      env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "icon": "sf:checkmark.circle.fill",
        "text": .string("Cleared " + String(n) + (n == 1 ? " download" : " downloads") + " from the list. The files stay in their folder.")]])
      renderLibrary()
    default:
      break
    }
  }

  static func errorText(_ e: String) -> String {
    if Text.contains(e, "moved or deleted") { return "That file was moved or deleted" }
    if Text.contains(e, "no web view") { return "Open a tab, then try again" }
    return "That didn’t work"
  }

  // MARK: Text (no Foundation in plugins)

  /// Finder-style sizes (1000-based): "812 bytes", "4.2 KB", "38 MB", "1.3 GB", "120 MB".
  static func bytes(_ n: Int64) -> String {
    if n < 1000 { return String(max(0, n)) + (n == 1 ? " byte" : " bytes") }
    let units = ["KB", "MB", "GB", "TB"]
    var div: Int64 = 1000
    var u = 0
    while u < units.count - 1, n >= div * 1000 {
      div *= 1000
      u += 1
    }
    let tenths = (n * 10 + div / 2) / div
    if tenths >= 1000 || tenths % 10 == 0 { return String((tenths + 5) / 10) + " " + units[u] }
    return String(tenths / 10) + "." + String(tenths % 10) + " " + units[u]
  }

  static func sizeText(_ got: Int64, _ total: Int64) -> String {
    total > 0 ? bytes(got) + " of " + bytes(total) : bytes(got)
  }

  /// "3.2 MB of 40 MB · 12 s left", "Starting…" before any byte arrives.
  static func progressText(_ got: Int64, _ total: Int64, rate: Int64) -> String {
    if got == 0 { return "Starting…" }
    var s = sizeText(got, total)
    if total > got, rate > 0 { s += " · " + timeLeft((total - got) / rate) }
    return s
  }

  static func timeLeft(_ secs: Int64) -> String {
    if secs < 60 { return String(max(1, secs)) + " s left" }
    if secs < 3600 { return String((secs + 30) / 60) + " min left" }
    return String(secs / 3600) + " h " + String((secs % 3600) / 60) + " min left"
  }
}
