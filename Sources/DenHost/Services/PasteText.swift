import AppKit

/// "Paste and Go" / "Paste and Search": what's on the clipboard, read only when a menu opens or
/// the item is picked (never at launch, never polled).
@MainActor
enum PasteText {
  /// Longest text offered: a longer clipboard is almost never meant for the address field.
  static let maxLength = 2048
  /// The clipboard den reads and writes here (tests swap in a private pasteboard).
  static var board: NSPasteboard = .general

  /// The clipboard's text, trimmed, when it is one line of at most `maxLength` characters.
  static func read(_ board: NSPasteboard? = nil) -> String? {
    let pb = board ?? Self.board
    guard let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
          s.count <= maxLength, !s.contains("\n"), !s.contains("\r") else { return nil }
    return s
  }

  /// Whether `s` opens as an address rather than a search. The same rule as the command bar's
  /// `CommandBarCore.url(from:)` (the plugin can't be called from here); `PasteTests` checks both
  /// agree on the same inputs.
  nonisolated static func isURL(_ s: String) -> Bool {
    // An existing local file or folder (the bar asks `app.fileInfo` for the same answer).
    if LocalFiles.looksLikePath(s), LocalFiles.existing(s) != nil { return true }
    if s.isEmpty || s.contains(" ") { return false }
    // ASCII lowercasing, like the plugin's `Text.lower`: byte offsets stay those of `s`.
    let lb = s.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
    let l = String(decoding: lb, as: UTF8.self)
    for scheme in ["http://", "https://", "about:", "file://", "data:"] where l.hasPrefix(scheme) { return true }
    if l.hasPrefix("localhost") { return true }
    let hostEnd = lb.firstIndex { $0 == 47 || $0 == 58 || $0 == 63 || $0 == 35 } ?? lb.count
    let host = lb[0..<hostEnd]
    guard let lastDot = host.lastIndex(of: 46), lastDot > host.startIndex else { return false }
    let tld = host[(lastDot + 1)...]
    if host.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 }) { return true }
    guard tld.count >= 2, tld.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return false }
    return host.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 >= 128 }
  }

  /// The menu title for the clipboard now: `urlTitle` for an address, `searchTitle` for other
  /// text, nil when there is nothing to paste (the item is left out).
  static func title(url urlTitle: String, search searchTitle: String) -> String? {
    guard let s = read() else { return nil }
    return isURL(s) ? urlTitle : searchTitle
  }
}
