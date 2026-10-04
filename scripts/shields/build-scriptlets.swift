// Builds Plugins/shields/resources/sites.json: uBlock Origin's site scriptlets (anti-adblock walls,
// pop-unders, ad-script traps) as data for den's scriptlet engine (Plugins/shields/resources/scriptlets.js).
//
//   swift scripts/shields/build-scriptlets.swift [list-file-or-url ...]
//
// Default lists: uBlock filters and uBlock filters – Quick fixes (assembled, from uAssetsCDN).
// Only `domain##+js(name, args…)` rules whose scriptlet den's engine implements are kept, for named
// hosts (no generic rules, no `name.*` entities, no regex domains); the YouTube hosts are left to
// scriptlets.json. `!#if` blocks are evaluated for den: every environment token is false (den is
// not uBO on Chrome, Firefox or Safari, and has no HTML filtering). Exceptions (`#@#+js`) remove the
// rule they name for their hosts. Rules with the same hosts are grouped into one set.
// Licence of the output: GPL-3.0, like uAssets (Plugins/shields/resources/NOTICE.md).
import Foundation

let lists = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : [
  "https://ublockorigin.github.io/uAssetsCDN/filters/filters.min.txt",
  "https://ublockorigin.github.io/uAssetsCDN/filters/quick-fixes.min.txt",
]
let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("Plugins/shields/resources/sites.json")

/// uBO scriptlet names (and aliases) den's engine runs, by the name the engine takes.
let supported: [String: String] = [
  "set": "set", "set-constant": "set",
  "aopr": "aopr", "abort-on-property-read": "aopr",
  "aopw": "aopw", "abort-on-property-write": "aopw",
  "acs": "acs", "acis": "acs", "abort-current-script": "acs", "abort-current-inline-script": "acs",
  "nostif": "nostif", "no-setTimeout-if": "nostif", "prevent-setTimeout": "nostif", "setTimeout-defuser": "nostif",
  "nosiif": "nosiif", "no-setInterval-if": "nosiif", "prevent-setInterval": "nosiif", "setInterval-defuser": "nosiif",
  "aeld": "aeld", "addEventListener-defuser": "aeld", "prevent-addEventListener": "aeld",
  "nowoif": "nowoif", "no-window-open-if": "nowoif", "prevent-window-open": "nowoif", "window.open-defuser": "nowoif",
  "no-fetch-if": "no-fetch-if", "prevent-fetch": "no-fetch-if",
  "no-xhr-if": "no-xhr-if", "prevent-xhr": "no-xhr-if",
  "nowebrtc": "nowebrtc",
  "nofab": "nofab", "nobab": "nofab", "fuckadblock.js-3.2.0": "nofab", "bab-defuser": "nofab", "prevent-bab": "nofab",
  "noeval": "noeval", "noeval-if": "noeval-if", "prevent-eval-if": "noeval-if",
  "ra": "ra", "remove-attr": "ra",
  "rc": "rc", "remove-class": "rc",
  "nano-stb": "nano-stb", "nano-setTimeout-booster": "nano-stb", "adjust-setTimeout": "nano-stb",
  "nano-sib": "nano-sib", "nano-setInterval-booster": "nano-sib", "adjust-setInterval": "nano-sib",
  "json-prune": "json-prune",
  "rmnt": "remove-node-text", "remove-node-text": "remove-node-text",
  "prevent-dom-bypass": "prevent-dom-bypass", "trusted-prevent-dom-bypass": "prevent-dom-bypass",
]
/// Hosts scriptlets.json owns.
let skipHosts = ["youtube.com", "youtube-nocookie.com", "youtubekids.com"]

func load(_ s: String) -> String {
  if s.hasPrefix("http") {
    let sem = DispatchSemaphore(value: 0)
    var text = ""
    URLSession.shared.dataTask(with: URL(string: s)!) { d, _, _ in text = d.map { String(decoding: $0, as: UTF8.self) } ?? ""; sem.signal() }.resume()
    sem.wait()
    if text.isEmpty { FileHandle.standardError.write("can't download \(s)\n".data(using: .utf8)!); exit(1) }
    return text
  }
  return (try? String(contentsOfFile: s, encoding: .utf8)) ?? ""
}

/// `!#if` expressions: every token is false; `!` negates; `&&` binds tighter than `||`.
func evaluate(_ expr: String) -> Bool {
  expr.components(separatedBy: "||").contains { conj in
    conj.components(separatedBy: "&&").allSatisfy { t in
      let t = t.trimmingCharacters(in: .whitespaces)
      return t.hasPrefix("!")  // "!token" is true when token is false
    }
  }
}

