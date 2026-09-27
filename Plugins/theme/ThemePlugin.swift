// cordis entry point for the `theme` plugin. The logic lives in ThemeCore.swift and ThemeRules.swift.

nonisolated(unsafe) var themeCore: ThemeCore?

struct Plugin: CordisPlugin {
  // `commands` is optional (commandbar plugin), so it is called but not injected.
  static let manifest = Manifest(name: "Theme", version: "0.1.0", inject: ["spaces", "window", "ui", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = ThemeCore(env: PluginEnv(ctx))
    themeCore = core
    core.start()
  }

  static func dispose() {
    themeCore?.stop()
    themeCore = nil
  }
}
