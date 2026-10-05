// Summarize: an example third-party den plugin. "Summarize This Page" (command bar, or ⌃⇧S) reads
// the page you're on and asks Apple's on-device model for a short summary, shown in a dialog.
//
// Install: copy this folder to ~/.den/plugins/summarize/. den compiles it, asks you to allow what
// plugin.json declares (tabs, pages:*, ai), and runs it in its own sandboxed process.
// Everything below goes through den's host services; the plugin can't touch files or the network.
//
// The API it uses (docs/host-api.md):
//   commands.register / commands.run    a command bar entry, and the event when it's picked
//   keys.bind                           a shortcut that emits our own event
//   tabs.selected                       the tab in front (its id is its web view's id)
//   webviews.inject                     run a script in that page (needs pages:<site>), result on webviews.injectResult
//   ai.availability / ai.respond        the on-device model (needs ai), result on ai.result
//   ui.set {slot: toast|dialog}         progress and the result
//
// Every id this plugin uses starts with "summarize." (den only lets it use its own names).

nonisolated(unsafe) var pending = ""  // the request we're waiting for ("" = idle)
nonisolated(unsafe) var pageTitle = ""
nonisolated(unsafe) var serial: Int64 = 0
nonisolated(unsafe) var registerTries = 0

let commandID = "summarize.page"
let instructions = """
  You summarize web pages for the person reading them. Answer with 3 to 5 short bullet points \
  ("• "), plain text, no introduction. Keep names, numbers and dates exact.
  """

func toast(_ ctx: Context, _ text: String, ms: Int64 = 0) {
  _ = ctx.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "id": "summarize.toast", "text": .string(text), "icon": "sf:sparkles", "duration": .int(ms)]])
}

func dismissToast(_ ctx: Context) {
  _ = ctx.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "id": "summarize.toast", "dismiss": true]])
}

func show(_ ctx: Context, title: String, message: String, icon: String = "sf:sparkles") {
  dismissToast(ctx)
  _ = ctx.call("ui", "set", [
    "slot": "dialog",
    "tree": [
      "type": "dialog", "id": "summarize.result", "icon": .string(icon), "title": .string(title), "message": .string(message),
      "buttons": [["id": "done", "title": "Done", "style": "default"]],
    ],
  ])
}

func nextID(_ kind: String) -> String {
  serial += 1
  return "summarize." + kind + "." + String(serial)
}

/// Step 1: find the page in front and read its text.
func start(_ ctx: Context) {
  guard pending.isEmpty else { return }
  let model = ctx.call("ai", "availability")
  if model["available"].bool != true {
    show(ctx, title: "Summaries need Apple Intelligence", message: "Turn on Apple Intelligence in System Settings to summarize pages on this Mac.", icon: "sf:exclamationmark.triangle.fill")
    return
  }
  guard let tab = ctx.call("tabs", "selected")["id"].string, !tab.isEmpty else {
    show(ctx, title: "No page to summarize", message: "Open a page first.", icon: "sf:doc.questionmark")
    return
  }
  pending = nextID("read")
  toast(ctx, "Reading the page…")
  let r = ctx.call("webviews", "inject", [
    "id": .string(tab), "plugin": "summarize", "request": .string(pending),
    "script": "return {title: document.title, text: (document.body ? document.body.innerText : '').slice(0, 20000)}",
  ])
  if let error = r["error"].string {
    pending = ""
    show(ctx, title: "Can't read this page", message: error, icon: "sf:exclamationmark.triangle.fill")
  }
}

/// Step 2: the page's text arrived; ask the model.
func read(_ ctx: Context, _ v: Value) {
  guard v["ok"].bool == true else {
    pending = ""
    show(ctx, title: "Can't read this page", message: v["error"].string ?? "The page didn't answer.", icon: "sf:exclamationmark.triangle.fill")
    return
  }
  pageTitle = v["value"]["title"].string ?? ""
  var text = v["value"]["text"].string ?? ""
  if text.isEmpty {
    pending = ""
    show(ctx, title: "Nothing to summarize", message: "This page has no text.", icon: "sf:doc.questionmark")
    return
  }
  // About 3 characters per token; leave room for the instructions and the answer.
  let context = ctx.call("ai", "availability")["contextSize"].int ?? 4096
  let budget = Int(max(1000, (context - 1400) * 3))
  if text.utf8.count > budget { text = String(text.prefix(budget)) }
  pending = nextID("ai")
  toast(ctx, "Summarizing…")
  _ = ctx.call("ai", "respond", ["id": .string(pending), "instructions": .string(instructions), "prompt": .string(pageTitle + "\n\n" + text)])
}

/// Step 3: the summary.
func answered(_ ctx: Context, _ v: Value) {
  pending = ""
  if v["ok"].bool == true, let text = v["text"].string {
    show(ctx, title: pageTitle.isEmpty ? "Summary" : pageTitle, message: text)
  } else {
    show(ctx, title: "Couldn't summarize this page", message: v["reason"].string ?? v["error"].string ?? "The model didn't answer.", icon: "sf:exclamationmark.triangle.fill")
  }
}

/// The command bar may load after us: retry the registration for a few seconds.
func register(_ ctx: Context) {
  let r = ctx.call("commands", "register", ["id": .string(commandID), "title": "Summarize This Page", "icon": "sf:sparkles", "keywords": "summary tldr ai", "shortcut": "⌃⇧S", "owner": "summarize"])
  if r["error"].string != nil, registerTries < 20 {
    registerTries += 1
    ctx.timer(milliseconds: 500) { register(ctx) }
  }
}

struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Summarize", version: "1.0.0", inject: ["ui"], provides: ["summarize"])

  static func apply(_ ctx: Context) throws(PluginError) {
    pending = ""
    registerTries = 0
    register(ctx)
    _ = ctx.call("keys", "bind", ["chord": "ctrl+shift+s", "event": .string(commandID), "title": "Summarize This Page"])
    ctx.on(commandID) { _ in start(ctx) }
    ctx.on("commands.run") { v in if v["id"].string == commandID { start(ctx) } }
    ctx.on("webviews.injectResult") { v in if !pending.isEmpty, v["request"].string == pending { read(ctx, v) } }
    ctx.on("ai.result") { v in if !pending.isEmpty, v["id"].string == pending { answered(ctx, v) } }
    ctx.on("ui.action") { v in
      if v["id"].string == "summarize.result" { _ = ctx.call("ui", "set", ["slot": "dialog", "tree": .null]) }
    }
    // A service, so other plugins (or a test) can start it and see what it's doing.
    ctx.provide("summarize") { method, _ in
      switch method {
      case "run":
        start(ctx)
        return ["pending": .string(pending)]
      case "state": return ["pending": .string(pending), "title": .string(pageTitle)]
      default: return ["error": .string("summarize: unknown method " + method)]
      }
    }
  }

  static func dispose() {
    pending = ""
    pageTitle = ""
  }
}
