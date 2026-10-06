// cordis entry point for the `jira` plugin. The logic lives in JiraCore.swift.

nonisolated(unsafe) var jiraCore: JiraCore?

struct Plugin: CordisPlugin {
  // `connections` is optional (the plugin registers with it when it loads).
  static let manifest = Manifest(name: "Jira", version: "0.1.0", inject: ["session", "net", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = JiraCore(env: PluginEnv(ctx))
    jiraCore = core
    core.start()
  }

  static func dispose() { jiraCore = nil }
}
