// den extension polyfill: bookmarks (persistent JSON store)
import Foundation
import CordisValue

// MARK: - Thread-safe box for shared mutable state

private final class Box<Value> {
  private let lock = NSRecursiveLock()
  private var _value: Value
  init(_ value: Value) { _value = value }
  var value: Value {
    get { lock.lock(); defer { lock.unlock() }; return _value }
    set { lock.lock(); _value = newValue; lock.unlock() }
  }
  func update(_ body: (inout Value) -> Void) {
    lock.lock(); defer { lock.unlock() }; body(&_value)
  }
}

// MARK: - Bookmark Entry types

public struct BookmarkEntry: Sendable, Codable {
  public let id: String, parentId: String?, title: String, url: String?
  public let type: BookmarkType, index: Int, folder: Bool
  public let children: [BookmarkEntry]
  public init(id: String, parentId: String?, title: String, url: String?, type: BookmarkType, index: Int, folder: Bool, children: [BookmarkEntry] = []) {
    self.id = id; self.parentId = parentId; self.title = title; self.url = url
    self.type = type; self.index = index; self.folder = folder; self.children = children
  }
}
public enum BookmarkType: String, Sendable, Codable { case bookmark, folder }

// MARK: - ExtensionBookmarks

public enum ExtensionBookmarks: Sendable {
  private static let fileKey = "den_bookmarks.json"
  private static let defaultRoots: [BookmarkEntry] = [
    BookmarkEntry(id: "0", parentId: nil, title: "Bookmarks bar", url: nil, type: .folder, index: 0, folder: true),
    BookmarkEntry(id: "1", parentId: nil, title: "Other bookmarks", url: nil, type: .folder, index: 1, folder: true),
    BookmarkEntry(id: "2", parentId: nil, title: "Mobile bookmarks", url: nil, type: .folder, index: 2, folder: true),
  ]
  private static let _tree: Box<[BookmarkEntry]> = Box(defaultRoots)
  @_spi(ExtensionAPI) public static var tree: [BookmarkEntry] { _tree.value }
  @_spi(ExtensionAPI) public static func setTree(_ t: [BookmarkEntry]) { _tree.value = t; save() }
  private static func savePath() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(fileKey) }
  @_spi(ExtensionAPI) public static func load() {
    let url = savePath()
    guard FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: url),
          let items = try? JSONDecoder().decode([BookmarkEntry].self, from: data) else { return }
    _tree.value = items
  }
  @_spi(ExtensionAPI) public static func reset() { _tree.value = defaultRoots; try? FileManager.default.removeItem(at: savePath()) }
  private static func save() {
    let url = savePath()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    if let data = try? encoder.encode(_tree.value) { try? data.write(to: url) }
  }
  private static func nextId() -> String { UUID().uuidString }
  private static func findEntry(in entries: [BookmarkEntry], id: String) -> BookmarkEntry? {
    for entry in entries where entry.id == id { return entry }
    for entry in entries where !entry.children.isEmpty {
      if let found = findEntry(in: entry.children, id: id) { return found }
    }
    return nil
  }
  private static func allEntries(from entries: [BookmarkEntry]) -> [BookmarkEntry] {
    var result: [BookmarkEntry] = []
    for entry in entries { result.append(entry); result.append(contentsOf: allEntries(from: entry.children)) }
    return result
  }
  private static func removeSelf(from entries: [BookmarkEntry], id: String) -> [BookmarkEntry] {
    return entries.filter { $0.id != id }.map { entry in
      if entry.children.contains(where: { $0.id == id }) {
        return BookmarkEntry(id: entry.id, parentId: entry.parentId, title: entry.title, url: entry.url,
                            type: entry.type, index: entry.index, folder: entry.folder,
                            children: entry.children.filter { $0.id != id })
      }
      var uc = removeSelf(from: entry.children, id: id)
      for i in uc.indices { uc[i] = BookmarkEntry(id: uc[i].id, parentId: uc[i].parentId, title: uc[i].title, url: uc[i].url,
                                                  type: uc[i].type, index: i, folder: uc[i].folder, children: uc[i].children) }
      return BookmarkEntry(id: entry.id, parentId: entry.parentId, title: entry.title, url: entry.url,
                          type: entry.type, index: entry.index, folder: entry.folder, children: uc)
    }
  }
  private static func replaceEntry(in entries: [BookmarkEntry], updated: BookmarkEntry) -> [BookmarkEntry] {
    entries.map { entry in
      if entry.id == updated.id { return updated }
      return BookmarkEntry(id: entry.id, parentId: entry.parentId, title: entry.title, url: entry.url,
                          type: entry.type, index: entry.index, folder: entry.folder, children: replaceEntry(in: entry.children, updated: updated))
    }
  }
  @_spi(ExtensionAPI) public static func getTree() -> [BookmarkEntry] { _tree.value }
  @_spi(ExtensionAPI) public static func getSubTree(_ parentId: String) -> [BookmarkEntry] { findEntry(in: _tree.value, id: parentId)?.children ?? [] }
  @_spi(ExtensionAPI) public static func get(_ id: String) -> BookmarkEntry? { findEntry(in: _tree.value, id: id) }
  @_spi(ExtensionAPI) public static func getChildren(_ parentId: String) -> [BookmarkEntry] { getSubTree(parentId) }
  @_spi(ExtensionAPI) public static func getRecent(_ days: Int = 2) -> [BookmarkEntry] { allEntries(from: _tree.value) }
  @_spi(ExtensionAPI) public static func search(query: String) -> [BookmarkEntry] {
    let q = query.lowercased()
    return allEntries(from: _tree.value).filter { $0.title.lowercased().contains(q) || ($0.url ?? "").lowercased().contains(q) }
      .sorted { $0.index < $1.index }
  }
  @_spi(ExtensionAPI) public static func create(url: String?, title: String?, parentId: String?) -> BookmarkEntry {
    let id = nextId()
    let targetId = _tree.value.first(where: { $0.folder })?.id ?? "0"
    let entry = BookmarkEntry(id: id, parentId: targetId, title: title ?? "", url: url, type: url != nil ? .bookmark : .folder, index: 0, folder: url == nil)
    _tree.update { current in
      current = current.map { $0.id == targetId ? BookmarkEntry(id: $0.id, parentId: $0.parentId, title: $0.title, url: $0.url,
                                                         type: $0.type, index: $0.index, folder: $0.folder, children: $0.children + [entry]) : $0 }
    }
    save(); return entry
  }
  @_spi(ExtensionAPI) public static func createFolder(title: String?, parentId: String?) -> BookmarkEntry { create(url: nil, title: title, parentId: parentId) }
  @_spi(ExtensionAPI) public static func update(id: String, url: String?, title: String?) -> BookmarkEntry? {
    guard let e = findEntry(in: _tree.value, id: id) else { return nil }
    let updated = BookmarkEntry(id: e.id, parentId: e.parentId, title: title ?? e.title, url: url ?? e.url,
                                type: (url ?? e.url) != nil ? .bookmark : .folder, index: e.index, folder: (url ?? e.url) == nil, children: e.children)
    _tree.value = replaceEntry(in: _tree.value, updated: updated); save(); return updated
  }
  @_spi(ExtensionAPI) public static func move(id: String, toParent: String, atIndex index: Int? = nil) -> BookmarkEntry? {
    guard let entry = findEntry(in: _tree.value, id: id), let folder = findEntry(in: _tree.value, id: toParent) else { return nil }
    _tree.value = removeSelf(from: _tree.value, id: id)
    let ne = BookmarkEntry(id: entry.id, parentId: toParent, title: entry.title, url: entry.url, type: entry.type,
                           index: index ?? folder.children.count, folder: entry.folder, children: entry.children)
    _tree.update { current in
      current = current.map { $0.id == toParent ? BookmarkEntry(id: $0.id, parentId: $0.parentId, title: $0.title, url: $0.url,
                                                         type: $0.type, index: $0.index, folder: $0.folder,
                                                         children: (index ?? folder.children.count) < folder.children.count ?
                                                         folder.children.prefix(index!) + [ne] + folder.children.suffix(from: index!) :
                                                         $0.children + [ne]) : $0 }
    }
    save(); return ne
  }
  @_spi(ExtensionAPI) public static func remove(_ id: String) -> Bool {
    guard findEntry(in: _tree.value, id: id) != nil else { return false }
    _tree.value = removeSelf(from: _tree.value, id: id); save(); return true
  }
  @_spi(ExtensionAPI) public static func removeTree(_ id: String) -> Bool { remove(id) }
}

