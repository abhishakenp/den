import CordisValue
import Foundation
import FoundationModels

/// `ai` service: Apple's on-device Foundation Models, for summaries and todos only (no chat, no
/// cloud). The on-device model has a small context window (4,096 tokens, TN3193; read at runtime
/// from `SystemLanguageModel.contextSize`), so long inputs are summarized in chunks (map) and the
/// partial summaries merged (reduce).
///
/// Every prompt is the caller's (docs/architecture/thin-host.md: the host holds no feature
/// policy): `instructions` is required, and the host adds no words of its own.
///
///   availability                           -> {available, reason?, contextSize}
///   respond {instructions, prompt, id?}    -> {id}; `ai.result {id, ok, text}`
///                                             (one plain request: the prompt must fit the context;
///                                             if it doesn't, `ok: false, reason: "contextOverflow"`)
///   summarize {items: [string], instructions, merge?, id?}
///                                          -> {id}; `ai.result {id, ok, text}`. `merge` is appended
///                                             to `instructions` when partial summaries are merged
///   brief {sources: [{name, items: [string]}], instructions, sourceInstructions, merge?, id?}
///                                          -> {id}; `ai.result {id, ok, text, sources: [{name, text}]}`
///                                             (one summary per source with `sourceInstructions`, where
///                                             `{name}` is the source's name, then one combined brief)
///   todos {items: [{id, text}], max? (8), instructions, id?}
///                                          -> {id}; `ai.result {id, ok, todos: [{item, title}]}`
///                                             (guided generation; `item` is an input id)
///   group {items: [{id, text}], instructions, maxGroups? (6), id?}
///                                          -> {id}; `ai.result {id, ok, groups: [{name, items: [id]}]}`
///                                             (guided generation: named groups of input ids; each id in
///                                             at most one group, empty groups dropped; items past the
///                                             context budget are left out, `skipped` counts them)
/// Failures: `ai.result {id, ok: false, error, reason?}`; `error: "unavailable"` when Apple
/// Intelligence can't run (callers fall back to plain lists). Requests run one at a time.
///
/// Model lifetime: den holds no model and no session between requests. Each request makes its own
/// `LanguageModelSession` and drops it when it answers, and nothing here runs at launch
/// (availability is read only when a caller asks). The model itself runs in macOS's
/// `TGOnDeviceInferenceProviderService`, which loads it for the request and lets it go on its own
/// a few minutes later. Measured on this project's dev Mac (macOS 26.5, `top -l 1 -stats pid,mem`
/// on the service, `task_info` phys_footprint for the caller): the service's two processes went
/// from 160 MB + 86 MB to 336 MB + 242 MB during a 13 s summary, 179 MB + 105 MB from 5 s to 120 s
/// after, and back to 160 MB + 86 MB by 180 s. The calling process gains about 5 MB once
/// (FoundationModels' client state, on the first request) and stays flat after that
/// (1.8 → 6.8 → 7.5 → 7.5 → 7.6 MB over four requests). See docs/host-api.md#ai.
@MainActor
public final class AIService: HostService {
  public let name = "ai"
  let host: ServiceHost
  public var generator: AIGenerator
  private var nextId = 1
  private var tail: Task<Void, Never>?
  public private(set) var busy = 0
  /// Latin text runs about 3–4 characters per token (TN3193); 3 keeps chunks safely inside.
  public var charsPerToken = 3
  /// Tokens kept free for instructions, the schema and the answer.
  public var reservedTokens = 1200

