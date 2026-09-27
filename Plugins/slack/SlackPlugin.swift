// cordis entry point for the `slack` plugin. The logic lives in SlackCore.swift.

nonisolated(unsafe) var slackCore: SlackCore?

struct Plugin: CordisPlugin {
  // `connections` is optional (the plugin registers with it when it loads).
  static let manifest = Manifest(name: "Slack", version: "0.1.0", inject: ["session", "net", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = SlackCore(env: PluginEnv(ctx))
    slackCore = core
    core.start()
  }

  static func dispose() { slackCore = nil }
}