// MARK: - Download types

public enum DownloadState: String, Sendable { case inProgress, complete, interrupted, canceled }

public struct DownloadEntry: Sendable {
  public let id: Int64, url: String, fileName: String?
  public let state: DownloadState, bytesReceived: Int64, totalBytes: Int64
  public let danger: Bool, mime: String?, startTime: Double, endTime: Double?, exists: Bool
  public init(id: Int64, url: String, fileName: String?, state: DownloadState, bytesReceived: Int64 = 0,
              totalBytes: Int64 = 0, danger: Bool = false, mime: String? = nil,
              startTime: Double = Date().timeIntervalSince1970, endTime: Double? = nil, exists: Bool = false) {
    self.id = id; self.url = url; self.fileName = fileName; self.state = state
    self.bytesReceived = bytesReceived; self.totalBytes = totalBytes; self.danger = danger
    self.mime = mime; self.startTime = startTime; self.endTime = endTime; self.exists = exists
  }
}
public enum DownloadError: LocalizedError {
  case notFound(id: Int64), notComplete(id: Int64), unavailable
  public var errorDescription: String? {
    switch self {
    case .notFound(let id): return "Download \(id) not found"
    case .notComplete(let id): return "Download \(id) is not complete"
    case .unavailable: return "File unavailable"
    }
  }
}

