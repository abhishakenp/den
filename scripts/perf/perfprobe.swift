// perfprobe: one identical launch/memory/CPU method for any macOS app bundle (den, Dia, Arc, ...).
//
//   perfprobe launch <App.app> [--runs N] [--warmup N] [--timeout S] [--url U] [-- app args...]
//       Warm launch time. Each run: LaunchServices opens a NEW instance of the bundle (optionally
//       with a URL), then CGWindowListCopyWindowInfo is polled every 1 ms until a window owned by
//       that new process is on screen (layer 0, >= 100x100 pt, alpha > 0). Prints per run:
//         reqMs   = LaunchServices request -> first on-screen window
//         startMs = kernel process start   -> first on-screen window
//       then quits that instance (polite terminate, force after 10 s) and waits for its process
//       tree to exit before the next run. Summary: median/p90/min/max of both.
//
//   perfprobe mem <App.app> [--settle S] [--cpu S] [--url U] [--shot out.png] [--timeout S] [-- app args...]
//       Launch one new instance, wait for the first window, wait S s (default 10), then sum
//       phys_footprint (the number `footprint` and Activity Monitor's "Memory" show) over the whole
//       process tree: every process whose parent chain OR "responsible process" leads to the app
//       (covers Chromium helpers and WebKit's com.apple.WebKit.* XPC services). With --cpu S it
//       then measures CPU time and wakeups over S seconds of idle across the same tree.
//
// Only processes started by this tool are ever quit. Pre-existing instances are never touched.
import AppKit
import Darwin

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: args
var argv = Array(CommandLine.arguments.dropFirst())
var appArgs: [String] = []
if let i = argv.firstIndex(of: "--") { appArgs = Array(argv[(i + 1)...]); argv = Array(argv[..<i]) }
func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }
guard argv.count >= 2 else { die("usage: perfprobe launch|mem <App.app> [options] [-- app args]") }
let mode = argv[0]
let appURL = URL(fileURLWithPath: argv[1]).standardizedFileURL
func opt(_ n: String) -> String? { argv.firstIndex(of: n).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }
let runs = Int(opt("--runs") ?? "10")!
let warmup = Int(opt("--warmup") ?? "1")!
let timeout = Double(opt("--timeout") ?? "60")!
let settle = Double(opt("--settle") ?? "10")!
let cpuSecs = Double(opt("--cpu") ?? "0")!
let openURL = opt("--url").flatMap(URL.init(string:))
let shot = opt("--shot")
/// `--any-alpha`: also count a fully transparent window (den `--background`, measured without
/// showing anything on screen).
let anyAlpha = argv.contains("--any-alpha")
func real(_ p: String) -> String { guard let r = realpath(p, nil) else { return p }; defer { free(r) }; return String(cString: r) }
guard let bundle = Bundle(url: appURL), let exe = bundle.executableURL.map({ real($0.path) }) else { die("not an app bundle: \(appURL.path)") }

// MARK: process helpers
func now() -> Double { Date().timeIntervalSince1970 }
func pidPath(_ pid: pid_t) -> String? {
  var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? real(String(cString: buf)) : nil
}
func allPids() -> [pid_t] {
  var pids = [pid_t](repeating: 0, count: 8192)
  let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
  return Array(pids.prefix(Int(max(n, 0)))).filter { $0 > 0 }
}
func kinfo(_ pid: pid_t) -> kinfo_proc? {
  var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  return sysctl(&mib, 4, &info, &size, nil, 0) == 0 && size > 0 ? info : nil
}
func startTime(_ pid: pid_t) -> Double? {
  guard let k = kinfo(pid) else { return nil }
  let tv = k.kp_proc.p_starttime
  return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
}
func ppid(_ pid: pid_t) -> pid_t { kinfo(pid)?.kp_eproc.e_ppid ?? 0 }
typealias RespFn = @convention(c) (pid_t) -> pid_t
let respFn: RespFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: RespFn.self) }
func responsible(_ pid: pid_t) -> pid_t { respFn?(pid) ?? pid }

