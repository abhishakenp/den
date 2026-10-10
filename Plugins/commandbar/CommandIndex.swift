// The command bar's launcher index: every den command, destination, settings pane and setting,
// lowercased once when the bar opens, so matching a keystroke is byte compares with no string
// building. See docs/plugin-services.md (`commands`, "Launcher").

#if !hasFeature(Embedded)
  import CordisValue
#endif

/// One searchable den item.
final class IndexEntry {
  enum Kind: Equatable {
    case command  // a built-in or registered command (destinations are commands too)
    case pane  // a Settings section
    case setting  // one setting inside a section
  }

  var kind: Kind
  var id: String  // command id, pane id or setting key
  var title: String
  var subtitle = ""  // "Settings › Appearance"
  var icon: String
  var shortcut = ""
  var shortcutRef = ""  // resolve the shortcut live from this ref (a keys.bind event or menu id)
  var section: String  // row header: "den" or "Settings"
  // Settings
  var pane = ""
  var type = ""  // toggle | choice | text | number | action
  var value: Value = .null
  var options: [(Value, String)] = []  // (value, title); On / Off for toggles
  var plugin = ""  // set through `<plugin>.settings {field: value}` while there's no `settings` service
  var field = ""
  // Precomputed, lowercased UTF-8.
  var t: [UInt8] = []
  var aliases: [[UInt8]] = []
  var keywords: [[UInt8]] = []
  var path: [UInt8] = []
  var initials: [UInt8] = []
  var usageKey = ""  // = rowId, built once
  var usage = 0  // frecency score when the index was built
  /// Which letters and digits appear anywhere in the entry's text: a query word with a character
  /// outside it can't match, so most entries are rejected with one AND.
  var mask: UInt64 = 0

  init(kind: Kind, id: String, title: String, icon: String, section: String, aliases: [String] = [], keywords: [String] = [], path: String = "") {
    self.kind = kind
    self.id = id
    self.title = title
    self.icon = icon
    self.section = section
    t = Matcher.bytes(title)
    self.aliases = aliases.map { Matcher.bytes($0) }
    self.keywords = keywords.map { Matcher.bytes($0) }
    self.path = Matcher.bytes(path)
    initials = Matcher.initials(t)
    usageKey = rowId
    mask = Matcher.mask(t) | Matcher.mask(self.path)
    for a in self.aliases { mask |= Matcher.mask(a) }
    for k in self.keywords { mask |= Matcher.mask(k) }
  }

  /// The row id, which is also the frecency key ("cmd:den.settings", "set:appearance.webDark").
  var rowId: String {
    switch kind {
    case .command: return "cmd:" + id
    case .pane: return "pane:" + id
    case .setting: return "set:" + id
    }
  }

  /// The option whose value is the current one.
  var currentOption: String {
    for o in options where o.0 == value { return o.1 }
    return ""
  }
}

/// Byte-level matching over precomputed lowercase text. A query is split into words once per
/// keystroke; each entry is then scored with compares only.
enum Matcher {
  /// Exact title or alias, or the whole query is a prefix of it.
  static let exact = 100
  static let alias = 95  // the query is a prefix of an alias
  static let phrase = 90  // a multi-word query starts a later word of the title
  static let wordPrefix = 70
  static let initialsPrefix = 65  // "dm" → "Dark Mode"
  static let keyword = 60
  static let path = 50  // the settings section ("appearance" → every Appearance setting)
  static let substring = 40
  static let fuzzy = 25  // letters in order, 3+ letters