// MARK: - ExtensionDownloads

public enum ExtensionDownloads: Sendable {
  private static let _nextId: Box<Int64> = Box(1)
  @_spi(ExtensionAPI) public static var nextId: Int64 { _nextId.value }
  @_spi(ExtensionAPI) public static func setNextId(_ id: Int64) { _nextId.value = id }
  private static let _downloads: Box<[Int64: DownloadEntry]> = Box([:])
  @_spi(ExtensionAPI) public static var downloads: [Int64: DownloadEntry] { _downloads.value }
  @_spi(ExtensionAPI) public static func setDownloads(_ d: [Int64: DownloadEntry]) { _downloads.value = d }
  private static let fileKey = "den_downloads.json"
  @_spi(ExtensionAPI) public static func load() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileKey)
    guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    for (idStr, obj) in dict {
      guard let id = Int64(idStr), let d = obj as? [String: Any],
            let u = d["url"] as? String, let st = DownloadState(rawValue: d["state"] as? String ?? "") else { continue }
      _downloads.value[id] = DownloadEntry(id: id, url: u, fileName: d["fileName"] as? String, state: st,
        bytesReceived: (d["bytesReceived"] as? Int64) ?? 0, totalBytes: (d["totalBytes"] as? Int64) ?? 0,
        danger: (d["danger"] as? Bool) ?? false, mime: d["mime"] as? String,
        startTime: (d["startTime"] as? Double) ?? 0, endTime: d["endTime"] as? Double,
        exists: (d["exists"] as? Bool) ?? false)
    }
  }
  private static func save() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileKey)
    let d = _downloads.value
    let dict = d.mapValues { ["url": $0.url, "fileName": $0.fileName as Any, "state": $0.state.rawValue,
      "bytesReceived": $0.bytesReceived, "totalBytes": $0.totalBytes, "danger": $0.danger,
      "mime": $0.mime as Any, "startTime": $0.startTime, "endTime": $0.endTime as Any, "exists": $0.exists] }
    if let data = try? JSONSerialization.data(withJSONObject: dict) { try? data.write(to: url) }
  }
  @_spi(ExtensionAPI) public static func reset() {
    _downloads.value.removeAll(); _nextId.value = 1
    try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(fileKey))
  }
  @_spi(ExtensionAPI) public static func download(url: String, fileName: String? = nil) -> Int64 {
    let id = _nextId.value; _nextId.value += 1
    _downloads.value[id] = DownloadEntry(id: id, url: url, fileName: fileName, state: .inProgress)
    save(); return id
  }
  @_spi(ExtensionAPI) public static func pause(downloadId: Int64) -> Bool {
    guard let e = _downloads.value[downloadId] else { return false }
    _downloads.value[downloadId] = DownloadEntry(id: e.id, url: e.url, fileName: e.fileName, state: .interrupted,
      bytesReceived: e.bytesReceived, totalBytes: e.totalBytes, danger: e.danger, mime: e.mime, startTime: e.startTime)
    save(); return true
  }
  @_spi(ExtensionAPI) public static func resume(downloadId: Int64) -> Bool {
    guard let e = _downloads.value[downloadId] else { return false }
    _downloads.value[downloadId] = DownloadEntry(id: e.id, url: e.url, fileName: e.fileName, state: .inProgress,
      bytesReceived: e.bytesReceived, totalBytes: e.totalBytes, danger: e.danger, mime: e.mime, startTime: e.startTime)
    save(); return true
  }
  @_spi(ExtensionAPI) public static func cancel(downloadId: Int64) -> Bool {
    guard let e = _downloads.value[downloadId] else { return false }
    _downloads.value[downloadId] = DownloadEntry(id: e.id, url: e.url, fileName: e.fileName, state: .canceled,
      bytesReceived: e.bytesReceived, totalBytes: e.totalBytes, danger: e.danger, mime: e.mime,
      startTime: e.startTime, endTime: Date().timeIntervalSince1970)
    save(); return true
  }
  @_spi(ExtensionAPI) public static func complete(downloadId: Int64) -> Bool {
    guard let e = _downloads.value[downloadId] else { return false }
    _downloads.value[downloadId] = DownloadEntry(id: e.id, url: e.url, fileName: e.fileName, state: .complete,
      bytesReceived: e.totalBytes, totalBytes: e.totalBytes, danger: e.danger, mime: e.mime,
      startTime: e.startTime, endTime: Date().timeIntervalSince1970, exists: true)
    save(); return true
  }
  @_spi(ExtensionAPI) public static func search(s: DownloadState? = nil, i: Int64? = nil, u: String? = nil) -> [DownloadEntry] {
    var e = Array(_downloads.value.values)
    if let s { e = e.filter { $0.state == s } }
    if let i { e = e.filter { $0.id == i } }
    if let u { e = e.filter { $0.url == u } }
    return e.sorted { $0.id < $1.id }
  }
  @_spi(ExtensionAPI) public static func get(id: Int64) -> DownloadEntry? { _downloads.value[id] }
  @_spi(ExtensionAPI) public static func getFile(id: Int64) throws -> Data {
    guard let e = _downloads.value[id] else { throw DownloadError.notFound(id: id) }
    guard e.state == .complete else { throw DownloadError.notComplete(id: id) }
    throw DownloadError.unavailable
  }
  @_spi(ExtensionAPI) public static func show(id: Int64) {}
  @_spi(ExtensionAPI) public static func removeFile(id: Int64) {}
  @_spi(ExtensionAPI) public static func open(id: Int64) {}
  @_spi(ExtensionAPI) public static func erase() {
    _downloads.value.removeAll(); save()
  }
  @_spi(ExtensionAPI) public static func clear(_ state: DownloadState = .complete) {
    _downloads.value = _downloads.value.filter { $0.value.state != state }; save()
  }
}

