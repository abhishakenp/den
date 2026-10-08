// Live folders: a pinned folder filled by a connection instead of tabs (Zen's live folders,
// Dia's live groups). The `Source` type and registration live here so all plugins can share it.
// Per-folder state (seen keys, done items, closed stacks) persists in storage ns `tabs` key `live`.

#if !hasFeature(Embedded)
  import CordisValue
#endif

/// A live folder source. Registered once per source; the tabs plugin owns the UI for each live folder.
public struct LiveFolders {
  public var id: String
  public var title: String
  public var icon: String

  public init(id: String, title: String, icon: String) {
    self.id = id
    self.title = title
    self.icon = icon
  }
}

public extension LiveFolders {
  /// Registry of live folder sources. The `tabs` plugin owns the UI and state.
  static var sources: [LiveFolders] = [
    LiveFolders(id: "github", title: "GitHub", icon: "https://github.com/favicon.ico"),
  ]

  static func registerSource(_ source: LiveFolders) {
    guard !sources.contains(where: { $0.id == source.id }) else { return }
    sources.append(source)
  }
}