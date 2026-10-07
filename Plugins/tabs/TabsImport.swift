// Bulk import into the sidebar (`tabs.importItems`, `tabs.removeImported`): what the `importer`
// plugin brings over from Arc, Chrome, Safari, Firefox, Zen and Dia (pinned tabs, folders,
// favorites, open tabs, bookmarks). See docs/plugin-services.md (`tabs`).
//
// - Idempotent: every imported item carries the importer's stable `key`; storage key `imported`
//   ({key: id}) maps it to the den tab or folder, so a second import reuses folders and skips tabs.
// - Undoable twice over: one checkpoint (⌃Z), and `removeImported {batch}` for the importer's
//   "Undo" (storage key `importBatches`: {batch: [id]}).
// - Fast: the tree is built straight into the lists (no `locate` per tab), web view records are
//   created lazily with the space's profile known up front, and it saves and renders once.

#if !hasFeature(Embedded)
  import CordisValue
#endif

extension TabsCore {
  struct ImportCount {
    var tabs = 0
    var folders = 0
    var existing = 0
    var skipped = 0
    var created: [String] = []
  }

  // MARK: - Keys (loaded lazily, never at launch)

  func loadImportKeys() {
    guard importKeys == nil else { return }
    var keys: [String: String] = [:]
    if case let .object(pairs) = env.call("storage", "get", ["ns": .string(Self.ns), "key": "imported"]) {
      for (k, v) in pairs { if let id = v.string { keys[k] = id } }
    }
    var batches: [String: [String]] = [:]
    if case let .object(pairs) = env.call("storage", "get", ["ns": .string(Self.ns), "key": "importBatches"]) {
      for (k, v) in pairs { batches[k] = (v.array ?? []).compactMap { $0.string } }
    }
    importKeys = keys
    importBatches = batches
  }

  /// Drops keys and batch members whose tab or folder is gone (closed, deleted, or undone with ⌃Z).
  func pruneImportKeys() {
    loadImportKeys()
    func alive(_ id: String) -> Bool { tabs[id] != nil || folders[id] != nil }
    importKeys = importKeys!.filter { alive($0.value) }
    var b: [String: [String]] = [:]
    for (k, ids) in importBatches! {
      let live = ids.filter { alive($0) }
      if !live.isEmpty { b[k] = live }
    }
    importBatches = b
  }

