// cordis entry point for the `extensions` plugin. The logic lives in ExtensionsCore.swift.

nonisolated(unsafe) var extensionsCore: ExtensionsCore?

struct Plugin: CordisPlugin {
  // `commands` and `tabs` are optional, so they are called but not injected. The host `webext`
  // service is the WKWebExtension bridge; this plugin provides `extensions` (the page).
  static let manifest = Manifest(name: "Extensions", version: "0.1.0", inject: ["webext", "ui"], provides: ["extensions"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = ExtensionsCore(env: PluginEnv(ctx))
    extensionsCore = core
    ctx.provide("extensions") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() {
    extensionsCore?.stop()
    extensionsCore = nil
  }
}
