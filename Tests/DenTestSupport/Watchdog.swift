import Foundation
import Testing

/// Per-test watchdog. Every suite carries `.watchdog` (checked by `WatchdogCoverageTests`).
///
/// - Each test gets a wall-time limit (`DEN_TEST_LIMIT` seconds, default 120). When it runs out,
///   the test fails with its name, elapsed time and the last thing it said it was waiting on
///   (`Wait.note`, set by every bounded wait below), and its task is cancelled. The bounded waits
///   honour cancellation, so a timed-out test normally unwinds and the run continues.
/// - If it does not unwind within `DEN_TEST_GRACE` seconds (default 15; e.g. the main thread is
///   blocked in a modal loop), a watchdog *thread*, which needs neither the main thread nor the
///   cooperative pool, prints the same report plus a `sample` of the process and exits 1. A run
///   can fail; it can no longer hang.
public struct Watchdog: TestTrait, SuiteTrait, TestScoping {
  public let seconds: Double
  public var isRecursive: Bool { true }

  public func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
    // Suites pass through; the trait is recursive, so each test case gets its own scope.
    Invisible.install()
    await MainActor.run { Leaks.install() }
    guard testCase != nil, !test.isSuite else { return try await function() }
    let name = "\(test.id)"
    let limit = seconds
    let token = WatchdogMonitor.shared.begin(name, limit: limit)
    defer { WatchdogMonitor.shared.end(token) }
    try await Wait.$token.withValue(token) {
      try await withoutActuallyEscaping(function) { body in
        var failure: Error?
        do {
        try await withThrowingTaskGroup(of: Bool.self) { group in
          group.addTask { try await body(); return true }
          group.addTask {
            try? await Task.sleep(for: .seconds(limit))
            return false
          }
          // The first child to finish decides. `true`: the test body finished (or threw, which
          // rethrows here). `false`: the limit ran out first.
          let finished = try await group.next() ?? true
          if !finished {
            let report = WatchdogMonitor.shared.report(token, reason: "exceeded its \(Int(limit)) s limit")
            Issue.record(Comment(rawValue: report))
          }
          group.cancelAll()
          // Waits for the body to unwind (bounded by the monitor thread's grace period).
          while let next = try? await group.next() { _ = next }
        }
        } catch { failure = error }
        // Whatever the outcome: nothing the test started outlives it.
        await MainActor.run { Leaks.tearDown(test: name, token: token) }
        if let failure { throw failure }
      }
    }
  }
}

extension Trait where Self == Watchdog {
  /// The default per-test limit: `DEN_TEST_LIMIT` seconds, else 120.
  public static var watchdog: Watchdog { Watchdog(seconds: WatchdogMonitor.defaultLimit) }
  public static func watchdog(seconds: Double) -> Watchdog { Watchdog(seconds: seconds) }
}

/// Tracks running tests on a dedicated thread. Owns the hard stop.
public final class WatchdogMonitor: @unchecked Sendable {
  public static let shared = WatchdogMonitor()
  public static let defaultLimit = Double(ProcessInfo.processInfo.environment["DEN_TEST_LIMIT"] ?? "") ?? 120
  static let grace = Double(ProcessInfo.processInfo.environment["DEN_TEST_GRACE"] ?? "") ?? 15

  struct Entry {
    let name: String
    let start: Double
    let limit: Double
    var note = "nothing yet (no bounded wait has started)"
    var noteAt: Double
  }

  private let lock = NSLock()
  private var entries: [Int: Entry] = [:]
  private var next = 0
  private var mainBeat = WatchdogMonitor.now()
  private var thread: Thread?
  /// Set when the watchdog itself ends the run (its report is already out).
  nonisolated(unsafe) var stopping = false

  static func now() -> Double { ProcessInfo.processInfo.systemUptime }

