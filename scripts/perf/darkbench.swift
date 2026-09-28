// darkbench: memory cost of dark-mode stylesheet variants on an image-heavy page.
//   swiftc -O scripts/perf/darkbench.swift -o build/perf/darkbench
//   darkbench <outdir> [--reps N] [--images N] [variant...]
// Generates a light page with N (default 300) JPEG photos, text, links and inline background
// images, then for each variant (interleaved, N reps) loads it in a fresh 1200x800 on-screen
// WKWebView with the variant as a user stylesheet (_WKUserStyleSheet, as den's pagestyle does),
// scrolls through the whole page, waits 3 s, and reads phys_footprint of that page's WebContent
// process (where its layers and decoded images live). Prints per run, then medians; writes a
// viewport PNG per variant (<outdir>/<variant>.png) to check quality.
import AppKit
import Darwin
import WebKit

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
guard let outArg = args.first else { print("usage: darkbench <outdir> [--reps N] [--images N] [variant...]"); exit(2) }
let out = URL(fileURLWithPath: outArg, isDirectory: true)
func opt(_ n: String) -> Int? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } }
let reps = opt("--reps") ?? 3
let imageCount = opt("--images") ?? 300

let inv = "filter: invert(1) hue-rotate(180deg) !important;"
let media = ":is(img, video, canvas, embed, object, iframe, svg image, [style*=\"background-image\"])"
let nested = "[style*=\"background-image\"] :is(img, video, canvas) { filter: none !important; }"
/// Variants: name -> user stylesheet.
let variants: [(String, String)] = [
  ("none", ""),
  // den today (DarkModeCore.darkCSS without the media query / tone key)
  ("current", "html { \(inv) }\nhtml \(media) { \(inv) }\nhtml \(nested)"),
  ("rootOnly", "html { \(inv) }"),
  // media re-inverted on their own compositing layers: Core Animation applies the filter at composite time
  ("mediaLayers", "html { \(inv) }\nhtml \(media) { \(inv) will-change: transform; }\nhtml \(nested)"),
  // the root on its own compositing layer as well
  ("allLayers", "html { \(inv) will-change: filter; }\nhtml \(media) { \(inv) will-change: transform; }\nhtml \(nested)"),
  // media re-inverted only near the viewport (a script marks them with an IntersectionObserver):
  // offscreen images carry no filter, so no filtered copy of them is kept
  ("nearMedia", "html { \(inv) }\nhtml \(media)[data-den-near] { \(inv) }\nhtml \(nested)"),
]
/// Variants that also need the near-viewport marker script.
let nearScript = """
  (()=>{const sel='img,video,canvas,embed,object,iframe,svg image,[style*="background-image"]';
  const io=new IntersectionObserver(es=>{for(const e of es){if(e.isIntersecting)e.target.setAttribute('data-den-near','');else e.target.removeAttribute('data-den-near')}},{rootMargin:'100% 0px'});
  const seen=new WeakSet();const scan=r=>{for(const el of (r.querySelectorAll?r.querySelectorAll(sel):[])){if(!seen.has(el)){seen.add(el);io.observe(el)}}};
  const go=()=>{scan(document);new MutationObserver(ms=>{for(const m of ms)for(const n of m.addedNodes)if(n.nodeType===1){if(n.matches(sel)&&!seen.has(n)){seen.add(n);io.observe(n)}scan(n)}}).observe(document.documentElement,{childList:true,subtree:true})};
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',go);else go()})();
  """
let chosen = args.filter { a in variants.contains { $0.0 == a } }
let run = chosen.isEmpty ? variants : variants.filter { chosen.contains($0.0) }

// MARK: page
let site = out.appendingPathComponent("site", isDirectory: true)
try? FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
func jpeg(_ i: Int) -> Data {
  let w = 600, h = 400
  let cs = CGColorSpace(name: CGColorSpace.sRGB)!
  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  let hue = CGFloat(i % 36) / 36
  let a = NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor
  let b = NSColor(hue: (hue + 0.4).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.4, alpha: 1).cgColor
  ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [a, b] as CFArray, locations: nil)!, start: .zero, end: CGPoint(x: w, y: h), options: [])
  var seed = UInt64(i) &* 6364136223846793005 &+ 1442695040888963407
  for _ in 0..<40 {  // noise-ish shapes so JPEGs don't compress to nothing
    seed = seed &* 6364136223846793005 &+ 1
    let x = CGFloat(seed >> 40 & 511), y = CGFloat(seed >> 20 & 383), r = CGFloat(seed & 63) + 8
    ctx.setFillColor(NSColor(hue: CGFloat(seed >> 8 & 255) / 255, saturation: 0.8, brightness: 0.8, alpha: 0.6).cgColor)
    ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
  }
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
}
var html = """
  <!doctype html><html><head><meta charset=utf-8><title>darkbench</title><style>
  body{font:16px -apple-system,sans-serif;margin:0;padding:24px;background:#fff;color:#222}
  .g{display:grid;grid-template-columns:repeat(3,1fr);gap:12px} img{width:100%;height:auto;display:block}
  a{color:#0645ad} .note{background:#fef6d8;border-left:4px solid #e0a800;padding:8px 12px}
  .bg{height:160px;background-size:cover}
  </style></head><body><h1>Image-heavy page</h1>
  """
for i in 0..<imageCount {
  try! jpeg(i).write(to: site.appendingPathComponent("p\(i).jpg"))
  if i % 3 == 0 {
    html += "<p>Paragraph \(i / 3): some body text with <a href='#'>a blue link</a> and <b>bold words</b> to read on a light page.</p>"
    if i % 30 == 0 { html += "<p class=note>A highlighted note with a yellow background.</p>" }
    html += "<div class=g>"
  }
  if i % 15 == 7 {
    html += "<div class=bg style=\"background-image:url('p\(i).jpg')\"></div>"
  } else {
    html += "<img src='p\(i).jpg' width=600 height=400 alt=''>"
  }
  if i % 3 == 2 { html += "</div>" }
}
html += "</div></body></html>"
let page = site.appendingPathComponent("index.html")
try! html.write(to: page, atomically: true, encoding: .utf8)