// MARK: - History types

public struct HistoryVisit: Sendable {
  public let id: String, url: String, title: String
  public let visitCount: Int, typedCount: Int, lastVisitTime: Double, transition: String
  public init(id: String, url: String, title: String, visitCount: Int = 0, typedCount: Int = 0,
              lastVisitTime: Double = Date().timeIntervalSince1970, transition: String = "auto_subframe") {
    self.id = id; self.url = url; self.title = title; self.visitCount = visitCount
    self.typedCount = typedCount; self.lastVisitTime = lastVisitTime; self.transition = transition
  }
}

// MARK: - ExtensionHistory

public enum ExtensionHistory: Sendable {
  private static let maxVisits = 2000
  private static let _visits: Box<[HistoryVisit]> = Box([])
  @_spi(ExtensionAPI) public static var visits: [HistoryVisit] { _visits.value }
  @_spi(ExtensionAPI) public static func setVisits(_ v: [HistoryVisit]) { _visits.value = v }
  @_spi(ExtensionAPI) public static func reset() { _visits.value.removeAll() }
  @_spi(ExtensionAPI) public static func record(url: String, title: String = "") {
    guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return }
    _visits.update { v in
      if let idx = v.firstIndex(where: { $0.url == url }) {
        v[idx] = HistoryVisit(id: v[idx].id, url: url,
          title: title.isEmpty ? v[idx].title : title,
          visitCount: v[idx].visitCount + 1, typedCount: v[idx].typedCount,
          lastVisitTime: Date().timeIntervalSince1970, transition: v[idx].transition)
      } else {
        let newVisit = HistoryVisit(id: UUID().uuidString, url: url, title: title.isEmpty ? url : title, lastVisitTime: Date().timeIntervalSince1970)
        v.insert(newVisit, at: 0)
        if v.count > maxVisits { v.removeLast(v.count - maxVisits) }
      }
    }
  }
  @_spi(ExtensionAPI) public static func search(t: String? = nil, s: Double? = nil, e: Double? = nil, maxResults: Int = 100) -> [HistoryVisit] {
    var r = _visits.value
    if let t { let tl = t.lowercased(); r = r.filter { $0.url.lowercased().contains(tl) || $0.title.lowercased().contains(tl) } }
    if let s { r = r.filter { $0.lastVisitTime >= s } }
    if let e { r = r.filter { $0.lastVisitTime <= e } }
    return Array(r.prefix(maxResults))
  }
  @_spi(ExtensionAPI) public static func getVisits(url: String) -> [HistoryVisit] { _visits.value.filter { $0.url == url } }
  @_spi(ExtensionAPI) public static func addUrl(url: String, title: String = "") { record(url: url, title: title) }
  @_spi(ExtensionAPI) public static func deleteUrl(url: String) -> Bool {
    _visits.update { v in
      guard let idx = v.firstIndex(where: { $0.url == url }) else { return false }
      v.remove(at: idx); return true
    }
  }
  @_spi(ExtensionAPI) public static func deleteRange(startTime: Double, endTime: Double) -> Bool {
    _visits.update { v in
      let c = v.count; v.removeAll { $0.lastVisitTime >= startTime && $0.lastVisitTime <= endTime }; return v.count < c
    }
  }
  @_spi(ExtensionAPI) public static func deleteAll() -> Bool {
    _visits.update { v in
      guard !v.isEmpty else { return false }; v.removeAll(); return true
    }
  }
  @_spi(ExtensionAPI) public static func getAllVisits() -> [HistoryVisit] { _visits.value }
  @_spi(ExtensionAPI) public static var count: Int { _visits.value.count }
}

