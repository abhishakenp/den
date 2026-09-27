// Runs one den automation launch and proves it stayed invisible (the flags scripts/snapshots.sh uses).
// usage: swift scripts/lib/invisible-check.swift <den binary> [den args...]
// Polls every ~20 ms until den exits (60 s limit): LaunchServices' ApplicationType for its pid
// ("Foreground" = a Dock app; `lsappinfo`), NSRunningApplication's active state, and every window
// CGWindowList reports for the pid, with whether it intersects a display. Exits 0 only if den quit
// by itself, checked in but never as Foreground, never became active, and no window of it ever
// touched a display. (NSRunningApplication.activationPolicy reads the Info.plist default,
// regular, until the process checks in, so LaunchServices is the record that counts.)
import AppKit
import CoreGraphics

let a = CommandLine.arguments
guard a.count >= 2 else { print("usage: invisible-check <den binary> [args...]"); exit(2) }
let p = Process()
p.executableURL = URL(fileURLWithPath: a[1])
p.arguments = Array(a.dropFirst(2))
var displays = [CGDirectDisplayID](repeating: 0, count: 16)
var n: UInt32 = 0
CGGetActiveDisplayList(16, &displays, &n)
let screens = displays.prefix(Int(n)).map { CGDisplayBounds($0) }
var lsTypes = Set<String>(), lsSeen: [String] = [], policies: [String] = []
var everActive = false, onDisplay = Set<String>(), windows = Set<String>()
let start = Date()
func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }

func lsType() -> String {
  let ls = Process()
  ls.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
  ls.arguments = ["info", "-only", "ApplicationType", "#\(pid)"]
  let pipe = Pipe()
  ls.standardOutput = pipe
  ls.standardError = FileHandle.nullDevice
  guard (try? ls.run()) != nil else { return "" }
  ls.waitUntilExit()
  let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  guard let v = out.split(separator: "=").last else { return "" }
  return v.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
}

/// App URLs of the Dock tiles titled "den" (other den builds may come and go; needs Accessibility, nil without it).
let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first.map { AXUIElementCreateApplication($0.processIdentifier) }
func children(_ e: AXUIElement) -> [AXUIElement] {
  var v: CFTypeRef?
  AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
  return v as? [AXUIElement] ?? []
}
func dockTiles() -> Set<String>? {
  guard let dock, AXIsProcessTrusted() else { return nil }
  var urls = Set<String>()
  for list in children(dock) {
    for tile in children(list) {
      var v: CFTypeRef?
      AXUIElementCopyAttributeValue(tile, kAXTitleAttribute as CFString, &v)
      guard (v as? String)?.lowercased() == "den" else { continue }
      var u: CFTypeRef?
      AXUIElementCopyAttributeValue(tile, kAXURLAttribute as CFString, &u)
      urls.insert((u as? URL)?.standardizedFileURL.path ?? "?")
    }
  }
  return urls
}
// This den bundle (…/X.app/Contents/MacOS/den → …/X.app).
let bundlePath = URL(fileURLWithPath: a[1]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
let tilesBefore = dockTiles()
var newTiles = Set<String>()
try p.run()
let pid = p.processIdentifier

while p.isRunning && Date().timeIntervalSince(start) < 60 {
  if let t = dockTiles(), let b = tilesBefore { newTiles.formUnion(t.subtracting(b)) }
  let t = lsType()
  if !t.isEmpty && !lsTypes.contains(t) { lsSeen.append("\(t)@\(ms())ms") }
  if !t.isEmpty { lsTypes.insert(t) }
  if let app = NSRunningApplication(processIdentifier: pid) {
    let pol = ["regular", "accessory", "prohibited"][app.activationPolicy.rawValue]
    if policies.last?.hasPrefix(pol) != true { policies.append("\(pol)@\(ms())ms") }
    if app.isActive { everActive = true }
  }
  let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
  for w in list where w[kCGWindowOwnerPID as String] as? Int32 == pid {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    let on = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    let desc = "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)) layer=\(w[kCGWindowLayer as String] ?? 0) orderedIn=\(on)"
    windows.insert(desc)
    if on && r.width > 1 && r.height > 1 && screens.contains(where: { $0.intersects(r) }) { onDisplay.insert(desc) }
  }
  usleep(20_000)
}
let exited = !p.isRunning
if !exited { p.terminate() }
p.waitUntilExit()
print("invisible-check: exitedBySelf=\(exited) status=\(p.terminationStatus) seconds=\(String(format: "%.1f", Date().timeIntervalSince(start)))")
print("invisible-check: LaunchServices ApplicationType=\(lsSeen) NSRunningApplication policy=\(policies) everActive=\(everActive)")
print("invisible-check: Dock: \(tilesBefore == nil ? "unknown (no Accessibility)" : "new den tiles during the run \(newTiles.sorted()), this bundle \(bundlePath)")")
print("invisible-check: displays=\(screens.map { "\($0)" })")
print("invisible-check: windows seen=\(windows.sorted())")
print("invisible-check: windows on a display=\(onDisplay.sorted())")
let noDock = tilesBefore != nil ? !newTiles.contains { $0.hasPrefix(bundlePath) } : !lsTypes.contains("Foreground")
let ok = exited && lsTypes.contains("UIElement") && noDock && !everActive && onDisplay.isEmpty
print("invisible-check: \(ok ? "PASS" : "FAIL")")
exit(ok ? 0 : 1)
