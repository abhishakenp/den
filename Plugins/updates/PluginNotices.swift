// Notices about den's own plugins and ~/.den, as toasts (docs/architecture/thin-host.md §6 step 2:
// the host reports what happened, this plugin owns the words):
//   plugins.crashed {ids}                       plugins cordis refused at launch (they crashed den)
//   plugins.failed {id, stage: load|build, reason, log?}  a ~/.den plugin didn't load or build
//   plugins.failed {stage: toolchain, reason: noCordisBuild|noEmbeddedSwift}
//   config.changed {edited: true}               config.toml was edited: its first problem, if any
// The host still logs every one of these to plugins.log, so nothing is lost if this plugin isn't
// loaded (or is the one that crashed).

#if !hasFeature(Embedded)
  import CordisValue
#endif

extension UpdatesCore {
  func startNotices() {
    env.on("plugins.crashed") { [self] v in
      let ids = v.a("ids").compactMap { $0.string }
      guard !ids.isEmpty else { return }
      var names = ""
      for id in ids { names += (names.isEmpty ? "" : ", ") + "“" + id + "”" }
      let text = ids.count == 1 ? "The " + names + " plugin crashed den and was turned off" : "Plugins " + names + " crashed den and were turned off"
      notice(text, icon: "sf:exclamationmark.triangle.fill")
    }
    env.on("plugins.failed") { [self] v in
      let id = v.s("id"), reason = v.s("reason")
      switch v.s("stage") {
      case "load": notice("Plugin “" + id + "” didn't load: " + reason)
      case "build": notice("Plugin “" + id + "” didn't build: " + reason + " (~/.den/logs/build-" + id + ".log)")
      case "toolchain":
        notice(reason == "noCordisBuild" ? "den can't find cordis-build (its bundled copy is missing)"
          : "Source plugins need a Swift toolchain with Embedded Swift (swift.org, or set CORDIS_TOOLCHAIN)")
      default: break
      }
    }
    env.on("config.changed") { [self] v in
      guard v.b("edited") else { return }
      // After every plugin has applied the new config (they report their problems to `config`).
      env.timer(1, false) { [self] in
        for e in env.call("config", "errors").array ?? [] {
          if let s = e.string, Text.hasPrefix(s, "config.toml") {
            notice(s)
            return
          }
        }
      }
    }
  }

  func notice(_ text: String, icon: String = "sf:puzzlepiece.extension") {
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": .string(icon), "duration": 6000]])
  }
}
