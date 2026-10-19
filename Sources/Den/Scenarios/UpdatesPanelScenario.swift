import AppKit
import CordisValue
import DenHost

/// `--scenario updatesPanel`: Settings ▸ Updates as it opens on a fresh store, then after a
/// (simulated, offline) check: the `updates` plugin is told the plugin manifest was unchanged
/// (`updates.fetched` 304), so "Last check" shows now. Each state is drawn to
/// `<storage>/updates-<n>.png` (off screen, `cacheDisplay`); then `scenario.done`.
@MainActor
enum UpdatesPanelScenario {
  static func start(rt: DenRuntime, storage: URL) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      rt.settings.open(section: "updates")
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        capture(storage, 1)
        rt.plugins.emit("updates.fetched", ["url": "https://raw.githubusercontent.com/abhishakenp/den/main/updates/plugins.json", "status": 304])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
          let st = rt.call("storage", "get", ["ns": "updates", "key": "state"])
          print("scenario.state lastCheck=\(st["lastCheck"]) lastResult=\(st["lastResult"])")
          capture(storage, 2)
          print("scenario.done")
          fflush(stdout)
        }
      }
    }
  }

  static func capture(_ storage: URL, _ n: Int) {
    guard let w = NSApp.windows.first(where: { $0.title == "Settings" }), let v = w.contentView,
          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { print("scenario.capture \(n) no window"); return }
    v.layoutSubtreeIfNeeded()
    v.cacheDisplay(in: v.bounds, to: rep)
    let url = storage.appendingPathComponent("updates-\(n).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("scenario.capture \(n) \(url.path)")
  }
}
