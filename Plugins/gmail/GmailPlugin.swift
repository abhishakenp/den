// cordis entry point for the `gmail` plugin. The logic lives in GmailCore.swift.

nonisolated(unsafe) var gmailCore: GmailCore?

struct Plugin: CordisPlugin {
  // `connections` is optional (the plugin registers with it when it loads).
  static let manifest = Manifest(name: "Gmail", version: "0.1.0", inject: ["session", "net", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = GmailCore(env: PluginEnv(ctx))
    gmailCore = core
    core.start()
  }

  static func dispose() { gmailCore = nil }
}
