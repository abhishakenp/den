import AppKit
import CordisValue

extension HostScenarios {
  /// `commandBar:<query>`: opens the Command Bar (the `commands` plugin) with `<query>` typed, or
  /// empty (Cmd-T) for `commandBar:`. Web suggestions come from the live `suggest` service.
  /// Needs the plugins, so run it on a fresh `--storage` (the first-run seed).
  static func commandBar(_ name: String, runtime rt: DenRuntime) -> NSWindow? {
    guard name.hasPrefix("commandBar:") else { return nil }
    let q = String(name.dropFirst("commandBar:".count))
    rt.call("commands", "open", ["mode": "new", "query": .string(q)])
    // As if typed: caret at the end, nothing selected.
    rt.ui.commandBar.input.currentEditor()?.selectedRange = NSRange(location: (q as NSString).length, length: 0)
    return rt.window.window
  }
}