/// The app process plus everything it spawned: parent-chain descendants and XPC services it is responsible for.
func tree(_ root: pid_t) -> [pid_t] {
  var out: [pid_t] = [root]
  for p in allPids() where p != root {
    if responsible(p) == root { out.append(p); continue }
    var q = ppid(p); var hops = 0
    while q > 1 && hops < 32 { if q == root { out.append(p); break }; q = ppid(q); hops += 1 }
  }
  return out
}
struct Usage { var footprint: UInt64; var cpuNs: UInt64; var wakeups: UInt64 }
func usage(_ pid: pid_t) -> Usage? {
  var ri = rusage_info_v4()
  let r = withUnsafeMutablePointer(to: &ri) { p in
    p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
  }
  guard r == 0 else { return nil }
  // ri_user_time/ri_system_time are mach absolute time units.
  var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
  let cpu = (ri.ri_user_time + ri.ri_system_time) * UInt64(tb.numer) / UInt64(tb.denom)
  return Usage(footprint: ri.ri_phys_footprint, cpuNs: cpu, wakeups: ri.ri_pkg_idle_wkups + ri.ri_interrupt_wkups)
}
func name(_ pid: pid_t) -> String { pidPath(pid).map { ($0 as NSString).lastPathComponent } ?? "?" }

// MARK: window polling
struct Win { let pid: pid_t; let t: Double; let w: Int; let h: Int; let title: String; let id: Int }
/// Polls every 1 ms for an on-screen window owned by a process running `exe` that is not in `existing`.
func waitForWindow(existing: Set<pid_t>, deadline: Double) -> Win? {
  var pathCache: [pid_t: Bool] = [:]
  while now() < deadline {
    if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
      let t = now()
      for w in list {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, !existing.contains(pid) else { continue }
        let mine = pathCache[pid] ?? { let m = pidPath(pid) == exe; pathCache[pid] = m; return m }()
        guard mine, (w[kCGWindowLayer as String] as? Int) == 0, anyAlpha || ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let wd = (b["Width"] as? NSNumber)?.intValue, let ht = (b["Height"] as? NSNumber)?.intValue,
              wd >= 100, ht >= 100 else { continue }
        return Win(pid: pid, t: t, w: wd, h: ht, title: w[kCGWindowName as String] as? String ?? "", id: (w[kCGWindowNumber as String] as? Int) ?? 0)
      }
    }
    usleep(1000)
  }
  return nil
}
func runningPids() -> Set<pid_t> { Set(allPids().filter { pidPath($0) == exe }) }
/// No window: quit whatever new instance we started, then fail.
func noWindow(_ existing: Set<pid_t>, _ msg: String) -> Never {
  print(msg)
  for p in runningPids().subtracting(existing) { quit(p) }
  exit(1)
}

// MARK: launch / quit
func launch() -> (t0: Double, existing: Set<pid_t>) {
  let existing = runningPids()
  let cfg = NSWorkspace.OpenConfiguration()
  cfg.createsNewApplicationInstance = true
  cfg.arguments = appArgs
  cfg.activates = false  // like `open -g`: never pull the test instance in front of the user (apps may still self-activate)
  cfg.addsToRecentItems = false
  let t0 = now()
  let done: (NSRunningApplication?, Error?) -> Void = { _, e in if let e { print("launch error: \(e)") } }
  if let openURL { NSWorkspace.shared.open([openURL], withApplicationAt: appURL, configuration: cfg, completionHandler: done) }
  else { NSWorkspace.shared.openApplication(at: appURL, configuration: cfg, completionHandler: done) }
  return (t0, existing)
}
func quit(_ pid: pid_t) {
  let members = tree(pid)
  if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() } else { kill(pid, SIGTERM) }
  let d = now() + 10
  while now() < d && kill(pid, 0) == 0 { pump(0.05) }
  if kill(pid, 0) == 0 { print("  (pid \(pid) ignored terminate; force-quitting)"); NSRunningApplication(processIdentifier: pid)?.forceTerminate(); kill(pid, SIGKILL) }
  // Wait for helpers to exit too, so they don't inflate the next run.
  let d2 = now() + 10
  while now() < d2 && members.contains(where: { kill($0, 0) == 0 && pidPath($0) != nil && (responsible($0) == pid || ppid($0) == pid) }) { pump(0.05) }
}
func pump(_ s: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }
func stats(_ xs: [Double]) -> String {
  let s = xs.sorted(); guard !s.isEmpty else { return "n=0" }
  func q(_ p: Double) -> Double { s[min(s.count - 1, Int((p * Double(s.count - 1)).rounded(.up)))] }
  let med = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
  return String(format: "n=%d median=%.1f p90=%.1f min=%.1f max=%.1f", s.count, med, q(0.9), s.first!, s.last!)
}
func loadavg() -> String { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return String(format: "%.2f %.2f %.2f", l[0], l[1], l[2]) }

