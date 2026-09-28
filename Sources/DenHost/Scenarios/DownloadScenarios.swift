// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
import CordisValue
import WebKit

/// `--scenario downloads`: Library ▸ Downloads (the `tabs` plugin) with a running, a paused, a
/// finished, a failed and an archived download, and the sidebar's download ring (`spaces`).
/// `--scenario uploadPicker`: the upload picker over a page (host sidebar, no plugins needed).
/// Files are made in a temporary folder; nothing touches ~/Downloads or the network.
@MainActor
enum DownloadScenarios {
  static let names = ["downloads", "uploadPicker"]

  static func apply(_ name: String, runtime rt: DenRuntime, appearance: String) -> NSWindow? {
    guard names.contains(name) else { return nil }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-scenario-downloads-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func file(_ n: String, _ data: Data = Data(repeating: 0, count: 64)) -> String {
      let u = dir.appendingPathComponent(n)
      try? data.write(to: u)
      return u.path
    }
    let now = Date().timeIntervalSince1970 * 1000
    switch name {
    case "downloads":
      rt.downloads.folder = { dir }
      let mb: Int64 = 1_000_000
      typealias I = DownloadsService.Item
      var running = I(id: "d5", url: "https://github.com/abhishakenp/den/releases/download/v0.2.0/den-0.2.0.dmg", name: "den-0.2.0.dmg",
                      path: file("den-0.2.0.dmg"), state: "downloading", received: 18_400_000, total: 42 * mb, started: now - 6000)
      running.rate = 3_100_000
      let paused = I(id: "d4", url: "https://example.com/q3.pdf", name: "Quarterly report.pdf", path: file("Quarterly report.pdf"), state: "paused",
                     received: 1_200_000, total: 3_400_000, started: now - 60_000, resume: Data([1]))
      var photo = I(id: "d3", url: "https://images.example.com/photo-4012.jpg", name: "photo-4012.jpg", path: file("photo-4012.jpg"), state: "done",
                    received: 2_300_000, total: 2_300_000, started: now - 300_000, finished: now - 300_000)
      photo.unseen = true
      let failed = I(id: "d2", url: "https://downloads.example.com/archive.zip", name: "archive.zip", path: "", state: "failed", received: 0, total: -1,
                     started: now - 3_600_000, finished: now - 3_600_000, error: "Network connection lost")
      let old = I(id: "d1", url: "https://example.com/notes.txt", name: "notes.txt", path: file("notes.txt"), state: "done", received: 1200, total: 1200,
                  started: now - 3 * 86_400_000, finished: now - 3 * 86_400_000, archived: true)
      rt.downloads.seed([running, paused, photo, failed, old])
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { rt.call("downloads", "open") }
      return rt.window.window
    default:  // uploadPicker
      HostScenarios.seedSidebar(rt, appearance: appearance)
      let id = HostScenarios.page(rt, id: "t1", title: "Compose — Mail", host: "mail.example.com",
                                  body: "A page asked for a file: den offers what you most likely want first.")
      rt.call("content", "show", ["panes": [.string(id)]])
      rt.content.releaseWebViews()
      guard let web = rt.webviews.record(id)?.webView, let prompts = rt.webviews.prompts, let picker = rt.webviews.uploadPicker else { return rt.window.window }
      let shot = file("Screenshot 2026-09-28 at 09.41.12.png", screenshotPNG())
      let pdf = file("Invoice 2026-09.pdf")
      let d = Date()
      picker.fixed = { _ in [
        .init(id: "download:d1", kind: .download, title: "Invoice 2026-09.pdf", subtitle: "Downloaded 4 min ago", icon: "file:" + pdf, url: URL(fileURLWithPath: pdf), date: d),
        .init(id: "screenshot:1", kind: .screenshot, title: "Screenshot 2026-09-28 at 09.41.12.png", subtitle: "Screenshot · 12 min ago", icon: shot,
              url: URL(fileURLWithPath: shot), date: d),
        .init(id: "clipboard", kind: .clipboard, title: "Copied image", subtitle: "From the clipboard, saved as PNG", icon: "sf:photo.on.rectangle", url: nil, date: d),
      ] }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        _ = picker.offer(UploadPicker.Request(), webView: web, prompts: prompts) { _ in }
      }
      return rt.window.window
    }
  }

  /// A small made-up screenshot (a window on a gradient), so the picker shows a real thumbnail.
  static func screenshotPNG() -> Data {
    let size = NSSize(width: 320, height: 200)
    let img = NSImage(size: size)
    img.lockFocus()
    NSGradient(colors: [NSColor(red: 0.42, green: 0.36, blue: 0.95, alpha: 1), NSColor(red: 0.95, green: 0.45, blue: 0.62, alpha: 1)])?.draw(in: NSRect(origin: .zero, size: size), angle: 35)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 50, y: 30, width: 220, height: 140), xRadius: 10, yRadius: 10).fill()
    NSColor(white: 0.85, alpha: 1).setFill()
    for i in 0..<4 { NSBezierPath(roundedRect: NSRect(x: 70, y: 130 - CGFloat(i) * 24, width: 180 - CGFloat(i) * 30, height: 10), xRadius: 5, yRadius: 5).fill() }
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return Data() }
    return png
  }
}
#endif