  func saveImportKeys() {
    var keys: [(String, Value)] = []
    for k in (importKeys ?? [:]).keys.sorted() { keys.append((k, .string(importKeys![k]!))) }
    var batches: [(String, Value)] = []
    for k in (importBatches ?? [:]).keys.sorted() { batches.append((k, .array(importBatches![k]!.map { .string($0) }))) }
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "imported", "value": .object(keys)])
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "importBatches", "value": .object(batches)])
  }

  // MARK: - importItems

  func importItems(_ args: Value) -> Value {
    let section = args.sOpt("section") ?? "pinned"
    guard section == "pinned" || section == "favorites" || section == "today" else { return .err("tabs: bad section " + section) }
    let batch = args.s("batch")
    guard !batch.isEmpty else { return .err("tabs: importItems needs a batch") }
    var sid = args.sOpt("spaceId") ?? currentSpace
    if section != "favorites" {
      if !spaceIds.contains(sid) { refreshSpaces() }
      guard spaceIds.contains(sid) else { return .err("tabs: no space '" + sid + "'") }
      if pinned[sid] == nil { pinned[sid] = [] }
      if today[sid] == nil { today[sid] = [] }
    } else {
      sid = ""
    }
    pruneImportKeys()
    checkpoint()
    var count = ImportCount()
    let kind = section == "favorites" ? "favorite" : section
    let prof = section == "favorites" ? "default" : profile(sid)
    let items = args.a("items")

    let top = args["folder"]
    if section != "favorites", !top.isNull, !top.s("key").isEmpty {
      let fid = importFolder(top, space: sid, kind: kind, profile: prof, batch: batch, count: &count)
      if count.created.contains(fid) {
        // A new top folder: at the end of the pinned tabs, or at the top of Today (a group).
        if section == "pinned" { pinned[sid]!.append(fid) } else { today[sid]!.insert(fid, at: 0) }
      }
      var children = folders[fid]?.children ?? []
      importNodes(items, into: &children, space: sid, kind: kind, profile: prof, batch: batch, count: &count)
      folders[fid]?.children = children
    } else if section == "favorites" {
      var list = favorites
      importNodes(items, into: &list, space: sid, kind: kind, profile: prof, batch: batch, count: &count)
      favorites = list
    } else {
      var list = section == "pinned" ? pinned[sid]! : today[sid]!
      importNodes(items, into: &list, space: sid, kind: kind, profile: prof, batch: batch, count: &count)
      if section == "pinned" { pinned[sid] = list } else { today[sid] = list }
    }

    if count.created.isEmpty {
      undoStack.removeLast()  // nothing changed: no empty undo step
    } else {
      importBatches![batch, default: []] += count.created
      saveImportKeys()
      save()
      renderAll()
      env.emit("tabs.changed", ["spaceId": section == "favorites" ? .null : .string(sid)])
    }
    return ["tabs": .int(Int64(count.tabs)), "folders": .int(Int64(count.folders)), "existing": .int(Int64(count.existing)), "skipped": .int(Int64(count.skipped))]
  }

  /// The folder for `node` (reused by key, else created with no place yet: the caller places it).
  func importFolder(_ node: Value, space sid: String, kind: String, profile prof: String, batch: String, count: inout ImportCount) -> String {
    let key = node.s("key")
    if let id = importKeys![key], folders[id] != nil { return id }
    let fid = newId("folder-")
    let title = node.sOpt("title") ?? "Imported"
    folders[fid] = Folder(id: fid, spaceId: sid, title: title, open: node.b("open", false), children: [])
    importKeys![key] = fid
    count.folders += 1
    count.created.append(fid)
    return fid
  }

  /// Appends `nodes` to `list` (a section or a folder's children), depth first.
  func importNodes(_ nodes: [Value], into list: inout [String], space sid: String, kind: String, profile prof: String, batch: String, count: inout ImportCount) {
    for n in nodes {
      if n.b("folder") {
        if kind == "favorite" {
          // Favorites hold no folders: their tabs join the grid.
          importNodes(n.a("children"), into: &list, space: sid, kind: kind, profile: prof, batch: batch, count: &count)
          continue
        }
        guard !n.s("key").isEmpty else { count.skipped += 1; continue }
        let fid = importFolder(n, space: sid, kind: kind, profile: prof, batch: batch, count: &count)
        var children = folders[fid]?.children ?? []
        importNodes(n.a("children"), into: &children, space: sid, kind: kind, profile: prof, batch: batch, count: &count)
        folders[fid]?.children = children
        if count.created.contains(fid) { list.append(fid) }
        continue
      }
      let url = n.s("url"), key = n.s("key")
      guard URLs.isWeb(url), !key.isEmpty else { count.skipped += 1; continue }
      if let id = importKeys![key], tabs[id] != nil { count.existing += 1; continue }
      if kind == "favorite" && list.count >= Self.maxFavorites { count.skipped += 1; continue }
      let id = newId("tab-")
      var t = Tab(id: id, title: n.sOpt("title") ?? URLs.title(url), url: url, pinnedUrl: kind == "today" ? nil : url, lastActive: env.now())
      if let f = n.sOpt("favicon"), URLs.usable(f) { t.favicon = f }
      tabs[id] = t
      // A lazy record: no WKWebView, nothing loads until the tab is shown.
      env.call("webviews", "create", ["id": .string(id), "url": .string(url), "profile": .string(prof)])
      list.append(id)
      importKeys![key] = id
      count.tabs += 1
      count.created.append(id)
    }
  }

  // MARK: - removeImported

  func removeImported(_ batch: String) -> Value {
    pruneImportKeys()
    guard let created = importBatches![batch], !created.isEmpty else { return ["removed": 0] }
    let gone = Set(created)
    checkpoint()
    // Removed folders give their other children (tabs the user dropped in, a later batch) to the
    // folder's place; removed tabs simply leave.
    func filter(_ list: [String]) -> [String] {
      var out: [String] = []
      for id in list {
        if let f = folders[id] {
          let kept = filter(f.children)
          if gone.contains(id) { out += kept } else { folders[id]!.children = kept; out.append(id) }
        } else if let sp = splits[id] {
          splits[id]!.children = sp.children.filter { !gone.contains($0) }
          out.append(id)
        } else if !gone.contains(id) {
          out.append(id)
        }
      }
      return out
    }
    favorites = filter(favorites)
    for k in Array(pinned.keys) { pinned[k] = filter(pinned[k]!) }
    for k in Array(today.keys) { today[k] = filter(today[k]!) }
    var removed = 0
    for id in created {
      if tabs[id] != nil {
        tabs[id] = nil
        env.call("webviews", "close", ["id": .string(id)])
        removed += 1
      } else if folders[id] != nil {
        folders[id] = nil
        removed += 1
      }
    }
    mru.removeAll { gone.contains($0) }
    multi.removeAll { gone.contains($0) }
    for (sid, id) in selected where gone.contains(id) {
      selected[sid] = mru.first { spaceOf($0) == sid }
    }
    tidySplits()
    importBatches![batch] = nil
    importKeys = importKeys!.filter { !gone.contains($0.value) }
    saveImportKeys()
    save()
    renderAll()
    showSelected()
    env.emit("tabs.changed", ["spaceId": .string(currentSpace)])
    return ["removed": .int(Int64(removed))]
  }
}
