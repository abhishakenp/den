import AppIntents
import CordisValue
import Foundation

// den's actions for Shortcuts, Siri and Spotlight (App Intents). Each one calls the same services
// the menu bar and the command bar do (`tabs`, `spaces`, `media`), so what an action does is still
// the plugins' business. The phrases are in `DenShortcuts` (the app module).
//
// The system lists an app's actions from `Contents/Resources/Metadata.appintents`, which
// scripts/bundle.sh extracts at build time (Xcode does this for Xcode projects). The system only
// accepts apps signed with a Team ID (an Apple developer account): with den's self-signed or ad
// hoc signature, linkd rejects it ("requiresValidatedBundle") and Shortcuts doesn't show den's
// actions. Everything here works and is tested in-process; it reaches Shortcuts once den is
// signed with a Team ID (docs/research/apple-platform.md).

/// The runtime the actions act on (the app sets it at launch).
@MainActor
public enum DenIntents {
  public static weak var runtime: DenRuntime?

  static func call(_ service: String, _ method: String, _ args: Value = .null) throws -> Value {
    guard let rt = runtime else { throw DenIntentError.notRunning }
    let v = rt.call(service, method, args)
    if v.isError { throw DenIntentError.failed(v.str("error")) }
    return v
  }

  static func spaces() -> [SpaceEntity] {
    guard let l = try? call("spaces", "list").array else { return [] }
    return l.map { SpaceEntity(id: $0.str("id"), name: $0.str("name").isEmpty ? "Space" : $0.str("name")) }
  }

  /// Every tab in the sidebar of every space (favorites once), never a private one.
  static func tabs() -> [TabEntity] {
    var out: [TabEntity] = []
    var seen = Set<String>()
    for (i, sp) in spaces().enumerated() {
      guard let l = try? call("tabs", "list", ["spaceId": .string(sp.id)]) else { continue }
      var stack = ((i == 0 ? l.list("favorites") : []) + l.list("pinned") + l.list("today")).reversed().map { $0 }
      while let item = stack.popLast() {
        if item.flag("folder") || item.flag("split") {
          stack.append(contentsOf: item.list("children").reversed())
          continue
        }
        let id = item.str("id")
        guard !id.isEmpty, !seen.contains(id) else { continue }
        seen.insert(id)
        let custom = item.str("customTitle"), title = item.str("title"), url = item.str("url")
        out.append(TabEntity(id: id, title: !custom.isEmpty ? custom : (!title.isEmpty ? title : url), url: URL(string: url),
                             space: item["spaceId"].isNull ? "Favorites" : sp.name))
      }
    }
    return out
  }

  /// The page in front (the selected tab), as an entity. Refuses a private window's.
  static func currentTab() throws -> TabEntity {
    let sel = try call("tabs", "selected")
    guard let id = sel["id"].string else { throw DenIntentError.noPage }
    if sel.flag("private") { throw DenIntentError.privateWindow }
    let w = try call("webviews", "get", ["id": .string(id)])
    let known = tabs().first { $0.id == id }
    let url = w.str("url")
    let title = w.str("title")
    return TabEntity(id: id, title: title.isEmpty ? (known?.title ?? url) : title, url: URL(string: url), space: known?.space ?? "")
  }

  static func matching(_ text: String) -> [TabEntity] {
    let q = text.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return tabs() }
    return tabs().filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.url?.absoluteString ?? "").localizedCaseInsensitiveContains(q) }
  }

  /// Switches to `space` (if given), then opens `url` there as a selected Today tab.
  static func open(_ url: URL, in space: SpaceEntity?) throws {
    if let space { _ = try call("spaces", "switch", ["id": .string(space.id)]) }
    _ = try call("tabs", "open", ["url": .string(url.absoluteString)])
  }
}

enum DenIntentError: Error, CustomLocalizedStringResourceConvertible {
  case notRunning, noPage, privateWindow, failed(String)

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .notRunning: "den isn't ready yet."
    case .noPage: "No page is open in den."
    case .privateWindow: "den's front window is private."
    case let .failed(why): "den couldn't do that: \(why)"
    }
  }
}

// MARK: Entities

public struct SpaceEntity: AppEntity, Sendable {
  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Space"
  public static let defaultQuery = SpaceQuery()
  public let id: String
  public let name: String
  public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
  public init(id: String, name: String) { (self.id, self.name) = (id, name) }
}

public struct SpaceQuery: EntityStringQuery {
  public init() {}
  public func entities(for identifiers: [String]) async throws -> [SpaceEntity] {
    await MainActor.run { DenIntents.spaces().filter { identifiers.contains($0.id) } }
  }
  public func suggestedEntities() async throws -> [SpaceEntity] { await MainActor.run { DenIntents.spaces() } }
  public func entities(matching string: String) async throws -> [SpaceEntity] {
    await MainActor.run { DenIntents.spaces().filter { $0.name.localizedCaseInsensitiveContains(string) } }
  }
}

