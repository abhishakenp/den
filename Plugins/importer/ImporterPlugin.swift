// cordis entry point for the `importer` plugin. The logic lives in ImporterCore.swift.

nonisolated(unsafe) var importerCore: ImporterCore?

struct Plugin: CordisPlugin {
  // `tabs`, `spaces`, `commands`, `settings` and `vault` are called when they exist, not injected.
  static let manifest = Manifest(name: "Importer", version: "0.1.0", inject: ["ui", "storage", "files"], provides: ["importer"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = ImporterCore(env: PluginEnv(ctx))
    importerCore = core
    ctx.provide("importer") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() {
    importerCore?.stop()
    importerCore = nil
  }
}
