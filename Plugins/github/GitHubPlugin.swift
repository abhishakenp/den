// cordis entry point for the `github` plugin. The logic lives in GitHubCore.swift.

nonisolated(unsafe) var githubCore: GitHubCore?

struct Plugin: CordisPlugin {
  // `connections` is optional (the plugin registers with it when it loads).
  static let manifest = Manifest(name: "GitHub", version: "0.1.0", inject: ["session", "net", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = GitHubCore(env: PluginEnv(ctx))
    githubCore = core
    core.start()
  }

  static func dispose() { githubCore = nil }
}
