// cordis entry point for the `linear` plugin. The logic lives in LinearCore.swift.

nonisolated(unsafe) var linearCore: LinearCore?

struct Plugin: CordisPlugin {
  // `connections` is optional (the plugin registers with it when it loads).
  static let manifest = Manifest(name: "Linear", version: "0.1.0", inject: ["session", "net", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = LinearCore(env: PluginEnv(ctx))
    linearCore = core
    core.start()
  }

  static func dispose() { linearCore = nil }
}
