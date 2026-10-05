import DenTestSupport
import Foundation
import Testing

/// Thin-host guardrail (docs/architecture/thin-host.md §6, step 1): the host may not gain feature
/// knowledge. New English UI strings in `Sources/DenHost` / `Sources/Den` (outside Scenarios), new
/// `overlay.*` slots and new host calls to plugin services fail here. Today's are listed in
/// `Tests/Fixtures/thin-host-allowlist.txt`; each migration step removes its lines (a line that no
/// longer matches the code fails too, so the list only shrinks with the code).
/// `DEN_THIN_HOST_ALLOWLIST=write` rewrites the list from the sources.
@Suite(.watchdog)
struct ThinHostGuardrailTests {
  static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  static let allowlist = root.appendingPathComponent("Tests/Fixtures/thin-host-allowlist.txt")

  @Test func hostGainsNoFeatureKnowledge() throws {
    let found = ThinHostScanner.scan(root: Self.root)
    #expect(found.count > 50, "the scan found almost nothing: is the repository root right? \(Self.root.path)")
    if ProcessInfo.processInfo.environment["DEN_THIN_HOST_ALLOWLIST"] == "write" {
      let text = ThinHostScanner.header + "\n" + found.map(\.line).joined(separator: "\n") + "\n"
      try text.write(to: Self.allowlist, atomically: true, encoding: .utf8)
      return
    }
    let allowed = ThinHostScanner.parse(try String(contentsOf: Self.allowlist, encoding: .utf8))
    var seen: [String: Int] = [:]
    for f in found { seen[f.line, default: 0] += 1 }
    let added = seen.flatMap { line, n in Array(repeating: line, count: max(0, n - (allowed[line] ?? 0))) }.sorted()
    let gone = allowed.flatMap { line, n in Array(repeating: line, count: max(0, n - (seen[line] ?? 0))) }.sorted()
    #expect(added.isEmpty, """
      New feature knowledge in the host (kind, file, text). Take the string, slot or service from a \
      plugin instead (docs/architecture/thin-host.md); if it truly can't, regenerate the allowlist with \
      DEN_THIN_HOST_ALLOWLIST=write swift test --filter ThinHostGuardrail and say why in the commit:
      \(added.joined(separator: "\n"))
      """)
    #expect(gone.isEmpty, """
      These allowlist lines no longer match the host (good: migrated or reworded). Remove them from \
      Tests/Fixtures/thin-host-allowlist.txt (or regenerate with DEN_THIN_HOST_ALLOWLIST=write):
      \(gone.joined(separator: "\n"))
      """)
  }

  /// The scanner itself: what counts and what doesn't.
  @Test func scannerRules() {
    #expect(ThinHostScanner.stripComment(#"let a = "x // y" // note"#) == #"let a = "x // y" "#)
    let english = ThinHostScanner.english
    func isEnglish(_ s: String) -> Bool { english.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    #expect(isEnglish("Clear Archive"))
    #expect(isEnglish("Open in \\(name)"))
    #expect(isEnglish("This page says"))
    #expect(!isEnglish("sf:xmark"))
    #expect(!isEnglish("overlay.peek"))
    #expect(!isEnglish("Return"))
    #expect(!isEnglish("EEEE"))
  }
}
