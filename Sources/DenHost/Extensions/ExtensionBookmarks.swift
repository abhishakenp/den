// thin-host: feature-specific, migrate to plugin (whole file)
import CordisValue
import Foundation

/// `chrome.bookmarks` over den's own saved places. den (like Arc) has no separate bookmarks: what
/// you keep is Favorites and each space's pinned tabs and folders (imported bookmarks land there
/// too, as a pinned folder). An extension sees them as a bookmark tree:
///
///     0  (root)
///     ├─ 1  Favorites            (Chrome's "Bookmarks bar", folderType "bookmarks-bar")
///     └─ 2  Pinned               (Chrome's "Other bookmarks", folderType "other")
///        └─ space:<id>  <space name>
///           └─ pinned tabs and folders (tab-<n> / folder-<n>; a split's tabs in its place)
///
/// A bookmark's URL is the tab's pinned address (`pinnedUrl`, the "/" reset target), not where
/// the tab has wandered. Writes go through the `tabs` plugin: `create` pins a new tab (never
/// loaded until opened), `update` renames or re-homes it (`setPinnedUrl`), `move` moves it,
/// `remove` archives it (like closing a Today tab, so the Library keeps it) and `removeTree`
/// deletes a folder. Events come from diffing the tree on `tabs.changed`, only while an
/// extension listens (`ExtensionAPIs`).
@MainActor
final class ExtensionBookmarks {
  let call: (String, String, Value) -> Value
  init(call: @escaping (String, String, Value) -> Value) { self.call = call }

  struct Node {
    var id: String
    var parentId: String?
    var index: Int
    var title: String
    var url: String?
    var dateAdded: Int64
    var children: [Node]?
    /// `root`, `favorites`, `pinned`, `space` (fixed folders) or `folder` / `tab`.
    var kind: String
    var spaceId: String?

    func value(deep: Bool) -> Value {
      var v: Value = ["id": .string(id), "title": .string(title), "dateAdded": .int(dateAdded), "syncing": false]
      if let parentId { v = v.with("parentId", .string(parentId)).with("index", .int(Int64(index))) }
      if let url { v = v.with("url", .string(url)) } else {
        v = v.with("dateGroupModified", .int(dateAdded))
        if kind == "favorites" { v = v.with("folderType", "bookmarks-bar") }
        if kind == "pinned" { v = v.with("folderType", "other") }
        if ["root", "favorites", "pinned", "space"].contains(kind) { v = v.with("unmodifiable", "managed") }
      }
      if deep, let children { v = v.with("children", .array(children.map { $0.value(deep: true) })) }
      return v
    }
  }

  // MARK: The tree

  func tree() -> Node {
    let spaces = call("spaces", "list", .null).array ?? []
    let current = call("spaces", "current", .null).str("id")
    let favs = call("tabs", "list", ["spaceId": .string(current)]).list("favorites")
    var favorites = Node(id: "1", parentId: "0", index: 0, title: "Favorites", dateAdded: 0, children: [], kind: "favorites")
    favorites.children = Self.items(favs, parent: "1", space: nil)
    var pinned = Node(id: "2", parentId: "0", index: 1, title: "Pinned", dateAdded: 0, children: [], kind: "pinned")
    for (i, s) in spaces.enumerated() {
      let sid = s.str("id")
      var n = Node(id: "space:" + sid, parentId: "2", index: i, title: s.str("name", "Space"), dateAdded: 0, children: [], kind: "space", spaceId: sid)
      n.children = Self.items(call("tabs", "list", ["spaceId": .string(sid)]).list("pinned"), parent: n.id, space: sid)
      pinned.children?.append(n)
    }
    return Node(id: "0", parentId: nil, index: 0, title: "", dateAdded: 0, children: [favorites, pinned], kind: "root")
  }

