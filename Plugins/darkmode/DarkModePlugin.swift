// cordis entry point for the `darkmode` plugin. The logic lives in DarkModeCore.swift.

nonisolated(unsafe) var darkModeCore: DarkModeCore?

struct Plugin: CordisPlugin {
  // `commands`, `tabs` and `content` are optional (called, not injected).
  static let manifest = Manifest(name: "Dark Mode", version: "0.1.0", inject: ["pagestyle", "webviews", "ui", "storage"], provides: ["darkmode"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = DarkModeCore(env: PluginEnv(ctx))
    darkModeCore = core
    ctx.provide("darkmode") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() {
    darkModeCore?.stop()
    darkModeCore = nil
  }
}
