import Cordis
import CordisValue
import Foundation

/// Manages sandboxed plugin processes: spawning, lifecycle, and XPC routing.
///
/// Each sandboxed plugin runs as a separate process with its own macOS sandbox
/// profile.  The host communicates with the helper via XPC using the
/// `PluginSandboxProtocol`.
///
/// Sandbox mode is opt-in per plugin (sidecar `"sandbox": true`) or global
/// (`~/.den/config.toml` `[sandbox] enabled = true`).  First-frame plugins
/// (spaces, tabs) always run unsandboxed to avoid blocking the first window.
@MainActor
final class PluginSandboxService: @unchecked Sendable {

  /// Global sandbox policy from `~/.den/config.toml`.
  public struct Policy: Sendable {
    /// Whether sandboxing is enabled globally.
    public var enabled: Bool = false
    /// Plugin ids that are exempt (e.g. first-frame plugins).
    public var exemptions: Set<String> = ["spaces", "tabs"]
    /// Whether to show permission dialogs for sandboxed plugins.
    public var promptPermissions: Bool = true
    /// Maximum number of sandboxed plugin processes.
    public var maxProcesses: Int = 32

    public init() {}
  }

  /// Status of a sandboxed plugin process.
  /// NOT Sendable because NSXPCConnection is not Sendable.
  public enum ProcessStatus: Equatable {
    case notLoaded
    case spawning
    case running
    case failed(String)
    case stopped
  }

  private let policy: Policy
  private let generator = SandboxProfileGenerator()
  /// Plugin id -> its sandbox profile.
  private var profiles: [String: PluginSandboxProfile] = [:]
  /// Plugin id -> its process status.
  private var processes: [String: ProcessStatus] = [:]
  /// Directory for generated .sb profile files.
  private let profileDirectory: URL
  /// Whether the sandbox subsystem is available.
  private let sandboxAvailable: Bool

  public init(policy: Policy = Policy(), profileDirectory: URL? = nil) {
    self.policy = policy
    let resolvedDir = profileDirectory
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("den-plugin-sandbox-profiles", isDirectory: true)
    self.profileDirectory = resolvedDir
    // Check if sandbox-exec is available (macOS 10.11+)
    self.sandboxAvailable = FileManager.default.isExecutableFile(
      atPath: "/usr/bin/sandbox-exec"
    )
    try? FileManager.default.createDirectory(at: resolvedDir, withIntermediateDirectories: true)
  }

  /// Whether sandboxing can be used at all on this system.
  public var isAvailable: Bool { sandboxAvailable }

  /// Whether a plugin should run sandboxed given its id and the current policy.
  public func shouldSandbox(_ pluginID: String) -> Bool {
    guard policy.enabled else { return false }
    guard !policy.exemptions.contains(pluginID) else { return false }
    return true
  }

  /// Generate (or reuse) the sandbox profile for a plugin.
  public func generateProfile(for pluginID: String, permissions: Permissions) async -> PluginSandboxProfile? {
    // Check if we already have a profile for this plugin
    if let existing = profiles[pluginID] { return existing }

    let profile = permissions.buildSandboxProfile(for: pluginID)
    profiles[pluginID] = profile
    return profile
  }

  /// Spawn a sandboxed helper process for the given plugin.
  public func spawnPlugin(
    pluginID: String,
    dylibPath: String,
    profile: PluginSandboxProfile,
    host: PluginHost
  ) async throws -> ProcessStatus {
    guard isAvailable else {
      throw SandboxError.sandboxNotAvailable
    }
    guard policy.maxProcesses > processes.values.filter { $0 != .stopped && $0 != .notLoaded }.count else {
      throw SandboxError.maxProcessesExceeded
    }

    processes[pluginID] = .spawning

    // Write the sandbox profile to disk
    let profileURL = try generator.writeProfile(profile, to: profileDirectory)

    // Build the helper process command
    let helperURL = PluginSandboxService.helperBundledPath()
    guard FileManager.default.fileExists(atPath: helperURL.path) else {
      processes[pluginID] = .failed("Plugin sandbox helper not found at \(helperURL.path)")
      throw SandboxError.helperNotFound
    }

    // Launch the sandboxed process
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments = [
      "-f", profileURL.path,
      helperURL.path,
      "--plugin-id", pluginID,
      "--plugin-dylib", dylibPath,
      "--plugin-profile", profileURL.path,
    ]

    // Inherit environment minus sensitive variables
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "CORDIS_TOOLCHAIN")
    env["DEN_SANDBOX_MODE"] = "1"
    process.environment = env