  public init(host: ServiceHost, generator: AIGenerator = FoundationModelsGenerator()) {
    self.host = host
    self.generator = generator
  }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "availability":
      let a = generator.availability()
      var v: Value = ["available": .bool(a.available), "contextSize": .int(Int64(generator.contextSize))]
      if let r = a.reason { v = v.with("reason", .string(r)) }
      return v
    case "summarize", "brief", "todos", "group", "respond":
      guard !args.str("instructions").isEmpty, method != "brief" || !args.str("sourceInstructions").isEmpty else {
        return .error("ai: \(method) needs instructions\(method == "brief" ? " and sourceInstructions" : "")")
      }
      var id = args.str("id")
      if id.isEmpty { id = "ai-\(nextId)"; nextId += 1 }
      enqueue(id: id, method: method, args: args)
      return ["id": .string(id)]
    default:
      return .error("ai: unknown method '\(method)'")
    }
  }

  func enqueue(id: String, method: String, args: Value) {
    let previous = tail
    busy += 1
    tail = Task { @MainActor [weak self] in
      await previous?.value
      guard let self else { return }
      let t0 = Date()
      var result: Value
      let a = self.generator.availability()
      if !a.available {
        result = ["ok": false, "error": "unavailable", "reason": .string(a.reason ?? "unknown")]
      } else {
        do {
          switch method {
          case "respond":
            let text = try await self.generator.respond(instructions: args.str("instructions"), prompt: args.str("prompt"))
            result = ["ok": true, "text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines))]
          case "summarize":
            let text = try await self.summarize(args.list("items").compactMap(\.string), instructions: args.str("instructions"), merge: args.str("merge"))
            result = ["ok": true, "text": .string(text)]
          case "brief":
            result = try await self.brief(args.list("sources"), instructions: args.str("instructions"),
                                          sourceInstructions: args.str("sourceInstructions"), merge: args.str("merge"))
          case "group":
            result = try await self.group(args.list("items"), instructions: args.str("instructions"),
                                          maxGroups: Int(args.num("maxGroups", 6)))
          default:
            let todos = try await self.todos(args.list("items"), max: Int(args.num("max", 8)), instructions: args.str("instructions"))
            result = ["ok": true, "todos": .array(todos)]
          }
        } catch AIError.contextOverflow {
          result = ["ok": false, "error": .string("ai: \(AIError.contextOverflow)"), "reason": "contextOverflow"]
        } catch {
          result = ["ok": false, "error": .string("ai: \(error)")]
        }
      }
      result = result.with("id", .string(id)).with("ms", .int(Int64(Date().timeIntervalSince(t0) * 1000)))
      self.busy -= 1
      self.host.emit("ai.result", result)
    }
  }

  // MARK: Map-reduce

  /// Characters of input that fit in one request.
  public var chunkBudget: Int { max(800, (generator.contextSize - reservedTokens) * charsPerToken) }

  /// Splits lines into chunks under `budget` characters; a single overlong line is truncated.
  nonisolated static func chunk(_ lines: [String], budget: Int) -> [[String]] {
    var out: [[String]] = []
    var cur: [String] = []
    var size = 0
    for raw in lines {
      let line = raw.count > budget / 2 ? String(raw.prefix(budget / 2)) + "…" : raw
      if size + line.count + 1 > budget, !cur.isEmpty {
        out.append(cur)
        cur = []
        size = 0
      }
      cur.append(line)
      size += line.count + 1
    }
    if !cur.isEmpty { out.append(cur) }
    return out
  }

  /// Summarizes any number of lines: each chunk is summarized, then partial summaries are merged
  /// until one remains. A chunk that still overflows the context is split in half and retried.
  public func summarize(_ lines: [String], instructions: String, merge: String = "") async throws -> String {
    guard !lines.isEmpty else { return "" }
    var parts: [String] = []
    for c in Self.chunk(lines, budget: chunkBudget) { parts += try await summarizeChunk(c, instructions: instructions, depth: 0) }
    var rounds = 0
    while parts.count > 1 && rounds < 6 {
      rounds += 1
      var merged: [String] = []
      for c in Self.chunk(parts, budget: chunkBudget) {
        merged += try await summarizeChunk(c, instructions: merge.isEmpty ? instructions : instructions + " " + merge, depth: 0)
      }
      parts = merged
    }
    return parts.first ?? ""
  }

  func summarizeChunk(_ lines: [String], instructions: String, depth: Int) async throws -> [String] {
    do {
      let text = try await generator.respond(instructions: instructions, prompt: lines.map { "- " + $0 }.joined(separator: "\n"))
      return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
    } catch AIError.contextOverflow where lines.count > 1 && depth < 4 {
      let half = lines.count / 2
      return try await summarizeChunk(Array(lines[..<half]), instructions: instructions, depth: depth + 1)
        + summarizeChunk(Array(lines[half...]), instructions: instructions, depth: depth + 1)
    }
  }

  func brief(_ sources: [Value], instructions: String, sourceInstructions: String, merge: String) async throws -> Value {
    var per: [Value] = []
    var lines: [String] = []
    for s in sources {
      let items = s.list("items").compactMap(\.string)
      guard !items.isEmpty else { continue }
      let name = s.str("name")
      let text = try await summarize(items, instructions: sourceInstructions.replacingOccurrences(of: "{name}", with: name), merge: merge)
      per.append(["name": .string(name), "text": .string(text)])
      lines.append("\(name): \(text)")
    }
    let text = lines.isEmpty ? "" : try await summarize(lines, instructions: instructions, merge: merge)
    return ["ok": true, "text": .string(text), "sources": .array(per)]
  }

  /// One guided generation per item: the model sees a single notification, so a todo can never
  /// be attached to the wrong item (with numbered lists the small model misnumbers). It also
  /// decides whether the item needs the user at all ("thanks for the review!" doesn't).
  func todos(_ items: [Value], max: Int, instructions: String) async throws -> [Value] {
    var out: [Value] = []
    var seen = Set<String>()
    for v in items {
      let text = v.str("text"), id = v.str("id")
      guard !text.isEmpty, seen.insert(id).inserted else { continue }
      let t = try await generator.todo(instructions: instructions, text: String(text.prefix(chunkBudget)))
      let title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard t.actionable, !title.isEmpty else { continue }
      out.append(["item": .string(id), "title": .string(title)])
      if out.count >= max { break }
    }
    return out
  }
}