  /// `tabs.list` items as bookmark nodes. A split stands for its tabs, each in turn.
  static func items(_ list: [Value], parent: String, space: String?) -> [Node] {
    var flat: [Value] = []
    for i in list { if i.flag("split") { flat += i.list("children") } else { flat.append(i) } }
    return flat.enumerated().map { (k, i) in
      if i.flag("folder") {
        var f = Node(id: i.str("id"), parentId: parent, index: k, title: i.str("title"), dateAdded: 0, children: nil, kind: "folder", spaceId: space)
        f.children = items(i.list("children"), parent: f.id, space: space)
        return f
      }
      let url = i["pinnedUrl"].string ?? i.str("url")
      return Node(id: i.str("id"), parentId: parent, index: k, title: i.str("title"), url: url, dateAdded: i["lastActive"].int ?? 0, kind: "tab", spaceId: space)
    }
  }

  static func find(_ id: String, in n: Node) -> Node? {
    if n.id == id { return n }
    for c in n.children ?? [] { if let f = find(id, in: c) { return f } }
    return nil
  }

  static func walk(_ n: Node, _ f: (Node) -> Void) {
    f(n)
    for c in n.children ?? [] { walk(c, f) }
  }

  // MARK: The API

  func handle(_ method: String, _ args: [Value]) -> Value {
    let a0 = args.first ?? .null
    switch method {
    case "getTree": return [tree().value(deep: true)]
    case "getSubTree":
      guard let n = Self.find(a0.string ?? "", in: tree()) else { return .error("Can't find bookmark for id.") }
      return [n.value(deep: true)]
    case "get":
      let ids = a0.array?.compactMap(\.string) ?? [a0.string ?? ""]
      let t = tree()
      var out: [Value] = []
      for id in ids {
        guard let n = Self.find(id, in: t) else { return .error("Can't find bookmark for id.") }
        out.append(n.value(deep: false))
      }
      return .array(out)
    case "getChildren":
      guard let n = Self.find(a0.string ?? "", in: tree()) else { return .error("Can't find bookmark for id.") }
      return .array((n.children ?? []).map { $0.value(deep: false) })
    case "getRecent":
      var tabs: [Node] = []
      Self.walk(tree()) { if $0.url != nil { tabs.append($0) } }
      let n = max(1, Int(a0.int ?? 10))
      return .array(tabs.sorted { $0.dateAdded > $1.dateAdded }.prefix(n).map { $0.value(deep: false) })
    case "search": return .array(search(a0).map { $0.value(deep: false) })
    case "create": return create(a0)
    case "update": return update(a0.string ?? "", args.count > 1 ? args[1] : .null)
    case "move": return move(a0.string ?? "", args.count > 1 ? args[1] : .null)
    case "remove": return remove(a0.string ?? "", tree: false)
    case "removeTree": return remove(a0.string ?? "", tree: true)
    default: return .error("bookmarks.\(method) isn’t available in den")
    }
  }

  /// `search(query)`: a string matches every word in the title or URL; an object matches
  /// `query` that way, `url` exactly and `title` exactly (Chrome's rules).
  func search(_ q: Value) -> [Node] {
    var words: [String] = []
    var url: String?, title: String?
    if let s = q.string { words = s.lowercased().split(separator: " ").map(String.init) } else {
      words = q.str("query").lowercased().split(separator: " ").map(String.init)
      url = q["url"].string
      title = q["title"].string
    }
    var out: [Node] = []
    Self.walk(tree()) { n in
      guard n.parentId != nil, !["favorites", "pinned", "space"].contains(n.kind) else { return }
      let hay = (n.title + " " + (n.url ?? "")).lowercased()
      if !words.allSatisfy({ hay.contains($0) }) { return }
      if let url, n.url != url { return }
      if let title, n.title != title { return }
      if words.isEmpty, url == nil, title == nil { return }
      out.append(n)
    }
    return out
  }

