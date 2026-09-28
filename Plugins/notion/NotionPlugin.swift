// cordis entry point for the `notion` plugin. The logic lives in NotionCore.swift.

nonisolated(unsafe) var notionCore: NotionCore?

struct Plugin: CordisPlugin {
  // `connections` is optional (the plugin registers with it when it loads).
  static let manifest = Manifest(name: "Notion", version: "0.1.0", inject: ["session", "net", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = NotionCore(env: PluginEnv(ctx))
    notionCore = core
    core.start()
  }

  static func dispose() { notionCore = nil }
}