extension AIService {
  /// One guided generation over a numbered list ("1. text"): the model answers with item numbers,
  /// which map back to the caller's ids. Numbers out of range, repeats and empty groups are
  /// dropped here, so callers only see valid, disjoint groups. Items that don't fit the context
  /// budget are left out (lines are cut to 120 characters first).
  func group(_ items: [Value], instructions: String, maxGroups: Int) async throws -> Value {
    var ids: [String] = []
    var lines: [String] = []
    var size = 0, skipped = 0
    for v in items {
      let id = v.str("id"), text = v.str("text")
      guard !id.isEmpty, !ids.contains(id) else { continue }
      let line = "\(ids.count + 1). " + String(text.prefix(120))
      if size + line.count + 1 > chunkBudget { skipped += 1; continue }
      ids.append(id)
      lines.append(line)
      size += line.count + 1
    }
    guard ids.count >= 2 else { return ["ok": true, "groups": [], "skipped": .int(Int64(skipped))] }
    let raw = try await generator.group(instructions: instructions, prompt: lines.joined(separator: "\n"))
    var used = Set<Int>()
    var out: [Value] = []
    for g in raw where out.count < max(1, maxGroups) {
      let name = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
      var members: [Value] = []
      for n in g.items where n >= 1 && n <= ids.count && used.insert(n).inserted { members.append(.string(ids[n - 1])) }
      guard !name.isEmpty, !members.isEmpty else { continue }
      out.append(["name": .string(name), "items": .array(members)])
    }
    return ["ok": true, "groups": .array(out), "skipped": .int(Int64(skipped))]
  }
}

// MARK: - Generator

public enum AIError: Error, CustomStringConvertible {
  case contextOverflow
  case failed(String)
  public var description: String {
    switch self {
    case .contextOverflow: return "exceeded the context window"
    case let .failed(s): return s
    }
  }
}

/// The model behind `ai`. Tests swap in a fake; the app uses Foundation Models.
@MainActor
public protocol AIGenerator {
  func availability() -> (available: Bool, reason: String?)
  var contextSize: Int { get }
  func respond(instructions: String, prompt: String) async throws -> String
  func todo(instructions: String, text: String) async throws -> (actionable: Bool, title: String)
  /// Named groups of 1-based item numbers from a numbered list.
  func group(instructions: String, prompt: String) async throws -> [(name: String, items: [Int])]
}

