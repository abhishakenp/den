// Dev fixture: compiled only with the `Scenarios` package trait (on by default; release bundles leave it out).
#if Scenarios
import AppKit
@preconcurrency import LocalAuthentication
import CordisValue
import WebKit

/// `--scenario` states for the password vault, on MockServices' local login pages with an
/// in-memory store (never the real Keychain) and a scripted Touch ID that approves (the real
/// prompt needs a person). The page is driven by script in the page itself, like a user typing.
///
/// - `vaultSave`: type a login and submit: the "Save password?" dialog.
/// - `vaultSuggest`: a saved login, then focus the password field: the suggestion list.
/// - `vaultFill`: pick the suggestion: Touch ID (scripted) and the filled form.
/// - `vaultGenerate`: a sign-up form's password field: the strong-password suggestion.
/// - `vaultSheet`: the Passwords sheet after Touch ID (scripted).
// thin-host: feature-specific, migrate to plugin (dev scenarios for the passwords plugin)
@MainActor
public enum VaultScenarios {
  public static let names = ["vaultSave", "vaultSuggest", "vaultFill", "vaultGenerate", "vaultSheet"]
  static var mock: MockServices?

  final class ApproveAuth: VaultAuth {
    func authenticate(reason: String, _ done: @escaping @MainActor (Bool, LAContext?) -> Void) {
      print("scenario.touchID approved (scripted): \(reason)")
      DispatchQueue.main.async { done(true, nil) }
    }
  }

  public static func apply(_ name: String, runtime rt: DenRuntime) {
    let m = MockServices()
    try? m.start()
    mock = m
    let store = MemoryVaultStore()
    rt.vault.store = store
    rt.vault.auth = ApproveAuth()
    let origin = "http://127.0.0.1:\(m.port)"
    if name != "vaultSave" {
      _ = store.save(origin: origin, username: "ada@example.com", password: Data("correct-horse-battery".utf8))
      _ = store.save(origin: "https://news.ycombinator.com", username: "ada", password: Data("x".utf8))
    }
    if name == "vaultSheet" {
      rt.plugins.emit("commands.run", ["id": "passwords.open"])
      return
    }
    let path = name == "vaultGenerate" ? "/vault/signup" : "/vault/login"
    let id = rt.call("tabs", "open", ["url": .string(m.base + path)])["id"]
    rt.call("tabs", "select", ["id": id])
    let wid = id.string ?? ""
    func js(_ s: String) { rt.webviews.record(wid)?.webView?.evaluateJavaScript(s) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      switch name {
      case "vaultSave":
        js("document.getElementById('u').value='ada@example.com';document.getElementById('p').value='correct-horse-battery';document.getElementById('go').click()")
      case "vaultGenerate":
        js("document.getElementById('p1').focus()")
      default:
        js("document.getElementById('p').focus()")
        if name == "vaultFill" {
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            rt.plugins.emit("vault.suggestion", ["webview": .string(wid), "item": .string("fill:\(origin) ada@example.com")])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
              rt.webviews.record(wid)?.webView?.evaluateJavaScript("document.getElementById('u').value + ' / ' + document.getElementById('p').value.length") { v, _ in
                print("scenario.vaultFill fields: \(v ?? "nil")")
              }
            }
          }
        }
      }
    }
  }
}
#endif
