import AppKit
import CordisValue

/// `pwa_dock` service: registers installed PWAs as custom dock tiles and manages their dock
/// presence. Each installed app appears with its manifest icon in the macOS Dock.
@MainActor
public final class PwaDockService: HostService {
  public let name = "pwa_dock"
  private let host: ServiceHost
  private let storage: StorageService
  /// Registered dock entries: appId -> {name, iconUrl, badge?}
  private var docks: [String: DockEntry] = [:]
  /// The last icon downloaded.
  private var currentIcon: NSImage?
  /// The dock tile's image view (reused across icon updates).
  private lazy var iconView: NSImageView = {
    let v = NSImageView()
    v.imageScaling = .scaleProportionallyDown
    return v
  }()
  /// Pending icon download tasks keyed by URL.
  private var pendingDownloads: [String: URLSessionDataTask?] = [:]

  public struct DockEntry {
    var appId: String
    var name: String
    var iconUrl: String
    var badge: String?
  }

  public init(host: ServiceHost, storage: StorageService) {
    self.host = host
    self.storage = storage
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "register":
      let appId = args.str("appId")
      guard !appId.isEmpty else { return .error("pwa_dock: missing appId") }
      let name = args.str("name")
      guard !name.isEmpty else { return .error("pwa_dock: missing name") }
      let iconUrl = args.str("icon")
      guard !iconUrl.isEmpty else { return .error("pwa_dock: missing icon") }
      let badge = args["badge"].string
      docks[appId] = DockEntry(appId: appId, name: name, iconUrl: iconUrl, badge: badge)
      // If this is the first PWA, update the dock tile.
      if docks.count == 1 {
        updateDockTile(name: name, iconUrl: iconUrl, badge: badge)
      }
      return .ok
    case "unregister":
      let appId = args.str("appId")
      docks.removeValue(forKey: appId)
      if docks.isEmpty {
        currentIcon = nil
        resetDockTile()
      } else if let last = docks.values.first {
        // The unregistered app may have been the current one; pick another.
        updateDockTile(name: last.name, iconUrl: last.iconUrl, badge: last.badge)
      }
      return .ok
    case "list":
      return ["docks": .array(docks.values.sorted { $0.appId < $1.appId }.map { e in
        ["appId": .string(e.appId), "name": .string(e.name), "icon": .string(e.iconUrl),
         "badge": e.badge.map { .string($0) } ?? .null]
      })]
    case "get":
      let appId = args.str("appId")
      if let entry = docks[appId] {
        return ["name": .string(entry.name), "icon": .string(entry.iconUrl),
                "badge": entry.badge.map { .string($0) } ?? .null]
      }
      return .null
    case "badge":
      let appId = args.str("appId")
      let badge = args["badge"].string
      if var entry = docks[appId] {
        entry.badge = badge
        docks[appId] = entry
        updateDockTile(name: entry.name, iconUrl: entry.iconUrl, badge: entry.badge)
      }
      return .ok
    default:
      return .error("pwa_dock: unknown method '\(method)'")
    }
  }

  // MARK: Dock tile management

  private func updateDockTile(name: String, iconUrl: String, badge: String?) {
    guard !iconUrl.isEmpty else {
      badgeLabel = badge ?? ""
      return
    }
    guard let url = URL(string: iconUrl) else {
      badgeLabel = badge ?? ""
      return
    }
    // If we already have this icon loaded, just set it.
    if currentIcon != nil {
      iconView.image = currentIcon
      badgeLabel = badge ?? ""
      display()
      return
    }
    // Download the icon asynchronously.
    let currentUrl = url.absoluteString
    pendingDownloads[currentUrl]?.map { $0.cancel() }
    let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
      guard let self else { return }
      DispatchQueue.main.async {
        self.pendingDownloads[currentUrl] = nil
        guard let data, error == nil else {
          self.badgeLabel = badge ?? ""
          self.display()
          return
        }
        guard let image = NSImage(data: data) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let size = scale >= 2 ? NSSize(width: 128, height: 128) : NSSize(width: 64, height: 64)
        image.size = size
        self.currentIcon = image
        self.iconView.image = image
        self.badgeLabel = badge ?? ""
        self.display()
      }
    }
    pendingDownloads[currentUrl] = task
    task.resume()
  }

  private func resetDockTile() {
    currentIcon = nil
    iconView.image = nil
    badgeLabel = ""
    display()
  }

  // MARK: NSDockTile wrapper

  private var badgeLabel: String {
    get { NSApp.dockTile.badgeLabel ?? "" }
    set { NSApp.dockTile.badgeLabel = newValue }
  }

  private func display() {
    NSApp.dockTile.contentView = iconView
    NSApp.dockTile.display()
  }

  /// Get icon data for a PWA app URL (for the sidebar dock slot).
  public func iconForApp(_ appId: String) -> String? {
    docks[appId]?.iconUrl
  }
}