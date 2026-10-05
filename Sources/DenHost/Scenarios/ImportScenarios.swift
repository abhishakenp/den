// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue

/// `--scenario` states for the `importer` plugin, on a synthetic home (`ImportFixtures`): never
/// the user's own browsers' data, and System Settings is never opened (the URL is printed).
///
/// - `importCard`: the tips plugin's quiet import card (Arc, Safari, Chrome found).
/// - `importDialog`: "Import from…" with every fixture browser and the passwords row.
/// - `importArc`: an Arc import: its spaces, pinned tabs and folders in the sidebar, the summary toast.
/// - `importSafariAccess`: Safari without Full Disk Access: the one-line toast.
/// - `importE2E`: every source in a row, a second Arc import (nothing doubles) and Undo, checked
///   through the services; prints `scenario.import <step> ok=true|false …` lines and exits 0/1.
@MainActor
public enum ImportScenarios {
  public static let names = ["importCard", "importDialog", "importArc", "importSafariAccess", "importE2E"]

  public static func apply(_ name: String, runtime rt: DenRuntime) {
    rt.files.openURL = { print("scenario.import opened \($0.absoluteString)") }
    if name == "importCard" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        rt.plugins.emit("tips.preview", ["key": "import", "sources": [["id": "arc", "name": "Arc"], ["id": "safari", "name": "Safari"], ["id": "chrome", "name": "Chrome"]]])
      }
      return
    }
    let home: URL
    do { home = try ImportFixtures.makeHome() } catch {
      print("scenario.import fixtures failed: \(error)")
      exit(1)
    }
    rt.files.home = home
    if name == "importSafariAccess" {
      try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: home.appendingPathComponent("Library/Safari").path)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      switch name {
      case "importDialog": rt.call("importer", "open")
      case "importArc": print("scenario.import run \(rt.call("importer", "run", ["source": "arc"]))")
      case "importSafariAccess": print("scenario.import run \(rt.call("importer", "run", ["source": "safari"]))")
      case "importE2E": E2E(rt).start()
      default: break
      }
    }
  }

  /// Every source, one after the other, each checked when its `importer.done` arrives.
  @MainActor final class E2E {
    let rt: DenRuntime
    var ok = true
    var steps: [(String, Value, (Value) -> [String])] = []
    var batches: [String: String] = [:]
    var waiting: String?
    let started = Date()

    init(_ rt: DenRuntime) { self.rt = rt }

    func count(_ v: Value, _ k: String) -> Int64 { v[k].int ?? -1 }

    func start() {
      _ = rt.plugins.on("importer.done") { [self] v in MainActor.assumeIsolated { arrived(v) } }
      let spacesBefore = (rt.call("spaces", "list").array ?? []).count
      steps = [
        ("arc", ["source": "arc"], { [self] d in
          expect(d, ["spaces": 4, "pinned": 23, "today": 2, "favorites": 3, "history": 300])
        }),
        ("arc again", ["source": "arc"], { [self] d in
          expect(d, ["spaces": 0, "pinned": 0, "today": 0, "favorites": 0, "history": 0])
        }),
        ("chrome", ["source": "chrome"], { [self] d in expect(d, ["bookmarks": 9, "openTabs": 3, "history": 900]) }),
        ("safari", ["source": "safari"], { [self] d in expect(d, ["bookmarks": 5]) }),
        ("firefox", ["source": "firefox"], { [self] d in expect(d, ["bookmarks": 5]) }),
        ("zen", ["source": "zen"], { [self] d in
          var e = expect(d, ["spaces": 2, "pinned": 3, "favorites": 2, "bookmarks": 2])
          let n = rt.call("commands", "history")["count"].int ?? -1
          if n != 1200 { e.append("history total \(n) != 1200") }
          let names = (rt.call("spaces", "list").array ?? []).map { $0.str("name") }
          if names.count != spacesBefore + 3 { e.append("spaces \(names)") }
          return e
        }),
      ]
      next()
    }

    func expect(_ d: Value, _ want: [String: Int64]) -> [String] {
      want.keys.sorted().compactMap { k in count(d, k) == want[k]! ? nil : "\(k) \(count(d, k)) != \(want[k]!)" }
    }

    func next() {
      guard !steps.isEmpty else { return finish() }
      let (name, args, _) = steps[0]
      waiting = name
      let r = rt.call("importer", "run", args)
      if r.isError {
        print("scenario.import \(name) ok=false run: \(ValueJSON.string(r))")
        ok = false
        steps.removeFirst()
        next()
      }
    }

    func arrived(_ v: Value) {
      guard let name = waiting, !steps.isEmpty else { return }
      waiting = nil
      let (_, _, check) = steps.removeFirst()
      let errors = check(v)
      if !errors.isEmpty { ok = false }
      batches[name] = v.str("batch")
      print("scenario.import \(name) ok=\(errors.isEmpty) \(ValueJSON.string(v))\(errors.isEmpty ? "" : " errors=\(errors)")")
      // Let the toast and sidebar settle a moment between sources.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in next() }
    }

    func finish() {
      // Undo the first Arc import: its tabs, spaces and history go; the others' stay.
      let before = rt.call("commands", "history")["count"].int ?? -1
      let u = rt.call("importer", "undo", ["batch": .string(batches["arc"] ?? "")])
      let names = (rt.call("spaces", "list").array ?? []).map { $0.str("name") }
      let after = rt.call("commands", "history")["count"].int ?? -1
      let undoOK = !u.isError && !names.contains("Research") && names.contains("Home") && after == before
      if !undoOK { ok = false }
      // History Arc brought that Chrome also had stays (Chrome's batch added only what was new).
      print("scenario.import undo ok=\(undoOK) spaces=\(names) history=\(before)->\(after)")
      print("scenario.import done ok=\(ok) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(self.ok ? 0 : 1) }
    }
  }
}
#endif
