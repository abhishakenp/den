import DenHost
import Foundation

/// A manual clock for host services' deadlines (`HostSchedule`): nothing fires until the test
/// advances time, so a loaded machine can never turn a debounce or timeout into a flake.
@MainActor
public final class ManualClock {
  public private(set) var nowMs = 0
  private var timers: [(id: Int, at: Int, fire: @MainActor () -> Void)] = []
  private var nextId = 0

  public init() {}

  public var schedule: HostSchedule {
    { [weak self] ms, fire in
      guard let self else { return {} }
      self.nextId += 1
      let id = self.nextId
      self.timers.append((id, self.nowMs + ms, fire))
      return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }
  }

  public var pending: Int { timers.count }

  /// Moves time forward, firing every timer that comes due, in deadline order.
  public func advance(ms: Int) {
    let end = nowMs + ms
    while let next = timers.filter({ $0.at <= end }).min(by: { ($0.at, $0.id) < ($1.at, $1.id) }) {
      timers.removeAll { $0.id == next.id }
      nowMs = max(nowMs, next.at)
      next.fire()
    }
    nowMs = end
  }
}

extension Wait {
  /// One full turn of the main queue: everything already enqueued on it (e.g. a
  /// `DispatchQueue.main.async` delivery) has run when this returns. An event, not a sleep.
  @MainActor
  public static func mainQueueTurn() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
  }
}
