import AppKit
import Cordis
import CordisValue
import Foundation
import WebKit

@testable import DenHost
@testable import PluginCores

/// A real den runtime (host services on a cordis PluginHost) plus a PluginEnv wired to it, the
/// same way a plugin's Context is. The clock is fake so idle timers can be tested.
@MainActor
final class Harness {
  let rt: DenRuntime
  let root: URL
  var clock: Int64 = 1_800_000_000_000
  var events: [(String, Value)] = []
  var timers: [(UInt64, Bool, () -> Void)] = []

  init(root: URL? = nil) {
    _ = NSApplication.shared
    self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("den-plugin-\(UUID())")
    rt = DenRuntime(storageRoot: self.root)
    // Test windows are never on screen: keep pages running (see ServiceTests.runtime).
    rt.webviews.configureHooks.append { _, c in c.preferences.inactiveSchedulingPolicy = .none }
    rt.window.window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
    rt.window.window.contentView?.layoutSubtreeIfNeeded()
  }

  var env: PluginEnv {
    let rt = rt
    return PluginEnv(
      invoke: { s, m, a in MainActor.assumeIsolated { rt.call(s, m, a) } },
      emit: { e, p in MainActor.assumeIsolated { rt.plugins.emit(e, p) } },
      on: { e, h in MainActor.assumeIsolated { _ = rt.plugins.on(e, h) } },
      // Weak: a finished test's runtime can still get late WebKit events (title, url) that make
      // a core save or read the clock after the Harness is gone.
      timer: { [weak self] ms, r, h in MainActor.assumeIsolated { self?.timers.append((ms, r, h)) } },
      now: { [weak self] in MainActor.assumeIsolated { self?.clock ?? 0 } },
      log: { print("plugin:", $0) })
  }

  func record(_ names: [String]) {
    for n in names { rt.plugins.on(n) { [weak self] v in self?.events.append((n, v)) } }
  }

  func fireTimers() { for t in timers { t.2() } }

  func action(_ id: String, _ action: String, _ value: Value = .null) {
    rt.plugins.emit("ui.action", ["id": .string(id), "action": .string(action), "value": value])
  }

  func key(_ chord: String) {
    let b = rt.keys.bindings[chord]
    precondition(b != nil, "no binding for \(chord)")
    rt.plugins.emit(b!.event, ["chord": .string(chord), "payload": b!.payload])
  }

  func storage(_ ns: String, _ key: String) -> Value { rt.call("storage", "get", ["ns": .string(ns), "key": .string(key)]) }

  /// Starts the spaces core and provides the `spaces` service on the plugin host.
  @discardableResult
  func startSpaces() -> SpacesCore {
    let core = SpacesCore(env: env)
    rt.plugins.provide("spaces") { m, a in core.handle(m, a) }
    core.start()
    return core
  }

  /// Starts spaces (if needed) and tabs, like the real load order.
  @discardableResult
  func startTabs() -> TabsCore {
    if rt.plugins.serviceNames.contains("spaces") == false { startSpaces() }
    let core = TabsCore(env: env)
    rt.plugins.provide("tabs") { m, a in core.handle(m, a) }
    core.start()
    return core
  }

  func tabs(_ method: String, _ args: Value = .null) -> Value { rt.call("tabs", method, args) }
  var spaceIds: [String] { (rt.call("spaces", "list").array ?? []).map { $0.s("id") } }
  func ids(_ section: String, _ space: String? = nil) -> [String] {
    (tabs("list", space.map { ["spaceId": .string($0)] } ?? .null)[section].array ?? []).map { $0.s("id") }
  }
  var selected: String? { tabs("selected")["id"].string }
  /// Suspension is asynchronous (it snapshots first); wait for the view to go away.
  func waitUnloaded(_ id: String) async -> Bool {
    for _ in 0..<100 {
      if rt.call("webviews", "get", ["id": .string(id)])["live"] == false { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  /// The tree last rendered into a sidebar slot.
  func tree(_ slot: String, _ page: Int) -> Value { rt.ui.sidebarView.slot(slot, page: page)?.root?.node ?? .null }
}