_ = NSApplication.shared  // AppKit/LaunchServices connection for NSWorkspace
print("app \(appURL.path) exe \(exe) version \(bundle.infoDictionary?["CFBundleShortVersionString"] ?? "?") args \(appArgs) url \(openURL?.absoluteString ?? "-")")
print("loadavg.start \(loadavg())")

switch mode {
case "launch":
  var req: [Double] = [], start: [Double] = []
  for i in 0..<(warmup + runs) {
    let (t0, existing) = launch()
    guard let w = waitForWindow(existing: existing, deadline: t0 + timeout) else { noWindow(existing, "run \(i): no window within \(timeout)s") }
    let r = (w.t - t0) * 1000, s = (w.t - (startTime(w.pid) ?? t0)) * 1000
    let tag = i < warmup ? "warmup" : "run \(i - warmup + 1)"
    print(String(format: "%@ pid=%d reqMs=%.1f startMs=%.1f window=%dx%d title=\"%@\" load=%@", tag, w.pid, r, s, w.w, w.h, w.title, loadavg()))
    if i >= warmup { req.append(r); start.append(s) }
    pump(1.0)  // let it finish settling before quitting, same for every app
    quit(w.pid)
    pump(1.0)
  }
  print("summary.reqMs \(stats(req))")
  print("summary.startMs \(stats(start))")
case "mem":
  let (t0, existing) = launch()
  guard let w = waitForWindow(existing: existing, deadline: t0 + timeout) else { noWindow(existing, "no window within \(timeout)s") }
  print(String(format: "window pid=%d reqMs=%.1f window=%dx%d title=\"%@\"", w.pid, (w.t - t0) * 1000, w.w, w.h, w.title))
  pump(settle)
  // Every on-screen window of the app after settling, so the log shows what was open (sign-in, page, panel).
  for x in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
  where (x[kCGWindowOwnerPID as String] as? pid_t) == w.pid {
    let b = x[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("  win layer=\(x[kCGWindowLayer as String] ?? 0) \((b["Width"] as? NSNumber)?.intValue ?? 0)x\((b["Height"] as? NSNumber)?.intValue ?? 0) \"\(x[kCGWindowName as String] as? String ?? "")\"")
  }
  let members = tree(w.pid)
  var total: UInt64 = 0
  for p in members { if let u = usage(p) { total += u.footprint; print(String(format: "  proc %6d %-45@ %8.1f MB", p, name(p), Double(u.footprint) / 1048576)) } }
  print(String(format: "mem.totalMB %.1f procs=%d settle=%.0fs load=%@", Double(total) / 1048576, members.count, settle, loadavg()))
  // The app's own process alone (for den: the host, without WebKit's processes).
  print(String(format: "mem.hostMB %.1f", Double(usage(w.pid)?.footprint ?? 0) / 1048576))
  if cpuSecs > 0 {
    let a = Dictionary(uniqueKeysWithValues: members.compactMap { p in usage(p).map { (p, $0) } })
    let ta = now()
    pump(cpuSecs)
    let dt = now() - ta
    var cpu: UInt64 = 0, wk: UInt64 = 0
    for p in tree(w.pid) { if let b = usage(p) { let x = a[p]; cpu += b.cpuNs - (x?.cpuNs ?? 0); wk += b.wakeups - (x?.wakeups ?? 0) } }
    print(String(format: "cpu.idlePct %.3f cpuMs=%.1f over %.1fs  wakeups/s %.1f load=%@", Double(cpu) / 1e9 / dt * 100, Double(cpu) / 1e6, dt, Double(wk) / dt, loadavg()))
  }
  if let shot {  // taken after sampling so it cannot affect the numbers
    // what state the window is in (sign-in, page, ...): a local screenshot of that one window
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-x", "-o", "-l\(w.id)", shot]
    try? p.run(); p.waitUntilExit()
  }
  quit(w.pid)
default: die("unknown mode \(mode)")
}
print("loadavg.end \(loadavg())")