/// uBO's scriptlet argument list: comma separated, `\,` escapes a comma, an argument may be quoted.
func arguments(_ s: String) -> [String] {
  var args: [String] = [], cur = "", i = s.startIndex, quote: Character? = nil, started = false
  while i < s.endIndex {
    let c = s[i]
    if !started, c == " " { i = s.index(after: i); continue }
    if !started, cur.isEmpty, quote == nil, c == "'" || c == "\"" || c == "`" { quote = c; started = true; i = s.index(after: i); continue }
    started = true
    if c == "\\", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "," { cur.append(","); i = s.index(i, offsetBy: 2); continue }
    if let q = quote, c == q {
      quote = nil
      i = s.index(after: i)
      // Skip to the separator.
      while i < s.endIndex, s[i] != "," { i = s.index(after: i) }
      continue
    }
    if quote == nil, c == "," {
      args.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; started = false; i = s.index(after: i); continue
    }
    cur.append(c)
    i = s.index(after: i)
  }
  args.append(quote == nil ? cur.trimmingCharacters(in: .whitespaces) : cur)
  return args
}

struct Rule: Hashable { let rule: [String] }
var hostsByRule: [[String]: Set<String>] = [:]
var exceptions: [[String]: Set<String>] = [:]
var skipped: [String: Int] = [:]

for src in lists {
  var stack: [Bool] = []
  for raw in load(src).components(separatedBy: "\n") {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("!#if ") { stack.append(evaluate(String(line.dropFirst(5)))); continue }
    if line.hasPrefix("!#else") { if !stack.isEmpty { stack[stack.count - 1].toggle() }; continue }
    if line.hasPrefix("!#endif") { if !stack.isEmpty { stack.removeLast() }; continue }
    if stack.contains(false) || line.hasPrefix("!") || line.isEmpty { continue }
    let exception = line.contains("#@#+js(")
    guard let r = line.range(of: exception ? "#@#+js(" : "##+js("), line.hasSuffix(")") else { continue }
    let domains = line[..<r.lowerBound].split(separator: ",").map { String($0).lowercased() }
    let body = String(line[r.upperBound..<line.index(before: line.endIndex)])
    var args = arguments(body)
    var name = args.removeFirst()
    if name.hasSuffix(".js") { name.removeLast(3) }
    guard let engineName = supported[name] else { skipped["unsupported " + name, default: 0] += 1; continue }
    // Named hosts only.
    var hosts = Set<String>()
    for d in domains {
      if d.hasPrefix("~") || d.hasPrefix("/") || d.hasSuffix(".*") || d.contains("*") || !d.contains(".") { continue }
      if skipHosts.contains(where: { d == $0 || d.hasSuffix("." + $0) }) { continue }
      hosts.insert(d.hasPrefix("www.") ? String(d.dropFirst(4)) : d)
    }
    if hosts.isEmpty { skipped[domains.isEmpty ? "generic" : "no named host", default: 0] += 1; continue }
    // Arguments the engine reads as uBO does; anything that would carry code is refused there.
    while let last = args.last, last.isEmpty { args.removeLast() }
    let key = [engineName] + args
    if exception { exceptions[key, default: []].formUnion(hosts) } else { hostsByRule[key, default: []].formUnion(hosts) }
  }
}
for (k, hs) in exceptions { hostsByRule[k]?.subtract(hs) }

// Group rules by their exact host list.
var rulesByHosts: [[String]: [[String]]] = [:]
for (rule, hosts) in hostsByRule where !hosts.isEmpty {
  rulesByHosts[hosts.sorted(), default: []].append(rule)
}
let sets: [[String: Any]] = rulesByHosts.keys.sorted { $0.joined(separator: ",") < $1.joined(separator: ",") }.map { hosts in
  ["hosts": hosts, "rules": rulesByHosts[hosts]!.sorted { $0.joined(separator: "\u{1}") < $1.joined(separator: "\u{1}") }]
}
var setsOfHost: [String: [Int]] = [:]
for (i, s) in sets.enumerated() { for h in s["hosts"] as! [String] { setsOfHost[h, default: []].append(i) } }
let df = DateFormatter()
df.dateFormat = "yyyy.MM.dd"
df.timeZone = TimeZone(identifier: "UTC")
func json(_ v: Any) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]), as: UTF8.self)
}
// One JSON document, laid out so den can index it without parsing it (SitePolicyService.SiteIndex):
// a header line, then one `"host":[set, …],` line per host in byte order, then one set (its rules) per line.
var text = "{\"version\":" + (try json(df.string(from: Date()))) + ",\"source\":"
  + (try json("uBlock Origin's uAssets filters (filters.txt, quick-fixes.txt; GPL-3.0), site scriptlets den's engine runs")) + ",\"hosts\":{\n"
let hosts = setsOfHost.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
text += try hosts.map { try json($0) + ":" + json(setsOfHost[$0]!) }.joined(separator: ",\n")
text += "\n},\"sets\":[\n"
text += try sets.map { try json($0["rules"]!) }.joined(separator: ",\n")
text += "\n]}\n"
let data = Data(text.utf8)
_ = try JSONSerialization.jsonObject(with: data)  // still one valid JSON document
try data.write(to: out)
print("sites.json: \(sets.count) sets, \(hostsByRule.count) rules, \(hosts.count) hosts, \(data.count) bytes")
for (k, n) in skipped.sorted(by: { $0.value > $1.value }).prefix(12) { print("  skipped \(n): \(k)") }