  /// Where a new or moved item goes: (spaceId, kind, folderId) for `tabs.open` / `tabs.move`.
  func place(_ parentId: String, in t: Node) -> (space: String, kind: String, folder: String?)? {
    let current = call("spaces", "current", .null).str("id")
    switch parentId {
    case "1": return (current, "favorite", nil)
    case "2", "0": return (current, "pinned", nil)
    default:
      guard let p = Self.find(parentId, in: t) else { return nil }
      if p.kind == "space", let s = p.spaceId { return (s, "pinned", nil) }
      if p.kind == "folder", let s = p.spaceId { return (s, "pinned", p.id) }
      return nil
    }
  }

  func create(_ o: Value) -> Value {
    let t = tree()
    guard let (space, kind, folder) = place(o.str("parentId", "2"), in: t) else { return .error("Can't find parent bookmark for id.") }
    let index = o["index"].int.map { Value.int($0) } ?? .null
    var id: String
    if let url = o["url"].string, !url.isEmpty {
      guard URL(string: url)?.scheme != nil else { return .error("Invalid URL.") }
      let r = call("tabs", "open", ["url": .string(url), "spaceId": .string(space), "kind": .string(kind), "background": true])
      guard let nid = r["id"].string else { return .error(r.str("error", "Couldn’t add the bookmark")) }
      id = nid
      if let f = folder { _ = call("tabs", "move", ["id": .string(id), "folderId": .string(f), "index": index]) } else if !index.isNull {
        _ = call("tabs", "move", ["id": .string(id), "spaceId": .string(space), "kind": .string(kind), "index": index])
      }
      if let title = o["title"].string, !title.isEmpty { _ = call("tabs", "rename", ["id": .string(id), "title": .string(title)]) }
    } else {
      guard kind != "favorite" else { return .error("Favorites can’t hold folders in den.") }
      let r = call("tabs", "createFolder", ["spaceId": .string(space), "title": .string(o.str("title", "New Folder"))])
      guard let nid = r["id"].string else { return .error(r.str("error", "Couldn’t add the folder")) }
      id = nid
      if let f = folder { _ = call("tabs", "move", ["id": .string(id), "folderId": .string(f), "index": index]) } else if !index.isNull {
        _ = call("tabs", "move", ["id": .string(id), "spaceId": .string(space), "kind": "pinned", "index": index])
      }
    }
    return Self.find(id, in: tree())?.value(deep: false) ?? .error("Couldn’t add the bookmark")
  }

  func update(_ id: String, _ changes: Value) -> Value {
    guard let n = Self.find(id, in: tree()), n.kind == "tab" || n.kind == "folder" else { return .error("Can't modify the root bookmark folders.") }
    if let title = changes["title"].string {
      let r = call("tabs", "rename", ["id": .string(id), "title": .string(title)])
      if r.isError { return r }
    }
    if let url = changes["url"].string {
      guard n.kind == "tab" else { return .error("Can't set URL of a bookmark folder.") }
      guard URL(string: url)?.scheme != nil else { return .error("Invalid URL.") }
      let r = call("tabs", "setPinnedUrl", ["id": .string(id), "url": .string(url)])
      if r.isError { return r }
    }
    return Self.find(id, in: tree())?.value(deep: false) ?? .error("Can't find bookmark for id.")
  }

  func move(_ id: String, _ dest: Value) -> Value {
    let t = tree()
    guard let n = Self.find(id, in: t), n.kind == "tab" || n.kind == "folder" else { return .error("Can't modify the root bookmark folders.") }
    guard let (space, kind, folder) = place(dest.str("parentId", n.parentId ?? "2"), in: t) else { return .error("Can't find parent bookmark for id.") }
    if n.kind == "folder", kind == "favorite" { return .error("Favorites can’t hold folders in den.") }
    var args: Value = ["id": .string(id), "index": dest["index"]]
    if let f = folder { args = args.with("folderId", .string(f)) } else { args = args.with("spaceId", .string(space)).with("kind", .string(kind)) }
    let r = call("tabs", "move", args)
    if r.isError { return r }
    return Self.find(id, in: tree())?.value(deep: false) ?? .error("Can't find bookmark for id.")
  }

