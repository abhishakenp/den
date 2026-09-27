import Foundation
import WebKit

/// Bounded, event-driven waits for tests. Every wait has a deadline on the monotonic clock
/// (not a loop count, which stretches under load), names what it waits for (the watchdog prints
/// it), and returns early when the test task is cancelled (by the watchdog).
public enum Wait {
  @TaskLocal static var token: Int?

  /// Tells the watchdog what the current test is doing, for its timeout report.
  public static func note(_ what: String) {
    if let token { WatchdogMonitor.shared.note(token, what) }
  }

  /// Polls `cond` every `every` until it holds, `seconds` pass, or the task is cancelled.
  /// Returns whether it held.
  @MainActor
  public static func until(_ what: String = "a condition", seconds: Double = 20, every: Duration = .milliseconds(20),
                           file: StaticString = #fileID, line: UInt = #line, _ cond: @MainActor () async -> Bool) async -> Bool {
    note("\(what) (\(file):\(line), up to \(Int(seconds)) s)")
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
    while clock.now < end, !Task.isCancelled {
      if await cond() { return true }
      try? await Task.sleep(for: every)
    }
    return await cond()
  }

  /// Awaits a callback-style operation for at most `seconds`: nil on timeout or cancellation.
  /// A late callback is ignored. Unlike `withCheckedContinuation` alone, it can never hang.
  @MainActor
  public static func callback<T: Sendable>(_ what: String, seconds: Double = 20, file: StaticString = #fileID, line: UInt = #line,
                                           _ start: @MainActor (@escaping @Sendable (T) -> Void) -> Void) async -> T? {
    note("\(what) (\(file):\(line), up to \(Int(seconds)) s)")
    let once = Once<T?>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        once.set(cont)
        start { once.resume($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { once.resume(nil) }
      }
    } onCancel: {
      once.resume(nil)
    }
  }

  /// `evaluateJavaScript` with a deadline. A suspended or busy web content process otherwise
  /// leaves the await hanging forever.
  @MainActor
  public static func js(_ web: WKWebView, _ script: String, seconds: Double = 20, file: StaticString = #fileID, line: UInt = #line) async -> Any? {
    let r: JSResult? = await callback("JS `\(script.prefix(60))`", seconds: seconds, file: file, line: line) { done in
      web.evaluateJavaScript(script) { v, e in done(JSResult(value: v, error: e)) }
    }
    return r?.value
  }

  /// `callAsyncJavaScript` with a deadline (the script may `return` / `await`).
  @MainActor
  public static func asyncJS(_ web: WKWebView, _ script: String, world: WKContentWorld = .page, seconds: Double = 20,
                             file: StaticString = #fileID, line: UInt = #line) async -> Any? {
    let r: JSResult? = await callback("async JS `\(script.prefix(60))`", seconds: seconds, file: file, line: line) { done in
      web.callAsyncJavaScript(script, arguments: [:], in: nil, in: world) { res in
        switch res {
        case .success(let v): done(JSResult(value: v, error: nil))
        case .failure(let e): done(JSResult(value: nil, error: e))
        }
      }
    }
    return r?.value
  }
}

/// A JS result carried across the Sendable callback boundary (WebKit hands values back on main).
public struct JSResult: @unchecked Sendable {
  public let value: Any?
  public let error: Error?
}

/// Resumes a continuation exactly once, whoever gets there first.
final class Once<T: Sendable>: @unchecked Sendable {
  private enum State { case idle, waiting(CheckedContinuation<T, Never>), early(T), done }
  private let lock = NSLock()
  private var state = State.idle

  func set(_ c: CheckedContinuation<T, Never>) {
    lock.lock()
    switch state {
    case .early(let v):
      state = .done
      lock.unlock()
      c.resume(returning: v)
    default:
      state = .waiting(c)
      lock.unlock()
    }
  }

  /// First call wins; resuming before `set` (cancelled up front) is delivered by `set`.
  func resume(_ v: T) {
    lock.lock()
    switch state {
    case .waiting(let c):
      state = .done
      lock.unlock()
      c.resume(returning: v)
    case .idle:
      state = .early(v)
      lock.unlock()
    case .early, .done:
      lock.unlock()
    }
  }
}
