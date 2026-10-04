import DenHost
import Foundation
import WebKit

/// Nothing a test starts may outlive it. Every `DenRuntime` a test creates is registered here and
/// torn down when the test ends (web views closed with their WebKit page, speech stopped,
/// extension contexts unloaded, windows ordered out). Every den web view is page-muted from the
/// start, so tests never play sound. The WebContent pids each test used are appended to
/// `DEN_TEST_WEBKIT_LOG` (set by scripts/test.sh) as `pid<TAB>test`, so the script can check they
/// all exited, name the test of any that didn't, and kill it.
@MainActor
public enum Leaks {
  private static var installed = false
  /// Runtimes by the test (watchdog token) that created them. Suites run side by side in one
  /// process, so a test that ends must tear down only its own: tearing down every runtime closed
  /// other suites' live web views mid-test (their pages vanished, their waits timed out).
  private static var runtimes: [(owner: Int?, rt: DenRuntime)] = []
  private static let log = ProcessInfo.processInfo.environment["DEN_TEST_WEBKIT_LOG"]

  static func install() {
    guard !installed else { return }
    installed = true
    DenRuntime.onCreate = { rt in
      runtimes.append((Wait.token, rt))
      rt.webviews.createdHooks.append { _, w in mute(w) }
    }
  }

  /// WebKit's page mute (what den's tab mute uses): no sound from any frame, <video> or WebAudio.
  static func mute(_ w: WKWebView) {
    guard w.responds(to: NSSelectorFromString("_setPageMuted:")) else { return }
    w.setValue(NSNumber(value: 1), forKey: "pageMuted")
  }

  /// Tears down the runtimes test `token` created (and any created outside a test); logs their
  /// WebKit pids for `test`.
  static func tearDown(test: String, token: Int?) {
    let mine = { (e: (owner: Int?, rt: DenRuntime)) in e.owner == nil || e.owner == token }
    let list = runtimes.filter(mine)
    runtimes.removeAll(where: mine)
    var pids: [pid_t] = []
    for e in list { pids += e.rt.tearDown() }
    guard let log, !pids.isEmpty else { return }
    let lines = Set(pids).map { "\($0)\t\(test)\n" }.joined()
    if let h = FileHandle(forWritingAtPath: log) ?? { FileManager.default.createFile(atPath: log, contents: nil); return FileHandle(forWritingAtPath: log) }() {
      h.seekToEndOfFile()
      h.write(Data(lines.utf8))
      try? h.close()
    }
  }
}