  func begin(_ name: String, limit: Double) -> Int {
    lock.lock()
    defer { lock.unlock() }
    next += 1
    let t = Self.now()
    entries[next] = Entry(name: name, start: t, limit: limit, noteAt: t)
    if thread == nil {
      // Code under test that ends the process (exit, NSApp.terminate) would otherwise cut the run
      // short silently, with exit status 0: say who did it, and fail.
      atexit {
        let running = WatchdogMonitor.shared.runningNames()
        guard !running.isEmpty, !WatchdogMonitor.shared.stopping else { return }
        let stack = Thread.callStackSymbols.prefix(24).joined(separator: "\n    ")
        FileHandle.standardError.write(Data("\nWATCHDOG: the process is exiting while \(running.joined(separator: ", ")) is running. Stack:\n    \(stack)\n".utf8))
        _exit(1)
      }
      let th = Thread { [unowned self] in self.watch() }
      th.name = "den.test.watchdog"
      th.qualityOfService = .userInteractive
      thread = th
      th.start()
    }
    return next
  }

  func runningNames() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return entries.values.map(\.name).sorted()
  }

  func end(_ token: Int) {
    lock.lock()
    entries[token] = nil
    lock.unlock()
  }

  func note(_ token: Int, _ what: String) {
    lock.lock()
    entries[token]?.note = what
    entries[token]?.noteAt = Self.now()
    lock.unlock()
  }

  func report(_ token: Int, reason: String) -> String {
    lock.lock()
    defer { lock.unlock() }
    return describe(token, reason: reason)
  }

  private func describe(_ token: Int, reason: String) -> String {
    let t = Self.now()
    guard let e = entries[token] else { return "watchdog: test \(token) \(reason)" }
    let others = entries.filter { $0.key != token }.values.map { "\($0.name) (\(Int(t - $0.start)) s)" }.sorted()
    return """
      WATCHDOG: \(e.name) \(reason) after \(String(format: "%.1f", t - e.start)) s.
        waiting on: \(e.note) (since \(String(format: "%.1f", t - e.noteAt)) s)
        main thread last answered \(String(format: "%.1f", t - mainBeat)) s ago
        other running tests: \(others.isEmpty ? "none" : others.joined(separator: ", "))
      """
  }

  private func watch() {
    while true {
      Thread.sleep(forTimeInterval: 0.5)
      DispatchQueue.main.async { [self] in
        lock.lock()
        mainBeat = Self.now()
        lock.unlock()
      }
      lock.lock()
      let t = Self.now()
      let stuck = entries.first { t - $0.value.start > $0.value.limit + Self.grace }
      let text = stuck.map { describe($0.key, reason: "did not unwind \(Int(Self.grace)) s after its \(Int($0.value.limit)) s limit; stopping the run") }
      lock.unlock()
      guard let text else { continue }
      var out = "\n" + text + "\n"
      if let sample = Self.sampleMainThread() { out += "  main thread stack (sample): \(sample)\n" }
      FileHandle.standardError.write(Data(out.utf8))
      stopping = true
      exit(1)
    }
  }

  /// `sample` this process for 1 s; returns the path of the full report plus the main thread's
  /// innermost frames, or nil when `sample` is unavailable.
  static func sampleMainThread() -> String? {
    let path = NSTemporaryDirectory() + "den-watchdog-\(getpid()).txt"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    p.arguments = ["\(getpid())", "1", "-file", path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    // Symbolication is slow on a loaded machine (15 s was not enough at load 70).
    let end = now() + 90
    while p.isRunning, now() < end { Thread.sleep(forTimeInterval: 0.1) }
    if p.isRunning { p.terminate(); return "sample did not finish within 90 s" }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return path }
    // The first thread block is the main thread; keep its deepest few frames.
    let lines = text.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.contains("Thread_") }) else { return path }
    let block = lines[(start + 1)...].prefix { !$0.contains("Thread_") && !$0.isEmpty }
    let frames = block.suffix(12).map { $0.trimmingCharacters(in: .whitespaces) }
    return path + "\n    " + frames.joined(separator: "\n    ")
  }
}
