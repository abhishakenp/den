// cordis entry point for the `confluence` plugin. The logic lives in ConfluenceCore.swift.

nonisolated(unsafe) var confluenceCore: ConfluenceCore?

struct Plugin: CordisPlugin {
  // `connections` is optional (the plugin registers with it when it loads).
  static let manifest = Manifest(name: "Confluence", version: "0.1.0", inject: ["session", "net", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = ConfluenceCore(env: PluginEnv(ctx))
    confluenceCore = core
    core.start()
  }

  static func dispose() { confluenceCore = nil }
}