@MainActor
extension AIGenerator {
  /// Plain-text fallback for generators without guided generation: one "Name: 1, 2, 3" line per group.
  public func group(instructions: String, prompt: String) async throws -> [(name: String, items: [Int])] {
    let text = try await respond(instructions: instructions + " Answer with one line per group: the name, a colon, then the item numbers separated by commas.",
                                 prompt: prompt)
    return AIService.parseGroups(text)
  }
}

extension AIService {
  /// "Name: 1, 2, 3" lines -> groups (lines without a colon or numbers are skipped).
  nonisolated static func parseGroups(_ text: String) -> [(name: String, items: [Int])] {
    var out: [(name: String, items: [Int])] = []
    for line in text.split(whereSeparator: \.isNewline) {
      guard let colon = line.lastIndex(of: ":") else { continue }
      var name = line[..<colon].trimmingCharacters(in: .whitespaces)
      // List markers: "- ", "* ", "• ", "# ", "1. ", "2) ".
      while let f = name.first, "-*•#".contains(f) { name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces) }
      let digits = name.prefix { $0.isNumber }
      if !digits.isEmpty, let m = name.dropFirst(digits.count).first, m == "." || m == ")" {
        name = String(name.dropFirst(digits.count + 1)).trimmingCharacters(in: .whitespaces)
      }
      name = name.trimmingCharacters(in: CharacterSet(charactersIn: "*\"'“”"))
      let nums = line[line.index(after: colon)...].split { !$0.isNumber }.compactMap { Int($0) }
      if !name.isEmpty && !nums.isEmpty { out.append((name, nums)) }
    }
    return out
  }
}

@Generable
struct GeneratedTodo {
  @Guide(description: "True only if the user has to do something: reply, review, fix, decide or answer. False for thanks, FYIs and announcements.")
  var actionable: Bool
  @Guide(description: "One imperative sentence under 110 characters naming the person, the action and where it lives (channel, repo, PR or issue number)")
  var title: String
}

@Generable
struct GeneratedGroups {
  @Guide(description: "Groups of related items")
  var groups: [GeneratedGroup]
}

@Generable
struct GeneratedGroup {
  @Guide(description: "A short, specific name for the group, one to three words in Title Case")
  var name: String
  @Guide(description: "The numbers of the items in this group")
  var items: [Int]
}

@MainActor
public struct FoundationModelsGenerator: AIGenerator {
  public init() {}

  public func availability() -> (available: Bool, reason: String?) {
    switch SystemLanguageModel.default.availability {
    case .available: return (true, nil)
    case let .unavailable(r):
      switch r {
      case .deviceNotEligible: return (false, "deviceNotEligible")
      case .appleIntelligenceNotEnabled: return (false, "appleIntelligenceNotEnabled")
      case .modelNotReady: return (false, "modelNotReady")
      @unknown default: return (false, "unavailable")
      }
    }
  }

  public var contextSize: Int { SystemLanguageModel.default.contextSize }

  static func map(_ error: Error) -> Error {
    if let g = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = g { return AIError.contextOverflow }
    return AIError.failed(String(describing: error))
  }

  public func respond(instructions: String, prompt: String) async throws -> String {
    do {
      let session = LanguageModelSession(instructions: instructions)
      return try await session.respond(to: prompt).content
    } catch { throw Self.map(error) }
  }

  public func todo(instructions: String, text: String) async throws -> (actionable: Bool, title: String) {
    do {
      let session = LanguageModelSession(instructions: instructions)
      let r = try await session.respond(to: text, generating: GeneratedTodo.self)
      return (r.content.actionable, r.content.title)
    } catch { throw Self.map(error) }
  }

  public func group(instructions: String, prompt: String) async throws -> [(name: String, items: [Int])] {
    do {
      let session = LanguageModelSession(instructions: instructions)
      let r = try await session.respond(to: prompt, generating: GeneratedGroups.self)
      return r.content.groups.map { ($0.name, $0.items) }
    } catch { throw Self.map(error) }
  }

}
