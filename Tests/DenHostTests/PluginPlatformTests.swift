import AppKit
import Cordis
import CordisValue
import DenTestSupport
import Foundation
import Testing

@testable import DenHost

/// The plugin platform with real Embedded Swift plugins (built here with cordis-build):
/// crash recovery and its UI, third-party plugins in a sandboxed helper behind Allow / Don't Allow,
/// the per-plugin gate, and the Summarize example end to end with a fake model.
@MainActor
@Suite(.serialized, .watchdog)
struct PluginPlatformTests {
  nonisolated static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// cordis-build from the resolved package (or $DEN_CORDIS_BUILD), if a toolchain can run it.
  nonisolated static let compiler: SourceCompiler? = {
    let env = ProcessInfo.processInfo.environment["DEN_CORDIS_BUILD"].map { URL(fileURLWithPath: $0) }
    let script = env ?? repo.appendingPathComponent(".build/checkouts/cordis-swift/Scripts/cordis-build")
    guard FileManager.default.isExecutableFile(atPath: script.path), SourceCompiler.findToolchain() != nil else { return nil }
    return SourceCompiler(script: script, shared: [])
  }()

  nonisolated static func build(_ id: String, _ sources: [String]) -> URL? {
    guard let compiler else { return nil }
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("den-pp-\(UUID().uuidString)/\(id).dylib")
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    let (ok, output) = compiler.run(id: id, out: out, sources: sources.map { repo.appendingPathComponent($0) })
    if !ok { print("\(id) build failed:\n\(output)") }
    return ok ? out : nil
  }

  nonisolated static let crashy = build("crashy", ["Tests/Fixtures/plugins/crashy/Crashy.swift"])
  nonisolated static let outsider = build("outsider", ["Tests/Fixtures/plugins/outsider/Outsider.swift"])
  nonisolated static let summarize = build("summarize", ["examples/summarize/Summarize.swift"])

  func until(_ seconds: Double = 10, line: UInt = #line, _ cond: () -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: seconds, line: line) { cond() }
  }

  func runtime() -> DenRuntime {
    _ = NSApplication.shared
    return DenRuntime(storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("den-pp-\(UUID())"))
  }