    let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessStatus, Error>) in
      // NOTE: In a real implementation, the helper process would:
      // 1. Load the plugin dylib via dlopen
      // 2. Create an NSXPCServiceListener
      // 3. Expose PluginSandboxProtocol
      // 4. The host connects via NSXPCConnection to the listener
      //
      // For now, this is a structured stub that records the intent.
      // The actual XPC connection and dylib loading happens in the
      // PluginSandboxHelper target (a separate Xcode target).

      let status = ProcessStatus.running
      processes[pluginID] = status
      continuation.resume(returning: status)
    }

    return status
  }

  /// Terminate a sandboxed plugin process.
  public func terminatePlugin(_ pluginID: String) async {
    guard var status = processes[pluginID] else { return }
    switch status {
    case .running:
      processes[pluginID] = .stopped
    case .spawning:
      processes[pluginID] = .stopped
    default:
      break
    }
  }

  /// Call a service method on a sandboxed plugin process via XPC.
  public func callPlugin(
    _ pluginID: String,
    service: String,
    method: String,
    args: Value
  ) async -> Value {
    guard let status = processes[pluginID], case .running = status else {
      return .error("plugin \(pluginID) is not running sandboxed")
    }

    // In a real implementation, this would use the NSXPCConnection's
    // remoteObjectProxy to call the PluginSandboxProtocol:
    //
    //   let proxy = conn.remoteObjectProxy as! PluginSandboxProtocol
    //   let result = await proxy.invoke(service: service, method: method, args: xpcArgs)
    //   return PluginXPCValue.fromXPC(result).toValue()
    //
    // For this implementation, we return a stub that records the call.
    return .error("stub: XPC call to \(pluginID).\(service).\(method)")
  }

  /// Reload a sandboxed plugin (terminate and respawn).
  public func reloadPlugin(
    pluginID: String,
    dylibPath: String,
    profile: PluginSandboxProfile,
    host: PluginHost
  ) async throws {
    await terminatePlugin(pluginID)
    _ = try await spawnPlugin(pluginID: pluginID, dylibPath: dylibPath, profile: profile, host: host)
  }

  /// Stop all sandboxed plugin processes.
  public func stopAll() async {
    for id in processes.keys { await terminatePlugin(id) }
    processes.removeAll()
  }

  // MARK: Private

  /// Path to the bundled sandbox helper binary.
  nonisolated static func helperBundledPath() -> URL {
    let url = Bundle.main.resourceURL?
      .appendingPathComponent("den-plugin-helper")
    return url ?? URL(fileURLWithPath: "/usr/local/bin/den-plugin-helper")
  }
}

/// Errors that can occur during sandboxed plugin lifecycle.
public enum SandboxError: Error, LocalizedError {
  case sandboxNotAvailable
  case helperNotFound
  case profileGenerationFailed(String)
  case maxProcessesExceeded
  case processSpawnFailed(String)
  case xpcConnectionFailed(String)

  public var errorDescription: String? {
    switch self {
    case .sandboxNotAvailable:
      return "macOS sandbox-exec is not available on this system"
    case .helperNotFound:
      return "Plugin sandbox helper binary not found"
    case .profileGenerationFailed(let reason):
      return "Failed to generate sandbox profile: \(reason)"
    case .maxProcessesExceeded:
      return "Maximum number of sandboxed plugin processes reached"
    case .processSpawnFailed(let reason):
      return "Failed to spawn sandboxed process: \(reason)"
    case .xpcConnectionFailed(let reason):
      return "XPC connection failed: \(reason)"
    }
  }
}