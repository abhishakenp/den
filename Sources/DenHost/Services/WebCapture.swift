import AppKit
import CordisValue
import WebKit

/// `webviews.snapshot` with a region, the full page, the clipboard or a folder: a generic
/// capture primitive (plugins own the picking UI and what happens next).
///
/// `snapshot {id, rect?: {x, y, width, height}, full?, clipboard?, folder?, name?, path?}`:
/// - `rect` is in CSS px of the document (scroll offset included); `full` is the whole
///   document. On screen: `takeSnapshot` of that rect. Past the visible area (which
///   `takeSnapshot` leaves blank): WebKit's whole-document PDF, rasterised and cropped. Nothing
///   scrolls and nothing is stitched. Neither `rect` nor `full`: the visible area.
/// - Output (PNG at the screen's scale): `path`, or `folder` + `name` (a " 2", " 3" … suffix
///   keeps it unique), and/or the general pasteboard (`clipboard`, PNG + TIFF).
/// Emits `webviews.snapshot {id, ok, path?, clipboard, width, height, bytes, error?}`.
extension WebViewsService {
  /// Tallest capture, in points: WebKit renders the rect at the screen's scale in one bitmap.
  static let maxCaptureHeight: CGFloat = 16_000

  func capture(_ r: WebRecord, _ args: Value) -> Value {
    guard let w = r.webView else { return .error("webviews: '\(r.id)' is not loaded") }
    let id = r.id
    let full = args.flag("full"), rectArg = args["rect"]
    var dest: URL?
    if !args.str("path").isEmpty {
      dest = URL(fileURLWithPath: (args.str("path") as NSString).expandingTildeInPath)
    } else if !args.str("folder").isEmpty {
      let name = args.str("name", "Capture.png")
      guard !name.contains("/") else { return .error("webviews: bad name") }
      dest = Self.unique(URL(fileURLWithPath: (args.str("folder") as NSString).expandingTildeInPath).appendingPathComponent(name))
    }
    let clipboard = args.flag("clipboard")
    Task {
      let config = WKSnapshotConfiguration()
      config.afterScreenUpdates = true
      if full || !rectArg.isNull {
        let m = await PageScripting.call(w, "var d = document.documentElement, b = document.body; return {x: scrollX, y: scrollY, w: Math.max(d.scrollWidth, b ? b.scrollWidth : 0), h: Math.max(d.scrollHeight, b ? b.scrollHeight : 0)}", [:], .defaultClient)
        let z = w.pageZoom * w.magnification
        let doc = full ? CGRect(x: 0, y: 0, width: max(m.num("w"), 1), height: max(m.num("h"), 1))
          : CGRect(x: rectArg.num("x"), y: rectArg.num("y"), width: rectArg.num("width"), height: rectArg.num("height"))
        guard doc.width >= 1, doc.height >= 1 else { return self.captured(id, nil, dest: dest, clipboard: clipboard, error: "empty rect") }
        config.rect = CGRect(x: (doc.minX - m.num("x")) * z, y: (doc.minY - m.num("y")) * z, width: doc.width * z,
                             height: min(doc.height * z, Self.maxCaptureHeight))
      }
      var image: NSImage?, failure = ""
      // takeSnapshot draws only what's on screen (the rest comes out blank). Anything reaching
      // past the visible area comes from WebKit's whole-document PDF, rasterised and cropped.
      let visible = CGRect(origin: .zero, size: w.bounds.size)
      if !config.rect.isNull, !visible.insetBy(dx: -1, dy: -1).contains(config.rect) {
        let scale = w.window?.backingScaleFactor ?? 2
        let z = w.pageZoom * w.magnification
        let m = await PageScripting.call(w, "return {x: scrollX, y: scrollY}", [:], .defaultClient)
        // Back to document coordinates (the PDF's), in points.
        let doc = CGRect(x: config.rect.minX + m.num("x") * z, y: config.rect.minY + m.num("y") * z, width: config.rect.width, height: config.rect.height)
        let data: Data? = await awaitCallback(30, nil) { done in
          w.createPDF(configuration: WKPDFConfiguration()) { r in done(try? r.get()) }
        }
        image = data.flatMap { Self.rasterize(pdf: $0, crop: doc, scale: scale) }
        failure = "pdf failed"
      }
      // One retry: WebKit can fail a snapshot while the page is still committing a frame.
      for attempt in 0..<2 where image == nil && failure.isEmpty {
        if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
        let (img, err): (NSImage?, String) = await awaitCallback(20, (nil, "timed out")) { done in
          w.takeSnapshot(with: config) { img, e in done((img, e.map { ($0 as NSError).localizedDescription } ?? "")) }
        }
        image = img
        failure = err
      }
      self.captured(id, image, dest: dest, clipboard: clipboard, error: image == nil ? "snapshot failed: " + failure : nil)
    }
    return ["pending": true]
  }

  private func captured(_ id: String, _ image: NSImage?, dest: URL?, clipboard: Bool, error: String?) {
    guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    else {
      host.emit("webviews.snapshot", ["id": .string(id), "ok": false, "clipboard": false, "error": .string(error ?? "no image")])
      return
    }
    var out: Value = ["id": .string(id), "ok": true, "clipboard": .bool(clipboard), "width": .int(Int64(cg.width)), "height": .int(Int64(cg.height)),
                      "bytes": .int(Int64(png.count))]
    if let dest {
      do {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: dest)
        out = out.with("path", .string(dest.path))
      } catch {
        out = out.with("ok", false).with("error", .string(error.localizedDescription))
      }
    }
    if clipboard {
      let pb = NSPasteboard.general
      pb.clearContents()
      pb.declareTypes([.png, .tiff], owner: nil)
      pb.setData(png, forType: .png)
      if let tiff = image.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }
    host.emit("webviews.snapshot", out)
  }

  /// The `crop` rect (points, top-left origin) of a one-page PDF, as a bitmap at `scale`.
  static func rasterize(pdf: Data, crop: CGRect, scale: CGFloat) -> NSImage? {
    guard let rep = NSPDFImageRep(data: pdf) else { return nil }
    let page = rep.bounds
    let r = crop.intersection(CGRect(origin: .zero, size: page.size))
    guard r.width >= 1, r.height >= 1 else { return nil }
    let px = Int((r.width * scale).rounded()), py = Int((r.height * scale).rounded())
    guard let b = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    b.size = r.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: b)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: r.size).fill()
    // PDF space has its origin at the bottom left.
    rep.draw(in: NSRect(x: -r.minX, y: -(page.height - r.maxY), width: page.width, height: page.height))
    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: r.size)
    img.addRepresentation(b)
    return img
  }

  /// `url`, or "name 2.ext", "name 3.ext" … when taken.
  nonisolated static func unique(_ url: URL) -> URL {
    var u = url, n = 2
    let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
    while FileManager.default.fileExists(atPath: u.path) {
      u = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : "." + ext))
      n += 1
    }
    return u
  }
}