  static func bytes(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count)
    for c in s.utf8 { out.append(c >= 65 && c <= 90 ? c + 32 : c) }
    return out
  }

  /// The query's words (lowercased), and the whole query with single spaces.
  /// Bit per character class: a-z, 0-9, anything else (one bit).
  static func mask(_ b: [UInt8]) -> UInt64 {
    var m: UInt64 = 0
    for c in b {
      if c >= 97 && c <= 122 { m |= 1 << UInt64(c - 97) } else if c >= 48 && c <= 57 { m |= 1 << UInt64(c - 48 + 26) } else if c != 32 { m |= 1 << 36 }
    }
    return m
  }

  static func words(_ q: String) -> (words: [[UInt8]], phrase: [UInt8], mask: UInt64) {
    var words: [[UInt8]] = []
    var cur: [UInt8] = []
    for c in q.utf8 {
      if c == 32 || c == 9 || c == 10 {
        if !cur.isEmpty { words.append(cur) }
        cur = []
      } else {
        cur.append(c >= 65 && c <= 90 ? c + 32 : c)
      }
    }
    if !cur.isEmpty { words.append(cur) }
    var phrase: [UInt8] = []
    for w in words {
      if !phrase.isEmpty { phrase.append(32) }
      phrase += w
    }
    return (words, phrase, mask(phrase))
  }

  static func isWord(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 97 && c <= 122) || c >= 128 }

  /// First letters of each word ("dark mode for websites" → "dmfw").
  static func initials(_ t: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var prev: UInt8 = 32
    for c in t {
      if isWord(c) && !isWord(prev) { out.append(c) }
      prev = c
    }
    return out
  }

  @inline(__always)
  static func prefix(_ s: [UInt8], _ w: [UInt8]) -> Bool {
    guard s.count >= w.count else { return false }
    var j = 0
    while j < w.count {
      if s[j] != w[j] { return false }
      j += 1
    }
    return true
  }

  /// `w` starts a word of `s` (after the first).
  static func wordPrefix(_ s: [UInt8], _ w: [UInt8]) -> Bool {
    guard !w.isEmpty, s.count > w.count else { return false }
    var start = 1
    while start + w.count <= s.count {
      if !isWord(s[start - 1]) && isWord(s[start]) {
        var j = 0
        while j < w.count && s[start + j] == w[j] { j += 1 }
        if j == w.count { return true }
      }
      start += 1
    }
    return false
  }

  static func contains(_ s: [UInt8], _ w: [UInt8]) -> Bool {
    guard !w.isEmpty, s.count >= w.count else { return w.isEmpty }
    var start = 0
    while start + w.count <= s.count {
      var j = 0
      while j < w.count && s[start + j] == w[j] { j += 1 }
      if j == w.count { return true }
      start += 1
    }
    return false
  }

  /// Every byte of `w` appears in `s` in order.
  static func subsequence(_ s: [UInt8], _ w: [UInt8]) -> Bool {
    var j = 0
    for c in s where j < w.count && c == w[j] { j += 1 }
    return j == w.count
  }

  /// How well one query word matches the entry; 0 = not at all.
  static func word(_ w: [UInt8], _ e: IndexEntry) -> Int {
    if prefix(e.t, w) { return exact }
    var best = 0
    for a in e.aliases where prefix(a, w) { best = max(best, a.count == w.count ? exact : alias) }
    if best >= alias { return best }
    if wordPrefix(e.t, w) { return wordPrefix }
    if w.count >= 2 && prefix(e.initials, w) { return initialsPrefix }
    for k in e.keywords where prefix(k, w) || wordPrefix(k, w) { return keyword }
    if prefix(e.path, w) || wordPrefix(e.path, w) { return path }
    if contains(e.t, w) { return substring }
    if w.count >= 3 && subsequence(e.t, w) { return fuzzy }
    return 0
  }

  /// The entry's match strength for the query, 0–100; nil when any word misses. A query that is a
  /// prefix of the title or an alias as a whole ("dark mode" → "Dark mode for websites") is exact.
  static func score(_ q: (words: [[UInt8]], phrase: [UInt8], mask: UInt64), _ e: IndexEntry) -> Int? {
    if q.words.isEmpty { return 0 }
    // Every word must match somewhere, so every query character must occur in the entry.
    if q.mask & ~e.mask != 0 { return nil }
    if q.words.count > 1 {
      if prefix(e.t, q.phrase) { return exact }
      for a in e.aliases where prefix(a, q.phrase) { return a.count == q.phrase.count ? exact : alias }
      // Several words in a row inside the title ("search engine" → "Default search engine").
      if wordPrefix(e.t, q.phrase) { return phrase }
    }
    var total = 0
    for w in q.words {
      let s = word(w, e)
      if s == 0 { return nil }
      total += s
    }
    return total / q.words.count
  }
}
