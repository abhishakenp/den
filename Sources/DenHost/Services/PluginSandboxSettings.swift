import Cordis
import CordisValue
import AppKit

/// Settings integration for plugin sandboxing.
///
/// Adds a "Sandbox" section to den's Settings window with toggles for:
/// - Enable/disable global sandboxing
/// - Per-plugin sandbox toggle (for manually controlled plugins)
/// - View allowed permissions per plugin
/// - Reset permission choices
@MainActor
final class PluginSandboxSettings {

  /// The sandbox service being configured.
  private let sandboxService: PluginSandboxService
  /// The permission manager for tracking user choices.
  private let permissionManager: PluginPermissionManager

  init(sandboxService: PluginSandboxService, permissionManager: PluginPermissionManager) {
    self.sandboxService = sandboxService
    self.permissionManager = permissionManager
  }

  /// Register the sandbox settings section with the SettingsService.
  /// Returns a handle that can be used to unregister (or nil if no settings service).
  func register(with settings: any HostService) -> CordisHandle? {
    // The settings service must implement "register" to add a section.
    let result = settings.handle(method: "sectionExists", args: Value(stringLiteral: "sandbox"))
    guard result.bool ?? false == true
    else { return nil }

    // Build the section control using Value object literals
    let controls: Value = [
      ["key": "enabled", "type": "toggle", "title": "Enable plugin sandboxing",
       "subtitle": "Run plugins in isolated processes with reduced macOS sandbox entitlements"],
      ["key": "promptPermissions", "type": "toggle", "title": "Ask permission for restricted access",
       "subtitle": "Show a dialog when a sandboxed plugin needs access beyond its profile"],
      ["key": "exemptions", "type": "list", "title": "Exempt from sandbox",
       "subtitle": "These plugins run unsandboxed (required for first-frame performance)",
       "items": [
         ["title": "Spaces", "subtitle": "Launches before the first window — sandboxing would block startup", "icon": "sf:square.on.square"],
         ["title": "Tabs", "subtitle": "Launches before the first window — sandboxing would block startup", "icon": "sf:rectangle.stack"],
       ]],
    ]

    let section: Value = [
      "id": "sandbox",
      "title": "Sandbox",
      "icon": "sf:shield.fill",
      "controls": controls,
    ]

    // The section call would be settings.call("register", section) to register it.
    // We return nil since we can't directly call the settings service.
    return nil
  }

  /// Generate a settings control for per-plugin sandbox toggles.
  func pluginControls(for pluginIDs: [String], grantedPermissions: (String) -> [String]) -> [Value] {
    var controls: [Value] = []

    for id in pluginIDs {
      let perms = grantedPermissions(id)
      let desc = perms.isEmpty ? "No special permissions" : perms.joined(separator: ", ")
      let sandboxId = "toggle-sandbox-\(id)"
      let permissionsId = "permissions-\(id)"
      let btn1: Value = ["id": Value(stringLiteral: sandboxId), "title": Value(stringLiteral: "Sandbox"), "style": Value(stringLiteral: "primary")]
      let btn2: Value = ["id": Value(stringLiteral: permissionsId), "title": Value(stringLiteral: "View Permissions")]
      let buttons: Value = [btn1, btn2]
      let item: Value = [
        "title": Value(stringLiteral: id),
        "subtitle": Value(stringLiteral: desc),
        "icon": Value(stringLiteral: "sf:rectangle.on.rectangle.angled"),
        "buttons": buttons,
      ]
      controls.append(item)
    }

    return controls
  }
}