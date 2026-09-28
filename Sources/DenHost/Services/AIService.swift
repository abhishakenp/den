import CordisValue
import Foundation
import FoundationModels

/// `ai` service: Apple's on-device Foundation Models, for summaries and todos only (no chat, no
/// cloud). The on-device model has a small context window (4,096 tokens, TN3193; read at runtime
/// from `SystemLanguageModel.contextSize`), so long inputs are summarized in chunks (map) and the
/// partial summaries merged (reduce).
///
///   availability                           -> {available, reason?, contextSize}
///   summarize {items: [string], instructions?, id?}
///                                          -> {id}; `ai.result {id, ok, text}`
///   brief {sources: [{name, items: [string]}], instructions?, id?}
///                                          -> {id}; `ai.result {id, ok, text, sources: [{name, text}]}`
///                                             (one summary per source, then one combined brief)
///   todos {items: [{id, text}], max? (8), instructions?, id?}
///                                          -> {id}; `ai.result {id, ok, todos: [{item, title}]}`
///                                             (guided generation; `item` is an input id)
/// Failures: `ai.result {id, ok: false, error, reason?}`; `error: "unavailable"` when Apple
/// Intelligence can't run (callers fall back to plain lists). Requests run one at a time.
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
    case "summarize", "brief", "todos":
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
          case "summarize":
            let text = try await self.summarize(args.list("items").compactMap(\.string), instructions: args.str("instructions", Self.summaryInstructions))
            result = ["ok": true, "text": .string(text)]
          case "brief":
            result = try await self.brief(args.list("sources"), instructions: args.str("instructions", Self.briefInstructions))
          default:
            let todos = try await self.todos(args.list("items"), max: Int(args.num("max", 8)), instructions: args.str("instructions", Self.todoInstructions))
            result = ["ok": true, "todos": .array(todos)]
          }
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

  static let summaryInstructions = "You summarize a person's work notifications. Keep every notification that asks something of the user: never drop one. For each, say who needs what, and where (channel, repo, PR or issue number). Merge only true duplicates. Group pure FYIs into one short line with a count. Be concrete and neutral. Never invent facts."
  static let briefInstructions = "You write a morning briefing from per-source summaries. Cover every item that needs the user, most urgent first, one short sentence per item; then one line counting the FYIs. Mention each item once. Plain text, no lists, no greeting. Never invent facts."
  static let todoInstructions = "You turn one work notification into a todo for the user. Decide whether it needs them to act (reply, review, fix, answer, decide); thanks, FYIs and announcements do not. Write one imperative sentence under 110 characters that names the person, the action and where it lives (channel, repo, PR or issue number), plus any deadline stated. Use only words and facts from the notification; never add details that are not in it."

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
  public func summarize(_ lines: [String], instructions: String) async throws -> String {
    guard !lines.isEmpty else { return "" }
    var parts: [String] = []
    for c in Self.chunk(lines, budget: chunkBudget) { parts += try await summarizeChunk(c, instructions: instructions, depth: 0) }
    var rounds = 0
    while parts.count > 1 && rounds < 6 {
      rounds += 1
      var merged: [String] = []
      for c in Self.chunk(parts, budget: chunkBudget) {
        merged += try await summarizeChunk(c, instructions: instructions + " Merge these partial summaries into one.", depth: 0)
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

  func brief(_ sources: [Value], instructions: String) async throws -> Value {
    var per: [Value] = []
    var lines: [String] = []
    for s in sources {
      let items = s.list("items").compactMap(\.string)
      guard !items.isEmpty else { continue }
      let name = s.str("name")
      let text = try await summarize(items, instructions: Self.summaryInstructions + " These are from \(name). Answer in at most 2 sentences.")
      per.append(["name": .string(name), "text": .string(text)])
      lines.append("\(name): \(text)")
    }
    let text = lines.isEmpty ? "" : try await summarize(lines, instructions: instructions)
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
}

@Generable
struct GeneratedTodo {
  @Guide(description: "True only if the user has to do something: reply, review, fix, decide or answer. False for thanks, FYIs and announcements.")
  var actionable: Bool
  @Guide(description: "One imperative sentence under 110 characters naming the person, the action and where it lives (channel, repo, PR or issue number)")
  var title: String
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

}
