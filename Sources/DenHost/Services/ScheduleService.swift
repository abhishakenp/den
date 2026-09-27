import AppKit
import CordisValue

/// `schedule` service: daily and interval triggers for plugins.
///
///   daily {id, hour, minute}   -> ok. Fires `schedule.fire {id, reason: "time"}` every day at that local
///                                 time. If den wasn't running (or the Mac slept) at that time, it
///                                 fires once with `reason: "catchup"` at launch/registration or wake,
///                                 unless it already fired since. The last fire time persists across
///                                 launches (storage ns `_schedule`); the first registration never
///                                 catches up.
///   interval {id, ms, wake?}   -> ok. Fires `{id, reason: "interval"}` every `ms` (min 60 s), and with
///                                 `wake: true` also `{id, reason: "wake"}` after the Mac wakes.
///   cancel {id}                -> ok
///   list                       -> [{id, kind, hour?, minute?, ms?, next}]  (`next` in ms since 1970)
///   clock {ms?}                -> {ms, hour, minute, weekday, date ("Sunday, September 27"), time ("8:02 AM"), offsetMinutes}
/// Plugins re-register on every launch (registrations live in memory); only fire times persist.
@MainActor
public final class ScheduleService: HostService {
  public let name = "schedule"
  let host: ServiceHost
  let storage: StorageService
  static let ns = "_schedule"

  struct Entry {
    var id: String
    var daily: (hour: Int, minute: Int)?
    var ms: Int64 = 0
    var wake = false
    var next: Date
  }

  private var entries: [String: Entry] = [:]
  private var timer: DispatchSourceTimer?
  private var wakeObserver: NSObjectProtocol?
  public var now: () -> Date = Date.init
  public var calendar = Calendar.current

  public init(host: ServiceHost, storage: StorageService) {
    self.host = host
    self.storage = storage
  }

  public func handle(method: String, args: Value) -> Value {
    let id = args.str("id")
    switch method {
    case "daily":
      guard !id.isEmpty else { return .error("schedule: id required") }
      let h = Int(args.num("hour", -1)), m = Int(args.num("minute", 0))
      guard (0...23).contains(h), (0...59).contains(m) else { return .error("schedule: hour 0–23, minute 0–59") }
      let t = now()
      var e = Entry(id: id, daily: (h, m), next: nextDaily(h, m, after: t))
      let last = lastFired(id)
      let todays = todayAt(h, m, t)
      entries[id] = e
      if let last {
        if todays <= t && last < todays {
          e.next = nextDaily(h, m, after: t)
          entries[id] = e
          fireSoon(id, "catchup")
        }
      } else {
        setLastFired(id, t)  // first registration: nothing to catch up on
      }
      start()
      return .ok
    case "interval":
      guard !id.isEmpty else { return .error("schedule: id required") }
      let ms = max(60_000, Int64(args.num("ms", 0)))
      entries[id] = Entry(id: id, daily: nil, ms: ms, wake: args.flag("wake"), next: now().addingTimeInterval(Double(ms) / 1000))
      start()
      return .ok
    case "cancel":
      entries[id] = nil
      return .ok
    case "clock":
      // Local time for plugins (they have no Foundation, so no time zone): `ms?` (default now).
      let d = args["ms"].double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now()
      let c = calendar.dateComponents([.hour, .minute, .weekday], from: d)
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = calendar.timeZone
      f.dateFormat = "EEEE, MMMM d"
      let date = f.string(from: d)
      f.dateFormat = "h:mm a"
      return ["ms": .double(d.timeIntervalSince1970 * 1000), "hour": .int(Int64(c.hour ?? 0)), "minute": .int(Int64(c.minute ?? 0)),
              "weekday": .int(Int64(c.weekday ?? 1)), "date": .string(date), "time": .string(f.string(from: d)),
              "offsetMinutes": .int(Int64(calendar.timeZone.secondsFromGMT(for: d) / 60))]
    case "list":
      return .array(entries.values.sorted { $0.id < $1.id }.map { e in
        var v: Value = ["id": .string(e.id), "kind": .string(e.daily == nil ? "interval" : "daily"), "next": .double(e.next.timeIntervalSince1970 * 1000)]
        if let d = e.daily { v = v.with("hour", .int(Int64(d.hour))).with("minute", .int(Int64(d.minute))) } else { v = v.with("ms", .int(e.ms)) }
        return v
      })
    default:
      return .error("schedule: unknown method '\(method)'")
    }
  }

  func todayAt(_ h: Int, _ m: Int, _ t: Date) -> Date {
    calendar.date(bySettingHour: h, minute: m, second: 0, of: t) ?? t
  }

  func nextDaily(_ h: Int, _ m: Int, after t: Date) -> Date {
    let today = todayAt(h, m, t)
    return today > t ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400))
  }

  func lastFired(_ id: String) -> Date? {
    storage.handle(method: "get", args: ["ns": .string(Self.ns), "key": .string(id)]).double.map { Date(timeIntervalSince1970: $0 / 1000) }
  }

  func setLastFired(_ id: String, _ d: Date) {
    _ = storage.handle(method: "set", args: ["ns": .string(Self.ns), "key": .string(id), "value": .double(d.timeIntervalSince1970 * 1000)])
  }

  func fireSoon(_ id: String, _ reason: String) {
    DispatchQueue.main.async { [weak self] in self?.fire(id, reason) }
  }

  func fire(_ id: String, _ reason: String) {
    guard entries[id] != nil else { return }
    if entries[id]?.daily != nil { setLastFired(id, now()) }
    host.emit("schedule.fire", ["id": .string(id), "reason": .string(reason)])
  }

  /// Checks every entry against the clock. Runs every 30 s, and on wake.
  public func tick(wake: Bool = false) {
    let t = now()
    for (id, e) in entries.sorted(by: { $0.key < $1.key }) {
      if let d = e.daily {
        guard e.next <= t else { continue }
        entries[id]?.next = nextDaily(d.hour, d.minute, after: t)
        // More than 2 minutes late means den (or the Mac) wasn't awake at that time.
        fire(id, t.timeIntervalSince(e.next) > 120 ? "catchup" : "time")
      } else {
        if wake && e.wake {
          entries[id]?.next = t.addingTimeInterval(Double(e.ms) / 1000)
          fire(id, "wake")
        } else if e.next <= t {
          entries[id]?.next = t.addingTimeInterval(Double(e.ms) / 1000)
          fire(id, "interval")
        }
      }
    }
  }

  func start() {
    guard timer == nil else { return }
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
    t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
    t.resume()
    timer = t
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick(wake: true) }
    }
  }

  isolated deinit {
    timer?.cancel()
    if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
  }
}
