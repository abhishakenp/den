import AppKit

/// A modal permission dialog for sandboxed plugin access requests.
///
/// When a sandboxed plugin process needs access beyond its sandbox profile
/// (e.g., reading a file, reaching a new domain), the host presents this
/// dialog to the user before granting the request.
@MainActor
final class PluginPermissionDialog: FlippedView, Themable {
  /// Represents a single permission request from a sandboxed plugin.
  public struct Request: Sendable {
    /// The plugin that is requesting access.
    public var pluginID: String
    /// Plugin display name.
    public var pluginName: String
    /// The plugin's icon (SF symbol name or empty).
    public var icon: String
    /// The type of access being requested.
    public var accessType: AccessType
    /// Description text for the user.
    public var description: String
    /// The specific resource (domain, path, etc.) being accessed.
    public var resource: String
    /// Whether this is a recurring request (can remember choice).
    public var rememberChoice: Bool = true

    public init(
      pluginID: String,
      pluginName: String,
      icon: String = "",
      accessType: AccessType,
      description: String,
      resource: String = "",
      rememberChoice: Bool = true
    ) {
      self.pluginID = pluginID
      self.pluginName = pluginName
      self.icon = icon
      self.accessType = accessType
      self.description = description
      self.resource = resource
      self.rememberChoice = rememberChoice
    }
  }

  public enum AccessType: String, Sendable {
    case network  // Network access to a domain
    case file     // File system read access
    case keychain // Keychain access
    case storage  // Session storage access

    var title: String {
      switch self {
      case .network: return "Network Access"
      case .file: return "File Access"
      case .keychain: return "Keychain Access"
      case .storage: return "Session Storage"
      }
    }

    var icon: String {
      switch self {
      case .network: return "globe"
      case .file: return "folder"
      case .keychain: return "key"
      case .storage: return "externaldrive"
      }
    }
  }