  func remove(_ id: String, tree whole: Bool) -> Value {
    guard let n = Self.find(id, in: tree()), n.kind == "tab" || n.kind == "folder" else { return .error("Can't modify the root bookmark folders.") }
    if n.kind == "folder" {
      if !whole, !(n.children ?? []).isEmpty { return .error("Can't remove non-empty folder (use recursive to force).") }
      let r = call("tabs", "deleteFolder", ["id": .string(id)])
      return r.isError ? r : .null
    }
    // A pinned tab or favorite leaves for the archive (the Library keeps it, ⌃Z-like restore).
    let m = call("tabs", "move", ["id": .string(id), "kind": "today"])
    if m.isError { return m }
    let r = call("tabs", "close", ["id": .string(id)])
    return r.isError ? r : .null
  }

  // MARK: Events

  /// Flat map of the tree for diffing: id -> (parentId, index, title, url).
  typealias Flat = [String: (parent: String, index: Int, title: String, url: String?)]
  func flat() -> Flat {
    var out: Flat = [:]
    Self.walk(tree()) { n in if let p = n.parentId { out[n.id] = (p, n.index, n.title, n.url) } }
    return out
  }

  /// The events `chrome.bookmarks` fires for the change from `old` to `new`.
  static func diff(_ old: Flat, _ new: Flat, node: (String) -> Value) -> [(String, [Value])] {
    var out: [(String, [Value])] = []
    for (id, n) in new.sorted(by: { $0.key < $1.key }) {
      guard let o = old[id] else {
        out.append(("bookmarks.onCreated", [.string(id), node(id)]))
        continue
      }
      if o.title != n.title || o.url != n.url {
        var info: Value = ["title": .string(n.title)]
        if let u = n.url { info = info.with("url", .string(u)) }
        out.append(("bookmarks.onChanged", [.string(id), info]))
      }
      if o.parent != n.parent || o.index != n.index {
        out.append(("bookmarks.onMoved", [.string(id), ["parentId": .string(n.parent), "index": .int(Int64(n.index)), "oldParentId": .string(o.parent), "oldIndex": .int(Int64(o.index))]]))
      }
    }
    for (id, o) in old.sorted(by: { $0.key < $1.key }) where new[id] == nil {
      var removed: Value = ["id": .string(id), "parentId": .string(o.parent), "index": .int(Int64(o.index)), "title": .string(o.title), "dateAdded": 0]
      if let u = o.url { removed = removed.with("url", .string(u)) }
      out.append(("bookmarks.onRemoved", [.string(id), ["parentId": .string(o.parent), "index": .int(Int64(o.index)), "node": removed]]))
    }
    // A reorder moves every sibling's index: report the item that moved, not all of them.
    let moved = out.filter { $0.0 == "bookmarks.onMoved" }
    let created = Set(out.filter { $0.0 == "bookmarks.onCreated" || $0.0 == "bookmarks.onRemoved" }.compactMap { $0.1.first?.string })
    if moved.count > 1 || !created.isEmpty {
      let real = moved.filter { m in
        let info = m.1[1]
        if info.str("parentId") != info.str("oldParentId") { return true }
        // Same parent: an index shift caused by an add or remove next to it isn't a move.
        return created.isEmpty && Self.isMover(m.1[0].string ?? "", parent: info.str("parentId"), old, new)
      }
      out = out.filter { $0.0 != "bookmarks.onMoved" } + real
    }
    return out
  }

  /// In a pure reorder of one parent's children, the item that moved: the one whose removal
  /// leaves both orders equal.
  static func isMover(_ id: String, parent: String, _ old: Flat, _ new: Flat) -> Bool {
    let o = old.filter { $0.value.parent == parent }.sorted { $0.value.index < $1.value.index }.map(\.key)
    let n = new.filter { $0.value.parent == parent }.sorted { $0.value.index < $1.value.index }.map(\.key)
    return o.filter { $0 != id } == n.filter { $0 != id }
  }
}
