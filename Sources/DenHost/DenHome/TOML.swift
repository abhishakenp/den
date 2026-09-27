import CordisValue
import Foundation

/// A small TOML reader for `~/.den/config.toml` and theme files. Produces a `Value` object with
/// keys in file order.
///
/// Supported: `# comments`, `[table]` and `[a.b]` headers, `key = value` with bare, quoted and
/// dotted keys, basic ("…" with \" \\ \n \t \r \uXXXX escapes) and literal ('…') strings,
/// integers (`_` separators, sign), floats, booleans, arrays (multi-line, trailing comma) and
/// inline tables `{ k = v }`. Not supported: `[[arrays of tables]]`, multi-line strings, dates.
public enum TOML {
  public struct ParseError: Error, Equatable, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
  }

  public static func parse(_ text: String) throws(ParseError) -> Value {
    var p = Parser(Array(text.unicodeScalars))
    return try p.document()
  }

  struct Parser {
    let s: [Unicode.Scalar]
    var i = 0
    var line = 1
    init(_ s: [Unicode.Scalar]) { self.s = s }

    var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }

    func fail(_ m: String) -> ParseError { ParseError(line: line, message: m) }

    mutating func advance() {
      if s[i] == "\n" { line += 1 }
      i += 1
    }

    /// Spaces and tabs only.
    mutating func skipBlank() { while let c = peek, c == " " || c == "\t" { advance() } }

    mutating func skipComment() {
      if peek == "#" { while let c = peek, c != "\n" { advance() } }
    }

    /// Whitespace, newlines and comments (inside arrays).
    mutating func skipAll() {
      while let c = peek {
        if c == " " || c == "\t" || c == "\n" || c == "\r" { advance() } else if c == "#" { skipComment() } else { return }
      }
    }

    /// After a key/value or header: only a comment may follow on the line.
    mutating func endOfLine() throws(ParseError) {
      skipBlank()
      skipComment()
      if peek == "\r" { advance() }
      guard let c = peek else { return }
      guard c == "\n" else { throw fail("expected end of line, found '\(c)'") }
      advance()
    }

    mutating func document() throws(ParseError) -> Value {
      var root: [(String, Value)] = []
      var table: [String] = []
      var defined: Set<String> = []
      while true {
        skipAll()
        guard let c = peek else { break }
        if c == "[" {
          advance()
          if peek == "[" { throw fail("arrays of tables ([[…]]) are not supported") }
          skipBlank()
          let path = try key()
          skipBlank()
          guard peek == "]" else { throw fail("expected ']'") }
          advance()
          let joined = path.joined(separator: ".")
          guard defined.insert(joined).inserted else { throw fail("table [\(joined)] defined twice") }
          try Self.ensureTable(&root, path, line: line)
          table = path
          try endOfLine()
        } else {
          let path = try key()
          skipBlank()
          guard peek == "=" else { throw fail("expected '=' after key") }
          advance()
          skipBlank()
          let v = try value()
          try Self.insert(&root, table + path, v, line: line)
          try endOfLine()
        }
      }
      return .object(root)
    }

    mutating func key() throws(ParseError) -> [String] {
      var parts: [String] = []
      while true {
        skipBlank()
        guard let c = peek else { throw fail("expected a key") }
        if c == "\"" {
          parts.append(try basicString())
        } else if c == "'" {
          parts.append(try literalString())
        } else {
          var k = ""
          while let c = peek, Self.isBare(c) {
            k.unicodeScalars.append(c)
            advance()
          }
          guard !k.isEmpty else { throw fail("expected a key, found '\(c)'") }
          parts.append(k)
        }
        skipBlank()
        guard peek == "." else { return parts }
        advance()
      }
    }

    static func isBare(_ c: Unicode.Scalar) -> Bool {
      ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "_" || c == "-"
    }

    mutating func value() throws(ParseError) -> Value {
      guard let c = peek else { throw fail("expected a value") }
      switch c {
      case "\"": return .string(try basicString())
      case "'": return .string(try literalString())
      case "[": return try array()
      case "{": return try inlineTable()
      default: return try scalar()
      }
    }

    mutating func basicString() throws(ParseError) -> String {
      advance()  // opening quote
      if peek == "\"", i + 1 < s.count, s[i + 1] == "\"" { throw fail("multi-line strings are not supported") }
      var out = ""
      while true {
        guard let c = peek, c != "\n" else { throw fail("unterminated string") }
        advance()
        if c == "\"" { return out }
        if c != "\\" {
          out.unicodeScalars.append(c)
          continue
        }
        guard let e = peek else { throw fail("unterminated string") }
        advance()
        switch e {
        case "\"": out += "\""
        case "\\": out += "\\"
        case "n": out += "\n"
        case "t": out += "\t"
        case "r": out += "\r"
        case "b": out += "\u{8}"
        case "f": out += "\u{c}"
        case "u", "U":
          let n = e == "u" ? 4 : 8
          var hex = ""
          for _ in 0..<n {
            guard let h = peek else { throw fail("bad \\\(e) escape") }
            hex.unicodeScalars.append(h)
            advance()
          }
          guard let code = UInt32(hex, radix: 16), let u = Unicode.Scalar(code) else { throw fail("bad \\\(e) escape") }
          out.unicodeScalars.append(u)
        default: throw fail("unknown escape \\\(e)")
        }
      }
    }

    mutating func literalString() throws(ParseError) -> String {
      advance()
      var out = ""
      while true {
        guard let c = peek, c != "\n" else { throw fail("unterminated string") }
        advance()
        if c == "'" { return out }
        out.unicodeScalars.append(c)
      }
    }

    mutating func array() throws(ParseError) -> Value {
      advance()  // [
      var items: [Value] = []
      while true {
        skipAll()
        guard let c = peek else { throw fail("unterminated array") }
        if c == "]" {
          advance()
          return .array(items)
        }
        items.append(try value())
        skipAll()
        if peek == "," {
          advance()
        } else if peek != "]" {
          throw fail("expected ',' or ']' in array")
        }
      }
    }

    mutating func inlineTable() throws(ParseError) -> Value {
      advance()  // {
      var pairs: [(String, Value)] = []
      skipBlank()
      if peek == "}" {
        advance()
        return .object([])
      }
      while true {
        let path = try key()
        skipBlank()
        guard peek == "=" else { throw fail("expected '=' in inline table") }
        advance()
        skipBlank()
        let v = try value()
        try Self.insert(&pairs, path, v, line: line)
        skipBlank()
        guard let c = peek else { throw fail("unterminated inline table") }
        advance()
        if c == "}" { return .object(pairs) }
        guard c == "," else { throw fail("expected ',' or '}' in inline table") }
      }
    }

    /// Booleans and numbers: read up to a delimiter, then interpret.
    mutating func scalar() throws(ParseError) -> Value {
      var t = ""
      while let c = peek, !(c == "," || c == "]" || c == "}" || c == " " || c == "\t" || c == "\n" || c == "\r" || c == "#") {
        t.unicodeScalars.append(c)
        advance()
      }
      if t == "true" { return .bool(true) }
      if t == "false" { return .bool(false) }
      if t.isEmpty { throw fail("expected a value") }
      let digits = t.replacingOccurrences(of: "_", with: "")
      if digits.hasPrefix("0x"), let n = Int64(digits.dropFirst(2), radix: 16) { return .int(n) }
      if let n = Int64(digits) { return .int(n) }
      let first = digits.unicodeScalars.first!
      if ("0"..."9").contains(first) || first == "-" || first == "+", let d = Double(digits), d.isFinite { return .double(d) }
      throw fail("unknown value '\(t)' (strings need quotes)")
    }

    // MARK: Tree building

    static func ensureTable(_ pairs: inout [(String, Value)], _ path: [String], line: Int) throws(ParseError) {
      guard let head = path.first else { return }
      if let j = pairs.firstIndex(where: { $0.0 == head }) {
        guard case var .object(inner) = pairs[j].1 else { throw ParseError(line: line, message: "'\(head)' is not a table") }
        try ensureTable(&inner, Array(path.dropFirst()), line: line)
        pairs[j].1 = .object(inner)
      } else {
        var inner: [(String, Value)] = []
        try ensureTable(&inner, Array(path.dropFirst()), line: line)
        pairs.append((head, .object(inner)))
      }
    }

    static func insert(_ pairs: inout [(String, Value)], _ path: [String], _ v: Value, line: Int) throws(ParseError) {
      guard let head = path.first else { return }
      if path.count == 1 {
        guard !pairs.contains(where: { $0.0 == head }) else { throw ParseError(line: line, message: "key '\(head)' defined twice") }
        pairs.append((head, v))
        return
      }
      if let j = pairs.firstIndex(where: { $0.0 == head }) {
        guard case var .object(inner) = pairs[j].1 else { throw ParseError(line: line, message: "'\(head)' is not a table") }
        try insert(&inner, Array(path.dropFirst()), v, line: line)
        pairs[j].1 = .object(inner)
      } else {
        var inner: [(String, Value)] = []
        try insert(&inner, Array(path.dropFirst()), v, line: line)
        pairs.append((head, .object(inner)))
      }
    }
  }
}
