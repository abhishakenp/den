import AppKit
import PluginCores
import CoreImage
import CordisValue
import UniformTypeIdentifiers

/// The `app` service's clipboard, share and file helpers (docs/host-api.md#app): platform
/// capabilities only; what to share, when, and the QR popover belong to plugins. Nothing here
/// exists until a method is called (`AppService.share` is lazy).
///
///   pasteboard                    -> {text, url} for one line of clipboard text, else {} (Paste and Go)
///   share {url, title?, anchor?}  -> ok. macOS's share picker (AirDrop, Messages, Mail, Notes…) for
///                                    the URL, next to the node `anchor` (e.g. the URL pill), else
///                                    at the top of the page
///   qrCode {text}                 -> {path, modules}. A QR code PNG (black on white, 4-module quiet
///                                    zone, sharp modules) in a temporary folder
///   copyImage {path}              -> ok. The image file on the clipboard (PNG and TIFF)
///   saveFile {path, name, request?} -> {pending}, then app.saved {request, path} ("" when cancelled):
///                                    a save panel as a sheet, then a copy of the file
@MainActor
final class AppShare {
  let host: ServiceHost
  /// The browser window in front (the share sheet and save panel go over it).
  var current: () -> DenWindowController? = { nil }
  var wc: DenWindowController? { current() }
  /// Finds a rendered node by id (set by `DenRuntime` from the `ui` service).
  var anchorView: ((String) -> NSView?)?
  /// Shows the picker (tests swap it to record what would be shared).
  var present: (NSSharingServicePicker, NSRect, NSView, NSRectEdge) -> Void = { p, r, v, e in p.show(relativeTo: r, of: v, preferredEdge: e) }
  /// The last picker's items (tests).
  private(set) var lastItems: [Any] = []
  private var picker: NSSharingServicePicker?
  var pasteboard: NSPasteboard { PasteText.board }
  lazy var folder: URL = {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("den-share-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }()

  init(host: ServiceHost, window: DenWindowController?) {
    self.host = host
    current = { [weak window] in window }
  }

  func handle(_ method: String, _ args: Value) -> Value {
    switch method {
    case "pasteboard":
      guard let s = PasteText.read(pasteboard) else { return .object([]) }
      return ["text": .string(s), "url": .bool(PasteText.isURL(s))]
    case "share":
      guard let u = URL(string: args.str("url")), u.scheme != nil else { return .error("app: share needs a url") }
      return share(u, title: args.str("title"), anchor: args.str("anchor"))
    case "qrCode":
      let text = args.str("text")
      guard !text.isEmpty else { return .error("app: qrCode needs text") }
      guard let qr = Self.qrPNG(text) else { return .error("app: couldn’t make a QR code") }
      let (png, modules) = qr
      let url = folder.appendingPathComponent("qr-\(Self.fnv(text)).png")
      do { try png.write(to: url) } catch { return .error("app: \(error.localizedDescription)") }
      return ["path": .string(url.path), "modules": .int(Int64(modules))]
    case "copyImage":
      guard let img = NSImage(contentsOfFile: args.str("path")) else { return .error("app: no image at that path") }
      pasteboard.clearContents()
      pasteboard.writeObjects([img])
      return .ok
    case "saveFile":
      return save(args)
    default:
      return .error("app: unknown method '\(method)'")
    }
  }

  // MARK: Share

  func share(_ url: URL, title: String, anchor: String) -> Value {
    // The URL alone: Messages and AirDrop send it as a link (a title item would go as extra text).
    let items: [Any] = [url]
    lastItems = items
    let picker = NSSharingServicePicker(items: items)
    self.picker = picker  // kept while it shows
    if !anchor.isEmpty, let v = anchorView?(anchor), v.window != nil {
      present(picker, v.bounds, v, .maxX)
    } else if let wc {
      let a = wc.contentArea
      present(picker, NSRect(x: a.bounds.midX - 1, y: 8, width: 2, height: 2), a, .minY)
    } else {
      return .error("app: no window to share from")
    }
    return .ok
  }


  // MARK: QR code

  /// A QR code for `text` as PNG data: one module = `scale` px (at least 8, so ~512 px for a
  /// typical URL), black on white with the 4-module quiet zone scanners need.
  static func qrPNG(_ text: String, scale requested: Int? = nil) -> (Data, Int)? {
    guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    f.setValue(Data(text.utf8), forKey: "inputMessage")
    f.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = f.outputImage, let small = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(out, from: out.extent) else { return nil }
    let modules = small.width
    let scale = requested ?? max(8, 512 / (modules + 8))
    let side = (modules + 8) * scale
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.interpolationQuality = .none
    ctx.draw(small, in: CGRect(x: 4 * scale, y: 4 * scale, width: modules * scale, height: modules * scale))
    guard let img = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
    return (png, modules)
  }

  static func fnv(_ s: String) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return String(h, radix: 16)
  }

  // MARK: Save

  func save(_ args: Value) -> Value {
    let src = URL(fileURLWithPath: args.str("path"))
    guard FileManager.default.fileExists(atPath: src.path) else { return .error("app: no file at that path") }
    let request = args.str("request", "save")
    let panel = NSSavePanel()
    panel.nameFieldStringValue = args.str("name", src.lastPathComponent)
    if let t = UTType(filenameExtension: src.pathExtension) { panel.allowedContentTypes = [t] }
    let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
      var path = ""
      if r == .OK, let dest = panel.url {
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.copyItem(at: src, to: dest)) != nil { path = dest.path }
      }
      self?.host.emit("app.saved", ["request": .string(request), "path": .string(path)])
    }
    if let w = wc?.window, w.isVisible { panel.beginSheetModal(for: w, completionHandler: done) } else { panel.begin(completionHandler: done) }
    return ["pending": true]
  }
}
