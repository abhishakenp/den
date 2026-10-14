import AppKit
import CordisValue
import Darwin
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// YouTube against the real site: shields with its shipped lists and YouTube scriptlets, a long
/// video playing (muted) for `DEN_LIVE_MINUTES` (default 3) while more YouTube tabs open, then its
/// web process killed: the tab comes back by itself and the video resumes where it was.
/// Opt-in (network, minutes): `DEN_LIVE=1 scripts/test.sh --filter YouTubeLiveTests`.
/// Prints `LIVE …` lines with what it saw (web process footprint and CPU, the video's time).
@MainActor
@Suite(.serialized, .watchdog, .enabled(if: ProcessInfo.processInfo.environment["DEN_LIVE"] != nil))
struct YouTubeLiveTests {
  static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  /// Big Buck Bunny (10 min), a long video that isn't live.
  static let video = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
  static let others = ["https://www.youtube.com/watch?v=jNQXAC9IVRw", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://www.youtube.com/"]

  func until(_ seconds: Double, _ f: () async -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if await f() { return true }
      try await Task.sleep(for: .milliseconds(200))
    }
    return await f()
  }

  static func pid(_ w: WKWebView) -> Int32 { (w.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0 }

  /// A process's physical footprint (MB) and CPU time (s), from proc_pid_rusage.
  static func usage(_ pid: Int32) -> (mb: Int, cpu: Double)? {
    var ri = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &ri) { p in
      p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard ok == 0 else { return nil }
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let ns = Double(ri.ri_user_time + ri.ri_system_time) * Double(tb.numer) / Double(tb.denom)
    return (Int(ri.ri_phys_footprint / 1_048_576), ns / 1e9)
  }

  func shields(_ h: Harness) async throws {
    let res = h.root.appendingPathComponent("res")
    try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: res.appendingPathComponent("shields"), withDestinationURL: Self.repo.appendingPathComponent("Plugins/shields/resources"))
    h.rt.sitePolicy.resourceRoots = [res]
    let core = ShieldsCore(env: h.env)
    h.rt.plugins.provide("shields") { m, a in core.handle(m, a) }
    core.start()
    _ = try await until(240) { core.ready.count == 3 }
    print("LIVE shields ready=\(core.ready)")
  }

  func time(_ h: Harness, _ id: String) -> (t: Double, paused: Bool)? {
    guard let v = h.rt.webviews.record(id)?.media.video, let t = v["t"].double else { return nil }
    return (t, v["paused"].bool ?? true)
  }

  @Test(.timeLimit(.minutes(30))) func aLongVideoPlaysAndSurvivesItsWebProcess() async throws {
    let h = Harness()
    try await shields(h)
    var crashed: [String] = [], restored: [Value] = []
    h.rt.host.on("webviews.crashed") { crashed.append($0.str("id")) }
    h.rt.host.on("webviews.restored") { restored.append($0) }
    let id = h.rt.call("webviews", "create", ["id": "yt", "url": .string(Self.video)])["id"].string!
    h.rt.call("webviews", "setMuted", ["id": .string(id), "muted": true])
    _ = h.rt.call("content", "show", ["panes": [.string(id)]])
    let w = try #require(h.rt.webviews.record(id)?.webView)
    #expect(try await until(60) { (self.time(h, id)?.paused == false) })
    print("LIVE playing t=\(time(h, id)?.t ?? -1) pid=\(Self.pid(w))")

    // More YouTube tabs, each shown for a moment (their pages load and play), then back.
    for (i, u) in Self.others.enumerated() {
      let o = h.rt.call("webviews", "create", ["id": .string("yt\(i)"), "url": .string(u)])["id"].string!
      h.rt.call("webviews", "setMuted", ["id": .string(o), "muted": true])
      _ = h.rt.call("content", "show", ["panes": [.string(o)]])
      try await Task.sleep(for: .seconds(8))
    }
    _ = h.rt.call("content", "show", ["panes": [.string(id)]])
    _ = try? await w.callAsyncJavaScript("const v = document.querySelector('video'); if (v && v.paused) v.play(); return 1", contentWorld: .defaultClient)

    // Play for a few minutes: the page lives, the video advances, nothing crashes.
    let minutes = Double(ProcessInfo.processInfo.environment["DEN_LIVE_MINUTES"] ?? "3") ?? 3
    let end = Date().addingTimeInterval(minutes * 60)
    let pid0 = Self.pid(w)
    var lastT = -1.0, lastCPU = Self.usage(pid0)?.cpu ?? 0, lastAt = Date()
    while Date() < end {
      try await Task.sleep(for: .seconds(15))
      let u = Self.usage(Self.pid(w))
      let now = Date()
      let cpu = u.map { ($0.cpu - lastCPU) / now.timeIntervalSince(lastAt) * 100 } ?? -1
      lastCPU = u?.cpu ?? lastCPU; lastAt = now
      let t = time(h, id)?.t ?? -1
      print("LIVE t=\(String(format: "%.1f", t)) pid=\(Self.pid(w)) footprint=\(u?.mb ?? -1)MB cpu=\(String(format: "%.1f", cpu))% crashed=\(crashed)")
      #expect(t > lastT, "the video stopped advancing at \(t)")
      lastT = t
    }
    #expect(crashed.isEmpty, "web processes died while playing: \(crashed)")
    #expect(Self.pid(w) == pid0)

    // The web process dies (as a WebKit crash or a memory kill would): back by itself, resumed.
    let before = try #require(time(h, id)).t
    #expect(Darwin.kill(Self.pid(w), SIGKILL) == 0)
    #expect(try await until(20) { !restored.isEmpty })
    #expect(try await until(60) {
      guard let now = self.time(h, id) else { return false }
      return !now.paused && now.t >= before - 6 && now.t <= before + 30
    })
    print("LIVE restored=\(restored) before=\(String(format: "%.1f", before)) after=\(String(format: "%.1f", time(h, id)?.t ?? -1)) url=\(w.url?.absoluteString ?? "-")")
    #expect(h.rt.webviews.record(id)?.resume == nil)
    #expect(w.title != "This page crashed")
  }
}
