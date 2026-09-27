// cordis entry point for the `quit` plugin. The logic lives in QuitCore.swift.

nonisolated(unsafe) var quitCore: QuitCore?

struct Plugin: CordisPlugin {
  // `commands` is optional (commandbar plugin), so it is called but not injected.
  static let manifest = Manifest(name: "Quit", version: "0.1.0", inject: ["app", "ui", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = QuitCore(env: PluginEnv(ctx))
    quitCore = core
    core.start()
  }

  static func dispose() {
    quitCore?.stop()
    quitCore = nil
  }
}