// MARK: processes
func allPids() -> [pid_t] {
  var pids = [pid_t](repeating: 0, count: 8192)
  let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
  return Array(pids.prefix(Int(max(n, 0)))).filter { $0 > 0 }
}
func path(_ p: pid_t) -> String {
  var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  return proc_pidpath(p, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}
func footprint(_ p: pid_t) -> UInt64 {
  var ri = rusage_info_v4()
  let r = withUnsafeMutablePointer(to: &ri) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p, RUSAGE_INFO_V4, $0) } }
  return r == 0 ? ri.ri_phys_footprint : 0
}
typealias RespFn = @convention(c) (pid_t) -> pid_t
let respFn: RespFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: RespFn.self) }
let me = getpid()
/// WebKit processes working for this bench: responsible pid is us, or (from a shell, where the
/// terminal is responsible) any com.apple.WebKit process that wasn't there when we started.
let before = Set(allPids())
func webkitProcs() -> [(pid_t, String)] {
  allPids().compactMap { p in
    let n = (path(p) as NSString).lastPathComponent
    guard n.hasPrefix("com.apple.WebKit.") else { return nil }
    return (respFn?(p) == me || !before.contains(p)) ? (p, n) : nil
  }
}

// MARK: sheet (as den's PageStyleService.makeSheet)
func makeSheet(_ source: String) -> NSObject? {
  guard let cls = NSClassFromString("_WKUserStyleSheet") as? NSObject.Type else { return nil }
  typealias Init = @convention(c) (AnyObject, Selector, NSString, Bool) -> Unmanaged<NSObject>?
  let sel = NSSelectorFromString("initWithSource:forMainFrameOnly:")
  guard let imp = class_getMethodImplementation(cls, sel), let alloc = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
  return unsafeBitCast(imp, to: Init.self)(alloc, sel, source as NSString, true)?.takeRetainedValue()
}

// MARK: bench
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
func pump(_ s: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }
final class Nav: NSObject, WKNavigationDelegate {
  var done = false
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done = true }
}
func js(_ w: WKWebView, _ s: String) -> Any? {
  var r: Any?, fin = false
  w.evaluateJavaScript(s) { v, _ in r = v; fin = true }
  let d = Date().addingTimeInterval(10)
  while !fin && Date() < d { pump(0.01) }
  return r
}
var results: [String: [Double]] = [:]
for rep in 1...reps {
  for (name, css) in run {
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = .nonPersistent()  // fresh caches every run
    if !css.isEmpty, let sheet = makeSheet(css) { cfg.userContentController.perform(NSSelectorFromString("_addUserStyleSheet:"), with: sheet) }
    if css.contains("data-den-near") {
      cfg.userContentController.addUserScript(WKUserScript(source: nearScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    let win = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    win.isReleasedWhenClosed = false
    win.appearance = NSAppearance(named: .aqua)
    let web = WKWebView(frame: win.contentView!.bounds, configuration: cfg)
    web.autoresizingMask = [.width, .height]
    win.contentView!.addSubview(web)
    win.orderFrontRegardless()
    let nav = Nav(); web.navigationDelegate = nav
    web.loadFileURL(page, allowingReadAccessTo: site)
    let d = Date().addingTimeInterval(30)
    while !nav.done && Date() < d { pump(0.02) }
    pump(1)
    // This view's own WebContent process (WebKit SPI, as den's WebViewsService reads it); DOM
    // layers and decoded images live there. GPU and Networking are shared across runs.
    let pid = (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    let height = (js(web, "document.documentElement.scrollHeight") as? Double) ?? 0
    var y = 0.0, peak: UInt64 = 0
    while y < height {  // ~ a fast wheel scroll: 400 px per 50 ms
      _ = js(web, "window.scrollTo(0, \(y))"); pump(0.05); y += 400
      peak = max(peak, footprint(pid))
    }
    _ = js(web, "window.scrollTo(0, \(min(height / 3, 12000)))")
    pump(3)
    let total = footprint(pid)
    peak = max(peak, total)
    let others = webkitProcs().filter { $0.0 != pid }.map { String(format: "%@ %.1f", $0.1.replacingOccurrences(of: "com.apple.WebKit.", with: ""), Double(footprint($0.0)) / 1048576) }.joined(separator: ", ")
    print(String(format: "run %d %-12@ WebContent %d settled %.1f MB peak %.1f MB height %.0f  (others: %@)", rep, name, pid, Double(total) / 1048576, Double(peak) / 1048576, height, others))
    results[name, default: []].append(Double(total) / 1048576)
    if rep == 1 {  // the window as the screen shows it (backdrop filters included)
      let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      p.arguments = ["-x", "-o", "-l\(win.windowNumber)", out.appendingPathComponent("\(name).png").path]
      try? p.run(); p.waitUntilExit()
    }
    web.removeFromSuperview()
    win.orderOut(nil)
    win.close()
    // Let the WebContent process exit before the next variant.
    let ed = Date().addingTimeInterval(10)
    web.navigationDelegate = nil
    while Date() < ed && kill(pid, 0) == 0 { pump(0.1) }
  }
}
print("== medians (settled MB, the page's WebContent process)")
for (name, _) in run {
  let s = (results[name] ?? []).sorted()
  let med = s.isEmpty ? 0 : (s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
  print(String(format: "%-12@ median %.1f MB  (%@)", name, med, s.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
}
