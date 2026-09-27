import Foundation

/// A one-shot deadline: runs the closure on the main actor after `ms` milliseconds and returns a
/// cancel. Host services with timeouts take one instead of calling `DispatchQueue.asyncAfter`
/// directly, so tests can replace wall-clock deadlines with a manual clock (a loaded machine then
/// can't turn "slow" into "timed out").
public typealias HostSchedule = @MainActor (_ ms: Int, _ fire: @escaping @MainActor () -> Void) -> () -> Void

public enum HostTimers {
  /// Real timers on the main queue.
  public static let main: HostSchedule = { ms, fire in
    let item = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
    return { item.cancel() }
  }
}
