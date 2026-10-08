// cordis entry point for the `outlook` plugin. The logic lives in OutlookCore.swift.

nonisolated(unsafe) var outlookCore: OutlookCore?

struct Plugin: CordisPlugin {
  // `connections` is optional (the plugin registers with it when it loads).
  static let manifest = Manifest(name: "Outlook", version: "0.1.0", inject: ["session", "net", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = OutlookCore(env: PluginEnv(ctx))
    outlookCore = core
    core.start()
  }

  static func dispose() { outlookCore = nil }
}