  /// A folder holding `dylib` (and `sidecar` as its `<id>.json`).
  func folder(_ dylib: URL, sidecar: String? = nil) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-pp-dir-\(UUID())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let id = dylib.deletingPathExtension().lastPathComponent
    try? FileManager.default.copyItem(at: dylib, to: dir.appendingPathComponent("\(id).dylib"))
    if let sidecar { try? Data(sidecar.utf8).write(to: dir.appendingPathComponent("\(id).json")) }
    return dir.appendingPathComponent("\(id).dylib")
  }

  /// den's own UI pressing a dialog button (the consent sheet).
  func press(_ rt: DenRuntime, _ button: String, choices: [String]? = nil) {
    let id = rt.ui.dialog.node.str("id")
    var value: Value = ["button": .string(button), "checked": false]
    if let choices { value = value.with("choices", .array(choices.map { .string($0) })) }
    rt.plugins.emit("ui.action", ["id": .string(id), "action": "button", "value": value])
  }

  // MARK: - Crash recovery

  @Test func aCrashingPluginIsUnloadedTheUserToldAndDenKeepsRunning() async throws {
    guard let dylib = Self.crashy else { return }  // no Embedded Swift toolchain here
    let rt = runtime()
    let file = folder(dylib)
    let loader = PluginLoader(plugins: rt.plugins)
    loader.load(file, watch: false)
    #expect(rt.plugins.plugin("crashy")?.state == .active)
    #expect(rt.plugins.isolation(of: "crashy") == .inProcess)  // a first-party location
    // A tab's page lives in the host; it must survive the plugin.
    _ = rt.call("webviews", "create", ["id": "tab-1", "url": "about:blank"])

    let r = rt.call("crashy", "trap")
    #expect(r["error"].string?.hasPrefix("plugin 'crashy' crashed (SIGTRAP)") == true, "\(r)")
    guard case .disabled = rt.plugins.plugin("crashy")?.state else {
      Issue.record("crashy should be disabled")
      return
    }
    #expect(rt.crashes.crashes["crashy"]?.signal == SIGTRAP)
    // Told once: a toast with Reload and Disable.
    let toast = try #require(rt.ui.toasts.last)
    #expect(toast.label.stringValue == "The “Crashy” plugin stopped working")
    #expect(toast.actionIDs == ["reload", "disable"])
    #expect(toast.buttonLabels.map(\.stringValue) == ["Reload", "Disable"])
    // den keeps running: its services answer, the page is still there.
    #expect(rt.call("webviews", "list").array?.contains("tab-1") == true)
    _ = rt.call("storage", "set", ["ns": "t", "key": "k", "value": 1])
    #expect(rt.call("storage", "get", ["ns": "t", "key": "k"]) == 1)
    // A plugin can't press den's buttons (a fake click carries its caller).
    // Reload, from the toast.
    rt.plugins.emit("ui.action", ["id": "_plugins.crash:crashy", "action": "toast", "value": ["button": "reload"]])
    #expect(rt.plugins.plugin("crashy")?.state == .active)
    #expect(rt.call("crashy", "ok") == "fine")

    // A crash in an event listener, then Disable.
    rt.plugins.emit("crashy.boom")
    #expect(await until { rt.crashes.crashes["crashy"] != nil && rt.plugins.plugin("crashy")?.state != .active })
    rt.plugins.emit("ui.action", ["id": "_plugins.crash:crashy", "action": "toast", "value": ["button": "disable"]])
    #expect(rt.consent.disabled.contains("crashy"))
    loader.load(file, watch: false)
    #expect(rt.plugins.plugin("crashy")?.state != .active)
    // Settings ▸ Plugins lists it with Reload.
    let items = PluginSettings.controls(rt).first?.list("items") ?? []
    #expect(items.contains { $0.str("id") == "crashy" })
    rt.consent.setDisabled("crashy", false)
    #expect(rt.plugins.plugin("crashy")?.state == .active)
  }

  // MARK: - Third-party plugins

  static let outsiderSidecar = #"{"permissions": ["ai", "net:example.com", "bogus:thing"]}"#

  @Test func aThirdPartyPluginAsksFirstAndRunsInASandboxedHelper() async throws {
    guard let dylib = Self.outsider else { return }
    let rt = runtime()
    let file = folder(dylib, sidecar: Self.outsiderSidecar)
    rt.consent.thirdPartyDirectories = [file.deletingLastPathComponent()]
    let loader = PluginLoader(plugins: rt.plugins)

    // First load: nothing loads, the sheet lists what it declared (valid ones only), all ticked.
    loader.load(file, watch: false)
    #expect(loader.outcome.waiting == ["outsider"])
    #expect(rt.plugins.plugin("outsider") == nil)
    #expect(rt.ui.dialogOpen)
    let sheet = rt.ui.dialog.node
    #expect(sheet.str("title") == "Allow the “outsider” plugin?")
    #expect(sheet.list("choices").map { $0.str("id") } == ["ai", "net:example.com"])
    #expect(sheet.list("choices").allSatisfy { $0.flag("selected") })

    // Allow, with net unticked: it loads in a helper process with just `ai`.
    press(rt, "allow", choices: ["ai"])
    #expect(await until { rt.plugins.plugin("outsider")?.state == .active })
    let info = try #require(rt.plugins.plugin("outsider"))
    #expect(info.isolation == .process(sandbox: true))
    let pid = try #require(info.helperPID)
    #expect(pid != getpid())
    #expect(rt.permissions.list("outsider") == ["ai"])
    #expect(rt.consent.grant("outsider") == .init(declared: ["ai", "net:example.com"], granted: ["ai"], denied: false))

    // Remembered: the next load doesn't ask.
    try rt.plugins.unload("outsider")
    loader.load(file, watch: false)
    #expect(rt.plugins.plugin("outsider")?.state == .active)
    #expect(!rt.ui.dialogOpen)

    // Revoke (Settings ▸ Plugins): unloaded, and it asks again; Don't Allow is remembered too.
    rt.consent.revoke("outsider")
    #expect(rt.plugins.plugin("outsider") == nil)
    loader.load(file, watch: false)
    #expect(rt.ui.dialogOpen)
    press(rt, "deny")
    #expect(rt.plugins.plugin("outsider") == nil)
    loader.load(file, watch: false)
    #expect(!rt.ui.dialogOpen)
    #expect(loader.outcome.failed[file.path] == "you didn't allow it")
    #expect(PluginSettings.controls(rt).first?.list("items").first?.str("subtitle").hasPrefix("Not allowed") == true)
  }

  @Test func aThirdPartyPluginGetsOnlyWhatItWasAllowed() async throws {
    guard let dylib = Self.outsider else { return }
    let rt = runtime()
    let fake = FakeModel()
    rt.ai.generator = fake
    let file = folder(dylib, sidecar: Self.outsiderSidecar)
    rt.consent.thirdPartyDirectories = [file.deletingLastPathComponent()]
    rt.consent.decide("outsider", .init(declared: ["ai", "net:example.com"], granted: ["ai"], denied: false))
    PluginLoader(plugins: rt.plugins).load(file, watch: false)
    #expect(rt.plugins.plugin("outsider")?.state == .active)
    func attempt(_ service: String, _ method: String, _ args: Value = .null) -> Value {
      rt.call("outsider", "try", ["service": .string(service), "method": .string(method), "args": args])
    }
    func denied(_ v: Value) -> Bool { v["error"].string?.contains("permission denied") == true || v["error"].string?.contains("has no") == true }

    // Its own storage namespace, yes; another plugin's, no.
    #expect(attempt("storage", "set", ["ns": "outsider", "key": "a", "value": 1])["error"].isNull)
    #expect(attempt("storage", "get", ["ns": "outsider", "key": "a"]) == 1)
    #expect(denied(attempt("storage", "get", ["ns": "tabs", "key": "state"])))
    // Granted: the model. Declared but not allowed: the network. Never declared: everything else.
    #expect(attempt("ai", "availability")["available"].bool == true)
    #expect(denied(attempt("net", "fetch", ["url": "https://example.com/"])))
    #expect(denied(attempt("tabs", "list")))
    #expect(denied(attempt("webviews", "list")))
    #expect(denied(attempt("webviews", "navigate", ["id": "tab-1", "url": "https://example.com"])))
    #expect(denied(attempt("vault", "list")))
    #expect(denied(attempt("app", "copy", ["text": "x"])))
    #expect(denied(attempt("session", "cookies", ["domain": "example.com"])))
    // Claiming to be another plugin doesn't help: `plugin` is replaced by the real caller.
    #expect(denied(attempt("net", "fetch", ["url": "https://slack.com/api", "plugin": "slack", "session": true])))
    // Its own web views are fine without `tabs`.
    #expect(attempt("webviews", "create", ["id": "outsider.panel"])["error"].isNull)
    // Commands: only its own ids.
    rt.plugins.provide("commands") { _, _ in ["ok": true] }
    #expect(attempt("commands", "register", ["id": "outsider.go", "title": "Go"])["ok"] == true)
    #expect(denied(attempt("commands", "run", ["id": "den.quit"])))

    // Emits: only its own events.
    var heard: [String] = []
    rt.plugins.on("outsider.hello") { _ in heard.append("outsider.hello") }
    rt.plugins.on("tabs.selected") { _ in heard.append("tabs.selected") }
    _ = rt.call("outsider", "emit", ["event": "outsider.hello"])
    _ = rt.call("outsider", "emit", ["event": "tabs.selected", "payload": ["id": "x"]])
    #expect(heard == ["outsider.hello"])
    // Listens: browsing events need `tabs`.
    #expect(rt.call("outsider", "listen", ["event": "webviews.url"]) == 0)
    #expect(rt.call("outsider", "listen", ["event": "outsider.ping"]) != 0)

    // Results and id'd events: only its own.
    rt.plugins.emit("ai.result", ["id": "briefing.1", "ok": true, "text": "someone else's"])
    rt.plugins.emit("ui.action", ["id": "tab-1", "action": "click"])
    rt.plugins.emit("ui.action", ["id": "outsider.button", "action": "click"])
    let asked = attempt("ai", "respond", ["id": "outsider.q1", "instructions": "i", "prompt": "p"])
    #expect(asked["id"] == "outsider.q1", "\(asked)")
    #expect(await until {
      (rt.call("outsider", "heard").array ?? []).contains { $0["event"] == "ai.result" }
    })
    try? await Task.sleep(for: .milliseconds(300))
    let got = rt.call("outsider", "heard").array ?? []
    #expect(got.filter { $0["event"] == "ai.result" }.map { $0["payload"]["id"] } == ["outsider.q1"])
    #expect(got.filter { $0["event"] == "ui.action" }.map { $0["payload"]["id"] } == ["outsider.button"])

    // The sandbox: no files of its own.
    #expect(rt.call("outsider", "touch") == -1)
  }

  // MARK: - The example

  @Test func theSummarizeExampleSummarizesThePageInFront() async throws {
    guard let dylib = Self.summarize else { return }
    let rt = runtime()
    let fake = FakeModel()
    fake.answer = "• den runs plugins in their own sandbox"
    rt.ai.generator = fake
    // The page in front, and what reading it returns (no web page needed).
    rt.plugins.dispose(rt.serviceHandles["webviews"]!)
    var injected: [Value] = []
    rt.provideService("webviews") { [weak rt] method, args in
      guard method == "inject" else { return .null }
      injected.append(args)
      let request = args.str("request")
      DispatchQueue.main.async {
        rt?.plugins.emit("webviews.injectResult", ["request": .string(request), "webview": "tab-1", "plugin": "summarize", "ok": true,
                                                   "value": ["title": "den", "text": "den is a browser. Every feature is a plugin."]])
      }
      return ["request": .string(request)]
    }
    rt.provideService("tabs") { m, _ in m == "selected" ? ["id": "tab-1"] : .null }
    var commands: [String: Value] = [:]
    rt.plugins.provide("commands") { m, a in
      if m == "register" { commands[a.str("id")] = a }
      return ["ok": true]
    }
    let file = folder(dylib, sidecar: try String(contentsOf: Self.repo.appendingPathComponent("examples/summarize/plugin.json"), encoding: .utf8))
    rt.consent.thirdPartyDirectories = [file.deletingLastPathComponent()]
    PluginLoader(plugins: rt.plugins).load(file, watch: false)
    #expect(rt.ui.dialog.node.list("choices").map { $0.str("id") } == ["tabs", "pages:*", "ai"])
    press(rt, "allow")
    #expect(await until { rt.plugins.plugin("summarize")?.state == .active })
    #expect(rt.plugins.isolation(of: "summarize") == .process(sandbox: true))
    #expect(commands["summarize.page"]?.str("title") == "Summarize This Page")
    #expect(rt.call("keys", "list").array?.contains { $0.str("chord") == "ctrl+shift+s" } == true)

    // The command bar runs the command.
    rt.plugins.emit("commands.run", ["id": "summarize.page"])
    #expect(await until(20) { rt.ui.dialogOpen && rt.ui.dialog.node.str("id") == "summarize.result" })
    #expect(rt.ui.dialog.node.str("message") == "• den runs plugins in their own sandbox")
    #expect(rt.ui.dialog.node.str("title") == "den")
    #expect(injected.first?.str("plugin") == "summarize")
    #expect(fake.prompts.first?.contains("Every feature is a plugin.") == true)
    // Done closes it.
    rt.plugins.emit("ui.action", ["id": "summarize.result", "action": "button", "value": ["button": "done"]])
    #expect(await until { !rt.ui.dialogOpen })
  }
}

/// A model that answers at once.
@MainActor
final class FakeModel: AIGenerator {
  var answer = "summary"
  var prompts: [String] = []
  func availability() -> (available: Bool, reason: String?) { (true, nil) }
  var contextSize: Int { 4096 }
  func respond(instructions: String, prompt: String) async throws -> String {
    prompts.append(prompt)
    return answer
  }
  func todo(instructions: String, text: String) async throws -> (actionable: Bool, title: String) { (false, "") }
  func group(instructions: String, prompt: String) async throws -> [(name: String, items: [Int])] { [] }
}
