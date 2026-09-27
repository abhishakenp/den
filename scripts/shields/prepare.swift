// Validates WebKit content-rule JSON against this Mac's WebKit, drops rules WebKit refuses, splits
// lists over WebKit's 150,000-rule cap, and writes LZFSE-compressed copies for den's bundle.
//   swiftc -O scripts/shields/prepare.swift -o build/shields-prepare
//   build/shields-prepare <out-dir> <name>=<rules.json>...
// Prints one line per list: rules kept, dropped, compile time, compiled size. Uses a throwaway
// WKContentRuleListStore, never den's.
import AppKit
import Foundation
import WebKit

let maxRules = 150_000
let args = CommandLine.arguments.dropFirst()
guard let outDir = args.first.map({ URL(fileURLWithPath: $0) }) else {
  print("usage: shields-prepare <out-dir> <name>=<rules.json>...")
  exit(2)
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let tmpStore = FileManager.default.temporaryDirectory.appendingPathComponent("den-shields-prepare-\(getpid())")
try? FileManager.default.createDirectory(at: tmpStore, withIntermediateDirectories: true)
let store = WKContentRuleListStore(url: tmpStore)!

/// Compiles synchronously (spinning the main run loop), returning the error text or nil.
@MainActor func compile(_ id: String, _ json: String) -> (error: String?, ms: Double) {
  var done = false
  var err: String?
  let t0 = Date()
  store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { _, e in
    err = e.map { (($0 as NSError).userInfo[NSHelpAnchorErrorKey] as? String) ?? "\($0)" }
    done = true
  }
  while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
  return (err, Date().timeIntervalSince(t0) * 1000)
}

func encode(_ rules: [Any]) -> String {
  String(data: try! JSONSerialization.data(withJSONObject: rules, options: [.withoutEscapingSlashes]), encoding: .utf8)!
}

/// Rules WebKit refuses (bisection: a bad rule fails its whole half).
@MainActor func badRules(_ rules: [Any], _ offset: Int = 0) -> [Int] {
  if rules.isEmpty { return [] }
  if compile("probe", encode(rules)).error == nil { return [] }
  if rules.count == 1 { return [offset] }
  let mid = rules.count / 2
  return badRules(Array(rules[..<mid]), offset) + badRules(Array(rules[mid...]), offset + mid)
}

func isException(_ r: Any) -> Bool {
  ((r as? [String: Any])?["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules"
}

MainActor.assumeIsolated {
  _ = NSApplication.shared
  for spec in args.dropFirst() {
    let kv = spec.split(separator: "=", maxSplits: 1).map(String.init)
    let name = kv[0], path = kv[1]
    var rules = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [Any]
    let first = compile(name, encode(rules))
    var dropped = 0
    if first.error != nil {
      let bad = Set(badRules(rules))
      dropped = bad.count
      rules = rules.enumerated().filter { !bad.contains($0.offset) }.map(\.element)
    }
    // WebKit applies `ignore-previous-rules` only within its own list, so every part keeps all
    // exceptions after its own share of the other rules.
    let exceptions = rules.filter(isException)
    let others = rules.filter { !isException($0) }
    let per = maxRules - exceptions.count
    var parts: [[Any]] = []
    var i = 0
    repeat {
      parts.append(Array(others[i..<min(others.count, i + per)]) + exceptions)
      i += per
    } while i < others.count
    for (n, part) in parts.enumerated() {
      let partName = parts.count == 1 ? name : "\(name)-\(n + 1)"
      let json = encode(part)
      let c = compile(partName, json)
      guard c.error == nil else { print("\(partName): FAILED after dropping bad rules: \(c.error!)"); exit(1) }
      let data = Data(json.utf8)
      let packed = try! (data as NSData).compressed(using: .lzfse) as Data
      try! packed.write(to: outDir.appendingPathComponent("\(partName).json.lzfse"))
      let compiled = (try? FileManager.default.contentsOfDirectory(at: tmpStore, includingPropertiesForKeys: [.fileSizeKey]))?
        .filter { $0.lastPathComponent.contains(partName) }
        .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +) ?? 0
      print(String(format: "%@: rules=%d exceptions=%d dropped=%d json=%d lzfse=%d compiled=%d compileMs=%.0f",
                   partName, part.count, exceptions.count, dropped, data.count, packed.count, compiled, c.ms))
    }
  }
  try? FileManager.default.removeItem(at: tmpStore)
}
