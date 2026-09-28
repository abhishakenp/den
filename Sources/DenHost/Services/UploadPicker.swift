import AppKit
import CordisValue
import UniformTypeIdentifiers
import WebKit

/// The upload picker (Opera's idea): when a page asks for a file (`<input type=file>`), den first
/// offers the files you most likely want, in a small dialog over the page: the last few downloads,
/// the newest screenshots and what's on the clipboard. "Choose File…" opens the normal panel.
/// With nothing to offer (or a folder input) the normal panel opens at once, as before.
///
/// Nothing runs until a page asks: the Downloads list, the screenshot folder and the clipboard's
/// types are read then, once. The clipboard's contents are read only when you pick it.
@MainActor
public final class UploadPicker {
  /// What the page's input accepts.
  public struct Request: Equatable {
    public var multiple = false
    public var directories = false
    /// MIME types and extensions from the input's `accept` (empty: anything). Wildcards like
    /// `image/*` are kept as they are.
    public var mimeTypes: [String] = []
    public var extensions: [String] = []

    public init(multiple: Bool = false, directories: Bool = false, mimeTypes: [String] = [], extensions: [String] = []) {
      (self.multiple, self.directories, self.mimeTypes, self.extensions) = (multiple, directories, mimeTypes, extensions)
    }

    /// WebKit passes `accept` only through WKOpenPanelParameters' private `_acceptedMIMETypes` /
    /// `_acceptedFileExtensions` (checked with `responds(to:)`; without them every file is offered).
    init(_ p: WKOpenPanelParameters) {
      multiple = p.allowsMultipleSelection
      directories = p.allowsDirectories
      func list(_ key: String) -> [String] {
        guard p.responds(to: NSSelectorFromString(key)) else { return [] }
        return (p.value(forKey: key) as? [String]) ?? []
      }
      mimeTypes = list("_acceptedMIMETypes").map { $0.lowercased() }
      extensions = list("_acceptedFileExtensions").map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    }

    public var acceptsAnything: Bool { mimeTypes.isEmpty && extensions.isEmpty }

    /// Whether a file of this type fits the input's `accept`.
    public func accepts(_ url: URL) -> Bool { accepts(ext: url.pathExtension) }

    public func accepts(ext: String) -> Bool {
      if acceptsAnything { return true }
      let e = ext.lowercased()
      if extensions.contains(e) { return true }
      guard let t = UTType(filenameExtension: e) else { return false }
      return mimeTypes.contains { m in Self.matches(t, mime: m) }
    }

    /// An image on the clipboard (saved as PNG) fits.
    public var acceptsImages: Bool { accepts(ext: "png") }

    static func matches(_ t: UTType, mime m: String) -> Bool {
      if m.hasSuffix("/*") {
        let family = String(m.dropLast(2))
        switch family {
        case "image": return t.conforms(to: .image)
        case "video": return t.conforms(to: .movie) || t.conforms(to: .video)
        case "audio": return t.conforms(to: .audio)
        case "text": return t.conforms(to: .text)
        default: return t.preferredMIMEType?.hasPrefix(family + "/") ?? false
        }
      }
      guard let want = UTType(mimeType: m) else { return false }
      return t.conforms(to: want)
    }
  }

  public struct Candidate: Equatable {
    public enum Kind: String { case download, screenshot, clipboard }
    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    /// An icon spec (IconView): a thumbnail path for images, `file:` for anything else.
    public var icon: String
    /// The file; nil for the clipboard (read when picked).
    public var url: URL?
    public var date: Date

    public init(id: String, kind: Kind, title: String, subtitle: String, icon: String, url: URL?, date: Date) {
      (self.id, self.kind, self.title, self.subtitle, self.icon, self.url, self.date) = (id, kind, title, subtitle, icon, url, date)
    }
  }

  weak var downloads: DownloadsService?
  /// Where macOS saves screenshots (the Screenshot app's setting, else the Desktop).
  public var screenshotFolder: () -> URL = UploadPicker.defaultScreenshotFolder
  public var pasteboard: NSPasteboard = .general
  public var now: () -> Date = Date.init
  /// Replaces what's offered (tests and `--scenario uploadPicker`); `[]` always opens the panel.
  public var fixed: ((Request) -> [Candidate])?
  /// At most this many per kind, and nothing older than a week.
  static let perKind = 3
  static let maxAge: TimeInterval = 7 * 86_400
  static let choicesKey = "\u{1}choices"

  public init(downloads: DownloadsService?) { self.downloads = downloads }