public struct TabEntity: AppEntity, Sendable {
  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tab"
  public static let defaultQuery = TabQuery()
  public let id: String
  @Property(title: "Title") public var title: String
  @Property(title: "Address") public var url: URL?
  @Property(title: "Space") public var space: String
  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)", subtitle: "\(url?.host() ?? space)")
  }
  public init(id: String, title: String, url: URL?, space: String) {
    self.id = id
    self.title = title
    self.url = url
    self.space = space
  }
}

public struct TabQuery: EntityStringQuery {
  public init() {}
  public func entities(for identifiers: [String]) async throws -> [TabEntity] {
    await MainActor.run { DenIntents.tabs().filter { identifiers.contains($0.id) } }
  }
  public func suggestedEntities() async throws -> [TabEntity] { await MainActor.run { DenIntents.tabs() } }
  public func entities(matching string: String) async throws -> [TabEntity] { await MainActor.run { DenIntents.matching(string) } }
}

// MARK: Actions

public struct OpenPageIntent: AppIntent {
  public static let title: LocalizedStringResource = "Open URL in den"
  public static let description = IntentDescription("Opens a web address as a new tab, in the space you pick or the current one.")
  public static let openAppWhenRun = true
  @Parameter(title: "URL") public var url: URL
  @Parameter(title: "Space") public var space: SpaceEntity?
  public init() {}
  public init(url: URL, space: SpaceEntity? = nil) {
    self.url = url
    self.space = space
  }
  @MainActor public func perform() async throws -> some IntentResult {
    try DenIntents.open(url, in: space)
    return .result()
  }
}

public struct NewTabIntent: AppIntent {
  public static let title: LocalizedStringResource = "New Tab in den"
  public static let description = IntentDescription("Opens a new tab in a space: the address you give, or the command bar to type one.")
  public static let openAppWhenRun = true
  @Parameter(title: "Space") public var space: SpaceEntity?
  @Parameter(title: "URL") public var url: URL?
  public init() {}
  public init(space: SpaceEntity?, url: URL? = nil) {
    self.space = space
    self.url = url
  }
  @MainActor public func perform() async throws -> some IntentResult {
    if let url { try DenIntents.open(url, in: space); return .result() }
    if let space { _ = try DenIntents.call("spaces", "switch", ["id": .string(space.id)]) }
    // ⌘T: the command bar for a new tab; without it, a blank tab.
    if (try? DenIntents.call("commands", "open", ["mode": "new"])) == nil {
      _ = try DenIntents.call("tabs", "open", ["url": "about:blank"])
    }
    return .result()
  }
}

public struct SwitchSpaceIntent: AppIntent {
  public static let title: LocalizedStringResource = "Switch Space in den"
  public static let description = IntentDescription("Shows another space in den's window.")
  public static let openAppWhenRun = true
  @Parameter(title: "Space") public var space: SpaceEntity
  public init() {}
  public init(space: SpaceEntity) { self.space = space }
  @MainActor public func perform() async throws -> some IntentResult {
    _ = try DenIntents.call("spaces", "switch", ["id": .string(space.id)])
    return .result()
  }
}

public struct SearchTabsIntent: AppIntent {
  public static let title: LocalizedStringResource = "Find Tabs in den"
  public static let description = IntentDescription("Finds den's tabs whose title or address contains the text, in every space.")
  @Parameter(title: "Text") public var query: String
  public init() {}
  public init(query: String) { self.query = query }
  @MainActor public func perform() async throws -> some IntentResult & ReturnsValue<[TabEntity]> {
    .result(value: DenIntents.matching(query))
  }
}

public struct OpenTabIntent: AppIntent {
  public static let title: LocalizedStringResource = "Open Tab in den"
  public static let description = IntentDescription("Selects a tab, switching to its space.")
  public static let openAppWhenRun = true
  @Parameter(title: "Tab") public var tab: TabEntity
  public init() {}
  public init(tab: TabEntity) { self.tab = tab }
  @MainActor public func perform() async throws -> some IntentResult {
    _ = try DenIntents.call("tabs", "select", ["id": .string(tab.id)])
    return .result()
  }
}

public struct GetCurrentPageIntent: AppIntent {
  public static let title: LocalizedStringResource = "Get Current Page from den"
  public static let description = IntentDescription("The page in den's front window: its title and address. Never a private window's.")
  public init() {}
  @MainActor public func perform() async throws -> some IntentResult & ReturnsValue<TabEntity> {
    .result(value: try DenIntents.currentTab())
  }
}

public struct TogglePictureInPictureIntent: AppIntent {
  public static let title: LocalizedStringResource = "Toggle Picture in Picture in den"
  public static let description = IntentDescription("Puts the video playing in den in picture in picture, or brings it back (⌥⌘P).")
  public init() {}
  @MainActor public func perform() async throws -> some IntentResult {
    _ = try DenIntents.call("media", "toggle")
    return .result()
  }
}