// MARK: - Identity types & polyfill

public struct UserProfile: Sendable {
  public let id: String, email: String, displayName: String
  public let avatar: String?
  public init(id: String, email: String, displayName: String, avatar: String? = nil) {
    self.id = id; self.email = email; self.displayName = displayName; self.avatar = avatar
  }
}

public struct IdentityAuthParams: Sendable {
  public let scope: String, hostedDomain: String?, hint: String?
  public init(scope: String, hostedDomain: String? = nil, hint: String? = nil) {
    self.scope = scope; self.hostedDomain = hostedDomain; self.hint = hint
  }
}

public enum ExtensionIdentity: Sendable {
  private static let mockUserId = "den-mock-user-0001"
  private static let mockEmail = "user@example.com"
  private static let mockName = "Mock User"
  @_spi(ExtensionAPI) public static func getProfile() throws -> UserProfile {
    UserProfile(id: mockUserId, email: mockEmail, displayName: mockName)
  }
  @_spi(ExtensionAPI) public static func getAuthToken(params: IdentityAuthParams) throws -> String {
    "den_mock_token_\(mockUserId)"
  }
  @_spi(ExtensionAPI) public static func removeCachedAuthToken(params: IdentityAuthParams? = nil) throws {}
  @_spi(ExtensionAPI) public static func getCode(params: IdentityAuthParams) throws -> String {
    "den_mock_auth_code_\(mockUserId)"
  }
  @_spi(ExtensionAPI) public static func getDisplayId() throws -> String { "den-mock-display-id" }
  @_spi(ExtensionAPI) public static func signOut() throws {}
  @_spi(ExtensionAPI) public static func reset() {}
  @_spi(ExtensionAPI) public static func isMockToken(_ token: String) -> Bool { token.hasPrefix("den_mock_") }
  @_spi(ExtensionAPI) public static func isMockCode(_ code: String) -> Bool { code.hasPrefix("den_mock_auth_code_") }
}

