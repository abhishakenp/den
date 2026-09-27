import AppKit
import CordisValue
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation

/// `translate` service: language detection (NaturalLanguage) and translation (Apple's
/// Translation framework), both on device: text in, text out, no network.
///
/// | Method | Args | Returns |
/// |---|---|---|
/// | `detect` | `text`, `hint?` (e.g. a page's `lang`) | `{lang, confidence}`: a base code ("fr"), or `lang: ""` when unsure |
/// | `userLanguage` | – | `{lang}`: the first preferred language ("en") |
/// | `availability` | `from`, `to?` | `{request}`, then `translate.availability {request, status: installed\|supported\|unsupported}` |
/// | `run` | `texts: [string]`, `from`, `to?`, `request?` | `{request}`, then `translate.result {request, ok, texts, from, to, ms, error?, needsDownload?}` |
///
/// `run` keeps one session per language pair while den runs. When the pair is supported but not
/// downloaded, a hidden 1x1 SwiftUI `translationTask` view in den's window lets macOS show its
/// own download prompt; declining it ends with `error: "notInstalled"`.
@MainActor
public final class TranslateService: HostService {
  public let name = "translate"
  let host: ServiceHost
  /// The window a download prompt attaches to.
  var window: () -> NSWindow? = { nil }
  private var sessions: [String: TranslationSession] = [:]
  private var nextRequest = 1

  public init(host: ServiceHost) { self.host = host }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "detect":
      let (lang, p) = Self.detect(args.str("text"), hint: args.str("hint"))
      return ["lang": .string(lang ?? ""), "confidence": .double(p), "name": .string(lang.map(Self.displayName) ?? "")]
    case "userLanguage": return ["lang": .string(Self.userLanguage)]
    case "availability":
      let request = newRequest(args)
      let from = args.str("from"), to = args.str("to", Self.userLanguage)
      Task {
        let s = await LanguageAvailability().status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
        host.emit("translate.availability", ["request": .string(request), "from": .string(from), "to": .string(to), "status": .string(Self.name(s))])
      }
      return ["request": .string(request)]
    case "run":
      let request = newRequest(args)
      let texts = args.list("texts").map { $0.string ?? "" }
      let from = args.str("from"), to = args.str("to", Self.userLanguage)
      guard !from.isEmpty else { return .error("translate: 'from' is required (see detect)") }
      Task { await run(request, texts, from: from, to: to) }
      return ["request": .string(request)]
    default: return .error("translate: unknown method '\(method)'")
    }
  }

  private func newRequest(_ args: Value) -> String {
    let r = args.str("request")
    if !r.isEmpty { return r }
    defer { nextRequest += 1 }
    return "translate-\(nextRequest)"
  }

  static func name(_ s: LanguageAvailability.Status) -> String {
    switch s {
    case .installed: return "installed"
    case .supported: return "supported"
    default: return "unsupported"
    }
  }

  private func run(_ request: String, _ texts: [String], from: String, to: String) async {
    let t0 = Date()
    let source = Locale.Language(identifier: from), target = Locale.Language(identifier: to)
    let key = from + ">" + to
    func fail(_ e: String, needsDownload: Bool = false) {
      host.emit("translate.result", ["request": .string(request), "ok": false, "error": .string(e), "from": .string(from), "to": .string(to),
                                     "needsDownload": .bool(needsDownload)])
    }
    if from == to { return fail("same language") }
    var session = sessions[key]
    if session == nil {
      switch await LanguageAvailability().status(from: source, to: target) {
      case .installed:
        session = TranslationSession(installedSource: source, target: target)
      case .supported:
        // The prompt's session only lives inside its view's task; once the model is installed,
        // a normal installed-source session takes over.
        guard await download(source: source, target: target) else { return fail("notInstalled", needsDownload: true) }
        session = TranslationSession(installedSource: source, target: target)
      default:
        return fail("unsupported")
      }
      sessions[key] = session
    }
    guard let session else { return fail("unsupported") }
    var out = texts
    nonisolated(unsafe) let requests = texts.enumerated().compactMap { i, t in
      t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : TranslationSession.Request(sourceText: t, clientIdentifier: String(i))
    }
    if !requests.isEmpty {
      do {
        for r in try await session.translations(from: requests) {
          if let s = r.clientIdentifier, let i = Int(s), i < out.count { out[i] = r.targetText }
        }
      } catch {
        sessions[key] = nil
        return fail(error.localizedDescription)
      }
    }
    host.emit("translate.result", ["request": .string(request), "ok": true, "texts": .array(out.map { .string($0) }), "from": .string(from), "to": .string(to),
                                   "ms": .int(Int64(Date().timeIntervalSince(t0) * 1000))])
  }

  /// Downloads a supported pair's model: macOS asks first, in its own sheet. True when installed.
  private func download(source: Locale.Language, target: Locale.Language) async -> Bool {
    guard let content = window()?.contentView else { return false }
    var holder: NSView?
    let ok: Bool = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      let view = NSHostingView(rootView: DownloadPrompt(config: .init(source: source, target: target)) { s in
        do {
          try await s.prepareTranslation()
          c.resume(returning: true)
        } catch {
          c.resume(returning: false)
        }
      })
      view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
      content.addSubview(view)
      holder = view
    }
    holder?.removeFromSuperview()
    return ok
  }

  /// "French" for "fr", in the user's language.
  static func displayName(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code) ?? code }

  /// The user's language ("en"), from the first preferred language.
  static var userLanguage: String {
    Locale.Language(identifier: Locale.preferredLanguages.first ?? "en").languageCode?.identifier ?? "en"
  }

  /// Dominant language of `text` as a base code ("fr"), with its probability. Falls back to
  /// `hint` when the text is short or ambiguous.
  static func detect(_ text: String, hint: String) -> (String?, Double) {
    let hinted = hint.isEmpty ? nil : Locale.Language(identifier: hint).languageCode?.identifier
    guard text.count >= 20 else { return (hinted, hinted == nil ? 0 : 0.5) }
    let r = NLLanguageRecognizer()
    r.processString(text)
    guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.5, lang != .undetermined else { return (hinted, 0) }
    return (Locale.Language(identifier: lang.rawValue).languageCode?.identifier ?? lang.rawValue, p)
  }
}

private struct DownloadPrompt: View {
  let config: TranslationSession.Configuration
  let action: @MainActor (TranslationSession) async -> Void
  var body: some View {
    Color.clear.frame(width: 1, height: 1).translationTask(config) { session in await action(session) }
  }
}
