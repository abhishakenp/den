import Foundation

/// The thin-host guardrail's source scan (docs/architecture/thin-host.md §6, step 1). Finds three
/// kinds of feature knowledge in the host's Swift sources:
///
/// - `string`: an English UI string literal. A one-line literal that starts with a capital letter
///   and has a second word ("Clear Archive", "Open in \(name)"), or any capitalized literal handed
///   to an on-screen property (`title:`, `stringValue`, `toolTip`, `placeholderString`,
///   `messageText`, `informativeText`). Log lines, errors returned to plugins, comments and
///   multi-line literals (page scripts, HTML) are not UI and are skipped.
/// - `slot`: a named overlay slot (`"overlay.<name>"`).
/// - `call`: the host calling, or listening to, a service no host file provides (a plugin's
///   service, such as `tabs`, `spaces` or `commands`).
///
/// Scenarios (dev fixtures, not in release builds) are not scanned. Pure Foundation, so the same
/// file compiles into a standalone tool.
enum ThinHostScanner {
  struct Finding: Hashable, Comparable {
    let kind: String
    let file: String
    let text: String
    var line: String { "\(kind)\t\(file)\t\(text)" }
    static func < (a: Finding, b: Finding) -> Bool { a.line < b.line }
  }

  /// Host Swift files, relative to the repository root.
  static func sources(root: URL) -> [String] {
    var out: [String] = []
    for dir in ["Sources/DenHost", "Sources/Den"] {
      guard let e = FileManager.default.enumerator(atPath: root.appendingPathComponent(dir).path) else { continue }
      while let f = e.nextObject() as? String {
        guard f.hasSuffix(".swift"), !f.hasPrefix("Scenarios/") else { continue }
        // AdCheck drives the shields plugin for the adCheck scenario (dev tooling, like Scenarios).
        if dir == "Sources/Den", f == "AdCheck.swift" { continue }
        out.append(dir + "/" + f)
      }
    }
    return out.sorted()
  }

  /// Every service the host provides: `name = "x"` in a `HostService`, plus the ones registered
  /// directly on the plugin host.
  static func hostServices(root: URL, files: [String]) -> Set<String> {
    var names: Set<String> = ["plugins"]
    let re = try! NSRegularExpression(pattern: #"(?:public )?let name = "([a-z]+)""#)
    for f in files {
      guard let s = try? String(contentsOf: root.appendingPathComponent(f), encoding: .utf8) else { continue }
      for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
        names.insert(String(s[Range(m.range(at: 1), in: s)!]))
      }
    }
    return names
  }

  static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
  static let call = try! NSRegularExpression(pattern: #"\b(?:call|callPlugin)\(\s*"([a-z][a-zA-Z]*)"\s*,"#)
  static let on = try! NSRegularExpression(pattern: #"\.on\(\s*"([a-z][a-zA-Z]*)\.[a-zA-Z.]+""#)
  static let english = try! NSRegularExpression(pattern: #"^[A-Z][A-Za-z’']*[,:]?(?: |\\\()[^{};=<>]*[A-Za-z…?!.)]$"#)
  static let capitalized = try! NSRegularExpression(pattern: #"^[A-Z][a-z]+[A-Za-z…]*$"#)
  /// Lines whose literals never reach the screen.
  static let quiet = ["print(", "DenLog", ".write(", "log(", "Log.", "logger", ".debug(", ".info(", ".notice(", ".error(", ".fault(",
                      "fatalError(", "precondition", "assert", "NSLog(", "error(\"", "throw ", "Error(", "LaunchTrace", "trace(",
                      "NSSound", "UTType", "NSImage(named", "Notification.Name", "forKey", "identifier", "#selector", "accessibilityIdentifier"]
  static let uiProperty = ["title", "stringValue", "toolTip", "placeholderString", "messageText", "informativeText", "label"]

  static func scan(root: URL) -> [Finding] {
    let files = sources(root: root)
    let services = hostServices(root: root, files: files)
    var out: [Finding] = []
    for f in files {
      guard let s = try? String(contentsOf: root.appendingPathComponent(f), encoding: .utf8) else { continue }
      var inMultiline = false
      for raw in s.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        // Multi-line literals (page scripts, HTML, CSS) are never UI copy.
        let fences = line.components(separatedBy: "\"\"\"").count - 1
        if inMultiline || fences > 0 {
          if fences % 2 == 1 { inMultiline.toggle() }
          continue
        }
        if line.hasPrefix("//") || line.hasPrefix("///") || line.hasPrefix("*") { continue }
        let code = stripComment(line)
        let ns = NSRange(code.startIndex..., in: code)
        for m in call.matches(in: code, range: ns) {
          let svc = String(code[Range(m.range(at: 1), in: code)!])
          if !services.contains(svc) { out.append(Finding(kind: "call", file: f, text: svc)) }
        }
        for m in on.matches(in: code, range: ns) {
          let svc = String(code[Range(m.range(at: 1), in: code)!])
          if !services.contains(svc) { out.append(Finding(kind: "call", file: f, text: svc + ".*")) }
        }
        let isQuiet = quiet.contains { code.contains($0) }
        let isUI = uiProperty.contains { code.contains($0) }
        for m in literal.matches(in: code, range: ns) {
          let text = String(code[Range(m.range(at: 1), in: code)!])
          if text.hasPrefix("overlay."), text.count > 8, text.dropFirst(8).allSatisfy({ $0.isLetter }) {
            out.append(Finding(kind: "slot", file: f, text: text))
            continue
          }
          guard !isQuiet else { continue }
          let r = NSRange(text.startIndex..., in: text)
          if english.firstMatch(in: text, range: r) != nil || (isUI && capitalized.firstMatch(in: text, range: r) != nil) {
            out.append(Finding(kind: "string", file: f, text: text))
          }
        }
      }
    }
    return out.sorted()
  }

  /// The line without a trailing `// comment` (outside string literals).
  static func stripComment(_ line: String) -> String {
    var inString = false, escaped = false, prev: Character = " "
    for (i, c) in zip(line.indices, line) {
      if inString {
        if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
      } else if c == "\"" {
        inString = true
      } else if c == "/", prev == "/" {
        return String(line[..<line.index(before: i)])
      }
      prev = c
    }
    return line
  }

  /// Allowlist file lines (`kind<TAB>file<TAB>text`, `#` comments) as a multiset.
  static func parse(_ text: String) -> [String: Int] {
    var m: [String: Int] = [:]
    for l in text.components(separatedBy: "\n") where !l.isEmpty && !l.hasPrefix("#") { m[l, default: 0] += 1 }
    return m
  }

  static let header = """
    # Thin-host guardrail allowlist (docs/architecture/thin-host.md §6, step 1; ThinHostGuardrailTests).
    # Feature knowledge the host still holds: English UI strings, named overlay slots, and calls to
    # plugin services. One line per occurrence: kind<TAB>file<TAB>text. Each migration step removes
    # lines; a new line needs a reason the code can't take the copy or policy from a plugin.
    # Regenerate: DEN_THIN_HOST_ALLOWLIST=write swift test --filter ThinHostGuardrail
    """
}