// MARK: - SidePanel types & polyfill

public struct SidePanelOptions: Sendable {
  public let panel: String?, shouldBypassCSP: Bool, openInTab: Bool
  public init(panel: String?, shouldBypassCSP: Bool, openInTab: Bool) {
    self.panel = panel; self.shouldBypassCSP = shouldBypassCSP; self.openInTab = openInTab
  }
}

public struct PanelBehavior: Sendable {
  public let openPanelOnActionClick: Bool
  public let panelPosition: SidePanelPosition
  public init(openPanelOnActionClick: Bool, panelPosition: SidePanelPosition = .end) {
    self.openPanelOnActionClick = openPanelOnActionClick; self.panelPosition = panelPosition
  }
}

public enum SidePanelPosition: String, Sendable { case start, end }

public enum ExtensionSidePanel: Sendable {
  private static let _panelBehavior: Box<PanelBehavior> = Box(PanelBehavior(openPanelOnActionClick: true))
  @_spi(ExtensionAPI) public static var panelBehavior: PanelBehavior { _panelBehavior.value }
  @_spi(ExtensionAPI) public static func setPanelBehavior(_ b: PanelBehavior) { _panelBehavior.value = b }
  private static let _tabConfigurations: Box<[String: SidePanelOptions]> = Box([:])
  @_spi(ExtensionAPI) public static var tabConfigurations: [String: SidePanelOptions] { _tabConfigurations.value }
  @_spi(ExtensionAPI) public static func setTabConfigurations(_ c: [String: SidePanelOptions]) { _tabConfigurations.value = c }
  private static let _panelURL: Box<String?> = Box(nil)
  @_spi(ExtensionAPI) public static func getPanelURL() -> String? { _panelURL.value }
  @_spi(ExtensionAPI) public static func setPanel(url: String?) { _panelURL.value = url }
  @_spi(ExtensionAPI) public static func setPanel(forTab tabId: String, url: String?) {
    _tabConfigurations.update { c in c[tabId] = SidePanelOptions(panel: url, shouldBypassCSP: false, openInTab: false) }
  }
  @_spi(ExtensionAPI) public static func getOptions(forTab tabId: String) -> SidePanelOptions {
    _tabConfigurations.value[tabId] ?? SidePanelOptions(panel: _panelURL.value, shouldBypassCSP: false, openInTab: false)
  }
  @_spi(ExtensionAPI) public static func setBehavior(_ behavior: PanelBehavior) { _panelBehavior.value = behavior }
  @_spi(ExtensionAPI) public static func getBehavior() -> PanelBehavior { _panelBehavior.value }
  @_spi(ExtensionAPI) public static func open(forTab tabId: String) {}
  @_spi(ExtensionAPI) public static func clearPanel(forTab tabId: String) { _tabConfigurations.update { c in c.removeValue(forKey: tabId) } }
  @_spi(ExtensionAPI) public static func clearPanel() { _tabConfigurations.update { c in c.removeAll() } }
  @_spi(ExtensionAPI) public static func reset() {
    _panelURL.value = nil; _panelBehavior.value = PanelBehavior(openPanelOnActionClick: true); _tabConfigurations.value.removeAll()
  }
}