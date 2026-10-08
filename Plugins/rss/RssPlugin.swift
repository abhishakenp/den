// cordis entry point for the `rss` plugin. The logic lives in RssCore.swift.

nonisolated(unsafe) var rssCore: RssCore?

struct Plugin: CordisPlugin {
  // `net`, `connections`, `storage`, and `schedule` are optional: called, not injected.
  static let manifest = Manifest(name: "RSS", version: "0.1.0", inject: ["net", "storage", "schedule"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = RssCore(env: PluginEnv(ctx))
    rssCore = core
    core.start()
  }

  static func dispose() { rssCore = nil }
}