  // UI components
  private let shieldIcon: NSImageView = {
    let iv = NSImageView()
    iv.image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "Sandbox")
    iv.image?.size = NSSize(width: 48, height: 48)
    iv.contentTintColor = .controlAccentColor
    return iv
  }()

  private let titleLabel: NSTextField = NSTextField(labelWithString: "")
  private let pluginNameLabel: NSTextField = NSTextField(labelWithString: "")
  private let descriptionLabel: NSTextField = NSTextField(labelWithString: "")
  private let resourceLabel: NSTextField = NSTextField(labelWithString: "")
  private let rememberCheckbox: NSButton = {
    let cb = NSButton(checkboxWithTitle: "Remember my choice", target: nil, action: nil)
    cb.controlSize = .small
    return cb
  }()
  private let denyButton: NSButton = {
    let b = NSButton(title: "Deny", target: nil, action: #selector(PluginPermissionDialog.denyPressed(_:)))
    b.bezelStyle = .push
    b.controlSize = .small
    return b
  }()
  private let allowButton: NSButton = {
    let b = NSButton(title: "Allow", target: nil, action: #selector(PluginPermissionDialog.allowPressed(_:)))
    b.bezelStyle = .push
    b.controlSize = .small
    b.keyEquivalent = ""
    return b
  }()

  // Callback for user decision
  var onDecision: ((Bool) -> Void)?
  private var palette = Palette(theme: Theme(), dark: true)

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 16
    layer?.cornerCurve = .continuous

    titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    pluginNameLabel.font = .systemFont(ofSize: 13)
    descriptionLabel.font = .systemFont(ofSize: 13)
    descriptionLabel.maximumNumberOfLines = 3
    descriptionLabel.lineBreakMode = .byWordWrapping
    pluginNameLabel.lineBreakMode = .byTruncatingMiddle
    resourceLabel.font = .systemFont(ofSize: 12)

    [shieldIcon, titleLabel, pluginNameLabel, descriptionLabel, resourceLabel, rememberCheckbox, denyButton, allowButton].forEach { addSubview($0) }
    resourceLabel.isHidden = true
    denyButton.isHidden = true
    allowButton.isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Present the dialog for a permission request.
  func present(for request: Request, from window: NSWindow?, palette p: Palette) {
    self.palette = p
    titleLabel.stringValue = request.accessType.title
    pluginNameLabel.stringValue = request.pluginName
    descriptionLabel.stringValue = request.description
    if !request.resource.isEmpty {
      resourceLabel.stringValue = "Resource: \(request.resource)"
      resourceLabel.isHidden = false
    } else {
      resourceLabel.isHidden = true
    }
    rememberCheckbox.state = .on
    onDecision = nil

    // Create a sheet window
    let sheetView = PluginPermissionDialog()
    sheetView.present(for: request, from: window, palette: p)

    let sheet = NSWindow()
    sheet.styleMask = [.borderless, .titled]
    sheet.titlebarAppearsTransparent = true
    sheet.title = ""
    sheet.isMovableByWindowBackground = true
    sheet.contentView = sheetView
    sheet.makeKeyAndOrderFront(nil)
    sheet.orderFrontRegardless()
    window?.beginSheet(sheet) { _ in
      sheet.close()
    }
  }

  @objc func denyPressed(_ sender: NSButton) {
    onDecision?(false)
    dismiss()
  }

  @objc func allowPressed(_ sender: NSButton) {
    onDecision?(true)
    dismiss()
  }

  private func dismiss() {
    onDecision = nil
    window?.close()
  }

  // MARK: Layout

  override func layout() {
    super.layout()
    let w = bounds.width, h = bounds.height
    let pad: CGFloat = 28
    let iconY = pad + 8
    shieldIcon.frame = NSRect(x: (w - 48) / 2, y: iconY, width: 48, height: 48)
    titleLabel.frame = NSRect(x: pad, y: h - pad - 90, width: w - 2 * pad, height: 24)
    pluginNameLabel.frame = NSRect(x: pad, y: h - pad - 110, width: w - 2 * pad, height: 17)
    let descY = h - pad - 135
    descriptionLabel.frame = NSRect(x: pad, y: descY, width: w - 2 * pad, height: 45)
    resourceLabel.frame = NSRect(x: pad, y: descY - 22, width: w - 2 * pad, height: 16)
    rememberCheckbox.frame = NSRect(x: pad, y: descY - 50, width: 180, height: 18)

    // Action buttons at bottom
    let btnY = h - pad - 36
    let btnW: CGFloat = 100
    let gap: CGFloat = 12
    denyButton.frame = NSRect(x: w / 2 - btnW - gap / 2, y: btnY, width: btnW, height: 28)
    allowButton.frame = NSRect(x: w / 2 + gap / 2, y: btnY, width: btnW, height: 28)
    denyButton.isHidden = false
    allowButton.isHidden = false
  }

  func apply(_ p: Palette) {
    titleLabel.textColor = p.textPrimary
    pluginNameLabel.textColor = p.textSecondary
    descriptionLabel.textColor = p.textSecondary
    resourceLabel.textColor = p.textTertiary
    shieldIcon.contentTintColor = p.accent
  }
}

/// A helper that manages presenting and tracking plugin permission decisions.
@MainActor
final class PluginPermissionManager {
  /// Cached decisions: pluginID + accessType -> allowed.
  private var cachedDecisions: [(pluginID: String, accessType: String, allowed: Bool)] = []
  /// The last window for presenting sheets.
  private weak var hostWindow: NSWindow?

  public init() {}

  /// Register the main window for sheet presentation.
  public func setHostWindow(_ window: NSWindow) {
    self.hostWindow = window
  }

  /// Check if a decision is cached.
  public func cachedDecision(for pluginID: String, accessType: String) -> Bool? {
    cachedDecisions.last { $0.pluginID == pluginID && $0.accessType == accessType }?.allowed
  }

  /// Record a user decision.
  public func recordDecision(_ decision: Bool, for pluginID: String, accessType: String) {
    // Remove old cached decision for this plugin+type
    cachedDecisions.removeAll { $0.pluginID == pluginID && $0.accessType == accessType }
    cachedDecisions.append((pluginID, accessType, decision))
  }

  /// Present a permission dialog and wait for the user's decision.
  public func requestPermission(
    request: PluginPermissionDialog.Request,
    shouldPrompt: Bool,
    palette: Palette
  ) async -> Bool {
    // Check cache first
    if let cached = cachedDecision(for: request.pluginID, accessType: request.accessType.rawValue) {
      return cached
    }
    // Silent deny if prompts are disabled
    guard shouldPrompt else { return false }

    return await withCheckedContinuation { continuation in
      let dialog = PluginPermissionDialog()
      dialog.present(for: request, from: hostWindow, palette: palette)
      dialog.onDecision = { allowed in
        if request.rememberChoice {
          self.recordDecision(allowed, for: request.pluginID, accessType: request.accessType.rawValue)
        }
        continuation.resume(returning: allowed)
      }
    }
  }
}