  nonisolated static func defaultScreenshotFolder() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    if let l = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !l.isEmpty {
      return URL(fileURLWithPath: (l as NSString).expandingTildeInPath, isDirectory: true)
    }
    return home.appendingPathComponent("Desktop", isDirectory: true)
  }

  // MARK: What to offer

  public func candidates(_ r: Request) -> [Candidate] {
    if r.directories { return [] }
    if let fixed { return fixed(r) }
    return recentDownloads(r) + screenshots(r) + clipboard(r)
  }

  func recentDownloads(_ r: Request) -> [Candidate] {
    guard let d = downloads else { return [] }
    d.load()
    let cutoff = now().addingTimeInterval(-Self.maxAge).timeIntervalSince1970 * 1000
    var out: [Candidate] = []
    for it in d.items where it.state == "done" && it.finished >= cutoff && !it.path.isEmpty {
      let u = URL(fileURLWithPath: it.path)
      guard r.accepts(u), FileManager.default.fileExists(atPath: u.path) else { continue }
      let date = Date(timeIntervalSince1970: it.finished / 1000)
      out.append(Candidate(id: "download:" + it.id, kind: .download, title: u.lastPathComponent,
                           subtitle: "Downloaded " + Self.ago(date, now: now()), icon: Self.icon(u), url: u, date: date))
      if out.count == Self.perKind { break }
    }
    return out
  }

  func screenshots(_ r: Request) -> [Candidate] {
    let dir = screenshotFolder()
    let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
    guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
    let cutoff = now().addingTimeInterval(-Self.maxAge)
    let shots: [(URL, Date)] = files.compactMap { u in
      let n = u.lastPathComponent
      guard n.hasPrefix("Screenshot") || n.hasPrefix("Screen Shot") || n.hasPrefix("Screen Recording"), r.accepts(u),
            let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, let d = v.creationDate, d >= cutoff else { return nil }
      return (u, d)
    }
    return shots.sorted { $0.1 > $1.1 }.prefix(Self.perKind).map { u, d in
      Candidate(id: "screenshot:" + u.path, kind: .screenshot, title: u.lastPathComponent, subtitle: "Screenshot · " + Self.ago(d, now: now()),
                icon: Self.icon(u), url: u, date: d)
    }
  }

  /// Only the clipboard's types are checked here, which macOS doesn't count as reading it.
  func clipboard(_ r: Request) -> [Candidate] {
    let types = pasteboard.types ?? []
    if types.contains(.fileURL) {
      return [Candidate(id: "clipboard", kind: .clipboard, title: "Copied file", subtitle: "From the clipboard", icon: "sf:doc.on.clipboard", url: nil, date: now())]
    }
    if r.acceptsImages, types.contains(.png) || types.contains(.tiff) {
      return [Candidate(id: "clipboard", kind: .clipboard, title: "Copied image", subtitle: "From the clipboard, saved as PNG", icon: "sf:photo.on.rectangle",
                        url: nil, date: now())]
    }
    return []
  }

  static func icon(_ u: URL) -> String {
    let t = UTType(filenameExtension: u.pathExtension)
    return (t?.conforms(to: .image) ?? false) ? u.path : "file:" + u.path
  }

  static func ago(_ d: Date, now: Date) -> String {
    // Whole seconds: a time stored in milliseconds comes back a hair off (59.9999 s is a minute).
    let s = max(0, now.timeIntervalSince(d).rounded())
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if s < 86_400 { let h = Int(s / 3600); return h == 1 ? "1 hour ago" : "\(h) hours ago" }
    let days = Int(s / 86_400)
    return days == 1 ? "yesterday" : "\(days) days ago"
  }

  /// The files for what was picked. The clipboard is read now: its file URLs, or its image saved
  /// as a PNG in a temporary folder.
  public func files(for picked: [Candidate], request r: Request) -> [URL] {
    var out: [URL] = []
    for c in picked {
      if let u = c.url { out.append(u); continue }
      if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
        out += urls.filter { r.accepts($0) }
      } else if let img = NSImage(pasteboard: pasteboard), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let u = dir.appendingPathComponent("Pasted Image \(f.string(from: now())).png")
        if (try? png.write(to: u)) != nil { out.append(u) }
      }
    }
    return r.multiple ? out : Array(out.prefix(1))
  }

  // MARK: The dialog

  static func tree(_ list: [Candidate], request r: Request, host: String) -> Value {
    let choices: [Value] = list.map { c in ["id": .string(c.id), "title": .string(c.title), "subtitle": .string(c.subtitle), "icon": .string(c.icon)] }
    return [
      "title": .string(host.isEmpty ? "Upload a file" : "Upload to \(host)"),
      "message": .string(r.multiple ? "Pick recent files, or choose any file on your Mac." : "Pick a recent file, or choose any file on your Mac."),
      "choices": .array(choices), "multiple": .bool(r.multiple),
      "buttons": [["id": "choose", "title": "Choose File…", "style": "secondary", "keycap": "⌘O"],
                  ["id": "cancel", "title": "Cancel", "style": "cancel"],
                  ["id": "upload", "title": "Upload", "style": "default"]],
    ]
  }

  /// Shows the picker when there's something to offer; false means "open the panel instead".
  func offer(_ r: Request, webView: WKWebView, prompts: WebPrompts, done: @escaping @MainActor ([URL]?) -> Void) -> Bool {
    let list = candidates(r)
    guard !list.isEmpty else { return false }
    let host = webView.url?.host ?? ""
    prompts.enqueue(Self.tree(list, request: r, host: host), webView, answer: { [weak self, weak webView] button, fields in
      guard let self else { return done(nil) }
      switch button {
      case "upload":
        let ids = (fields[Self.choicesKey] ?? "").split(separator: "\n").map(String.init)
        let picked = list.filter { ids.contains($0.id) }
        let urls = self.files(for: picked, request: r)
        done(urls.isEmpty ? nil : urls)
      case "choose":
        guard let webView else { return done(nil) }
        WebViewsService.runOpenPanel(r, webView: webView, done: done)
      default:
        done(nil)
      }
    }, cancel: { done(nil) })
    return true
  }
}
