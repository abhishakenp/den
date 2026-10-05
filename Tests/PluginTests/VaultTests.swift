import AppKit
import CordisValue
import Foundation
import LocalAuthentication
import DenTestSupport
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// The password vault: the host `vault` service with an in-memory store and a scripted Touch ID,
/// the `passwords` plugin, and real WebKit pages (a mock login and sign-up form; no real sites).
@MainActor
@Suite(.serialized, .watchdog)
struct VaultTests {
  final class FakeAuth: VaultAuth {
    var approve = true
    var asked: [String] = []
    func authenticate(reason: String, _ done: @escaping @MainActor (Bool, LAContext?) -> Void) {
      asked.append(reason)
      let ok = approve
      DispatchQueue.main.async { done(ok, nil) }
    }
  }

  @MainActor struct Env {
    let h: Harness
    let store: MemoryVaultStore
    let auth: FakeAuth
    let core: PasswordsCore
    var events: [(String, Value)] { h.events }
  }

  func start() -> Env {
    let h = Harness()
    let store = MemoryVaultStore(), auth = FakeAuth()
    h.rt.vault.store = store
    h.rt.vault.auth = auth
    h.record(["vault.focus", "vault.captured", "vault.result", "vault.blur"])
    let core = PasswordsCore(env: h.env)
    core.start()
    return Env(h: h, store: store, auth: auth, core: core)
  }

  static let login = """
    <html><body><form id=f action="javascript:void 0">
    <input id=u name=username autocomplete=username><input id=p type=password autocomplete=current-password>
    <button id=go type=submit>Sign in</button></form></body></html>
    """
  static let signup = """
    <html><body><form id=f action="javascript:void 0">
    <input id=u type=email name=email><input id=p1 type=password autocomplete=new-password><input id=p2 type=password autocomplete=new-password>
    <button type=submit>Create account</button></form></body></html>
    """

  func page(_ h: Harness, _ id: String, _ html: String, _ base: String) async throws -> WKWebView {
    h.rt.call("webviews", "create", ["id": .string(id)])
    let w = h.rt.webviews.materialize(id)!
    w.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    h.rt.window.window.contentView?.addSubview(w)
    w.loadHTMLString(html, baseURL: URL(string: base))
    _ = await Wait.until("\(base) to load") { !w.isLoading && w.url?.absoluteString == base }
    // Loaded isn't enough on a slow machine (a CI runner's first WebContent process): typing could
    // hit the old document for one field and the form for the other (a capture with an empty
    // username). Wait for the form itself.
    for _ in 0..<600 {  // up to 30 s
      let r = await js(w, "return document.readyState === 'complete' && !!document.getElementById('f')")
      if r == "1" || r == "true" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    return w
  }

  @discardableResult
  func js(_ w: WKWebView, _ s: String, line: UInt = #line) async -> String {
    await Wait.asyncJS(w, s, line: line).map { "\($0)" } ?? "error"
  }

  func wait(line: UInt = #line, _ cond: () -> Bool) async throws -> Bool {
    await Wait.until("a condition", seconds: 20, line: line) { cond() }
  }

  func type(_ w: WKWebView, _ fields: [String: String]) async {
    // One script, in a fixed order, so every field lands in the same document.
    await js(w, fields.sorted { $0.key < $1.key }.map { "document.getElementById('\($0.key)').value = '\($0.value)';" }.joined())
  }


  /// Closes every web view the test made, so their WebContent processes don't outlive it and
  /// slow down other suites' real-event tests.
  func closeAll(_ h: Harness) {
    for id in h.rt.call("webviews", "list").array ?? [] { h.rt.call("webviews", "close", ["id": id]) }
  }

  @Test func submitOffersToSaveAndSaves() async throws {
    let e = start()
    defer { closeAll(e.h) }
    let w = try await page(e.h, "t1", Self.login, "https://login.test/signin")
    await type(w, ["u": "ada@example.com", "p": "hunter2-correct"])
    await js(w, "document.getElementById('go').click()")
    #expect(try await wait { e.events.contains { $0.0 == "vault.captured" } })
    let cap = e.events.first { $0.0 == "vault.captured" }!.1
    #expect(cap.s("origin") == "https://login.test" && cap.s("username") == "ada@example.com" && cap.b("exists") == false)
    #expect(cap["password"].isNull && !"\(cap)".contains("hunter2"))  // never leaves the host
    // The save dialog, then Save.
    #expect(e.h.rt.ui.dialogOpen && e.h.rt.ui.dialog.node.s("title") == "Save password for login.test?")
    e.h.action("passwords.save", "button", ["button": "save"])
    #expect(!e.h.rt.ui.dialogOpen)
    #expect(e.store.items["https://login.test ada@example.com"]?.1 == Data("hunter2-correct".utf8))
    #expect(e.h.rt.vault.captures.isEmpty)
    // A capture can't be saved twice.
    #expect(e.h.rt.call("vault", "save", ["capture": cap["capture"]]).isErr)
  }

  @Test func neverForThisSite() async throws {
    let e = start()
    defer { closeAll(e.h) }
    let w = try await page(e.h, "t2", Self.login, "https://never.test/")
    await type(w, ["u": "bob", "p": "pw-one"])
    await js(w, "document.getElementById('f').requestSubmit()")
    #expect(try await wait { e.h.rt.ui.dialogOpen })
    e.h.action("passwords.save", "button", ["button": "never"])
    #expect(e.h.storage("passwords", "never") == ["https://never.test"])
    await type(w, ["p": "pw-two"])
    await js(w, "document.getElementById('f').requestSubmit()")
    #expect(try await wait { e.events.filter { $0.0 == "vault.captured" }.count == 2 })
    #expect(!e.h.rt.ui.dialogOpen && e.store.items.isEmpty && e.h.rt.vault.captures.isEmpty)
  }

  @Test func plainHTTPIsIgnored() async throws {
    let e = start()
    defer { closeAll(e.h) }
    let w = try await page(e.h, "t3", Self.login, "http://insecure.test/")
    await type(w, ["u": "bob", "p": "pw"])
    await js(w, "document.getElementById('p').focus(); document.getElementById('f').requestSubmit()")
    try await Task.sleep(for: .milliseconds(400))
    #expect(!e.events.contains { $0.0 == "vault.captured" || $0.0 == "vault.focus" })
    // Loopback http is allowed (local development and den's mock pages).
    #expect(VaultService.origin(scheme: "http", host: "127.0.0.1", port: 8080) == "http://127.0.0.1:8080")
    #expect(VaultService.origin(scheme: "http", host: "example.com", port: 80) == "")
    #expect(VaultService.origin(scheme: "https", host: "Example.com", port: 443) == "https://example.com")
  }

  @Test func focusSuggestsThenTouchIDFills() async throws {
    let e = start()
    defer { closeAll(e.h) }
    _ = e.store.save(origin: "https://login.test", username: "ada", password: Data("s3cret-pw".utf8))
    _ = e.store.save(origin: "https://other.test", username: "eve", password: Data("nope".utf8))
    let w = try await page(e.h, "t4", Self.login, "https://login.test/")
    await js(w, "document.getElementById('p').focus()")
    #expect(try await wait { e.events.contains { $0.0 == "vault.focus" } })
    let f = e.events.first { $0.0 == "vault.focus" }!.1
    #expect(f.a("accounts").map { $0.s("username") } == ["ada"] && f.s("field") == "password")
    // The suggestion list sits in the web view, one row per login for this origin only.
    let view = e.h.rt.vault.suggestions["t4"]
    #expect(view?.superview === w.superview && view?.stack.arrangedSubviews.count == 1)
    // Under the focused field (page y 8…29), not over the page.
    #expect(view.map { w.convert($0.frame, from: w.superview).minY > 29 && $0.frame.height < 100 } == true)
    // Touch ID refused: nothing read, nothing filled.
    e.auth.approve = false
    e.core.picked("t4", "fill:https://login.test ada")
    #expect(try await wait { e.events.contains { $0.0 == "vault.result" } })
    let empty = await js(w, "return document.getElementById('p').value")
    #expect(e.store.reads == 0 && empty == "")
    // Approved: filled into the page, username too.
    e.auth.approve = true
    await js(w, "document.getElementById('p').focus()")
    e.core.picked("t4", "fill:https://login.test ada")
    #expect(try await wait { e.events.filter { $0.0 == "vault.result" && $0.1.b("ok") }.count == 1 })
    #expect(await js(w, "return document.getElementById('p').value") == "s3cret-pw")
    #expect(await js(w, "return document.getElementById('u').value") == "ada")
    #expect(e.auth.asked.count == 2 && e.store.reads == 1)
    // Another origin's login is never filled here.
    #expect(e.h.rt.call("vault", "fill", ["webview": "t4", "account": "https://other.test eve"]).isErr)
  }

  @Test func signupGetsAStrongPasswordThenSaves() async throws {
    let e = start()
    defer { closeAll(e.h) }
    let w = try await page(e.h, "t5", Self.signup, "https://new.test/join")
    await js(w, "document.getElementById('p1').focus()")
    #expect(try await wait { e.events.contains { $0.0 == "vault.focus" && $0.1.b("signup") } })
    #expect(e.h.rt.vault.suggestions["t5"]?.stack.arrangedSubviews.count == 1)
    e.core.picked("t5", "generate")
    #expect(try await wait { e.events.contains { $0.0 == "vault.result" && $0.1.s("method") == "generate" && $0.1.b("ok") } })
    let p1 = await js(w, "return document.getElementById('p1').value"), p2 = await js(w, "return document.getElementById('p2').value")
    #expect(p1 == p2 && p1.range(of: "^[a-zA-Z2-9]{6}-[a-zA-Z2-9]{6}-[a-zA-Z2-9]{6}$", options: .regularExpression) != nil)
    #expect(e.auth.asked.isEmpty)  // generating needs no Touch ID
    // Filling focused each field on the way: the list doesn't pop back up under the last one.
    let focuses = e.events.filter { $0.0 == "vault.focus" }.count
    try await Task.sleep(for: .milliseconds(300))
    #expect(e.events.filter { $0.0 == "vault.focus" }.count == focuses && e.h.rt.vault.suggestions["t5"] == nil)
    await type(w, ["u": "new@example.com"])
    await js(w, "document.getElementById('f').requestSubmit()")
    #expect(try await wait { e.h.rt.ui.dialogOpen })
    e.h.action("passwords.save", "button", ["button": "save"])
    #expect(e.store.items["https://new.test new@example.com"]?.1 == Data(p1.utf8))
  }

  /// The key in the URL pill: shown while the page in front has saved logins; a click focuses the
  /// sign-in field, which opens the suggestions under it.
  @Test func keyButtonInTheURLPill() async throws {
    let e = start()
    defer { closeAll(e.h) }
    // The tabs plugin's URL-pill buttons (tabs.pillButtons), recorded.
    var pill: [String: [Value]] = [:]
    e.h.rt.plugins.provide("tabs") { m, a in
      if m == "pillButtons" { MainActor.assumeIsolated { pill[a.s("webview")] = a.a("buttons") } }
      return .ok
    }
    _ = e.store.save(origin: "https://login.test", username: "ada", password: Data("pw".utf8))
    let w = try await page(e.h, "t6", Self.login, "https://login.test/")
    e.h.rt.call("content", "show", ["panes": ["t6"]])
    #expect(try await wait { pill["t6"]?.first?.s("id") == "passwords.key" })
    #expect(pill["t6"]?.first?.s("tooltip") == "Fill your saved password for login.test")
    #expect(e.h.rt.call("vault", "accounts", ["webview": "t6"]).array?.count == 1)
    e.h.action("passwords.key", "click", ["webview": "t6"])
    #expect(try await wait { e.events.contains { $0.0 == "vault.focus" } })
    #expect(e.h.rt.vault.suggestions["t6"]?.stack.arrangedSubviews.count == 1)
    #expect(await js(w, "return document.activeElement.id") == "p")
    // A page without saved logins: no key.
    w.loadHTMLString(Self.login, baseURL: URL(string: "https://elsewhere.test/"))
    #expect(try await wait { pill["t6"]?.isEmpty == true })
  }

  /// Username-first sign-ins (Google): the email step has no password field, yet the saved login is
  /// offered and fills the username.
  @Test func usernameFirstStep() async throws {
    let e = start()
    defer { closeAll(e.h) }
    _ = e.store.save(origin: "https://accounts.test", username: "ada@example.com", password: Data("pw".utf8))
    let w = try await page(e.h, "t7", "<form><input id=u type=email autocomplete='username webauthn'><button>Next</button></form>", "https://accounts.test/")
    await js(w, "document.getElementById('u').focus()")
    #expect(try await wait { e.events.contains { $0.0 == "vault.focus" } })
    #expect(e.h.rt.vault.suggestions["t7"]?.stack.arrangedSubviews.count == 1)
    e.core.picked("t7", "fill:https://accounts.test ada@example.com")
    #expect(try await wait { e.events.contains { $0.0 == "vault.result" && $0.1.b("ok") } })
    #expect(await js(w, "return document.getElementById('u').value") == "ada@example.com")
    #expect(e.auth.asked == ["fill your password for accounts.test"])
  }

  /// The real path on this Mac: the login Keychain (or the data protection one) and a real
  /// `LAContext`. Save from a mock login page, reload, focus, the suggestion appears, pick it, and
  /// Touch ID is really asked for ("fill your password for …"). Nobody touches the sensor, so the
  /// test cancels the prompt after 3 s and checks the answer is a cancel (the prompt was on
  /// screen), not biometryNotAvailable or a Keychain error. It shows the system Touch ID sheet for
  /// 3 s, so it only runs with DEN_TOUCHID_PROBE=1.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DEN_TOUCHID_PROBE"] == "1"))
  func realTouchIDPromptOnFill() async throws {
    let h = Harness()
    let store = SystemKeychain(), auth = SystemAuth()
    h.rt.vault.store = store
    h.rt.vault.auth = auth
    h.record(["vault.focus", "vault.captured", "vault.result"])
    let core = PasswordsCore(env: h.env)
    core.start()
    let origin = "https://den-touchid-probe.invalid"
    defer {
      for a in store.accounts() where a.origin == origin { _ = store.delete(a) }
      closeAll(h)
    }
    var w = try await page(h, "tid", Self.login, origin + "/signin")
    await type(w, ["u": "probe@den.test", "p": "probe-pw-1"])
    await js(w, "document.getElementById('go').click()")
    #expect(try await wait { h.rt.ui.dialogOpen })
    h.action("passwords.save", "button", ["button": "save"])
    #expect(store.accounts().contains { $0.origin == origin }, "saved to the \(store.mode) keychain")
    // Reload, focus the field: the suggestion.
    closeAll(h)
    w = try await page(h, "tid2", Self.login, origin + "/signin")
    await js(w, "document.getElementById('p').focus()")
    #expect(try await wait { h.rt.vault.suggestions["tid2"]?.stack.arrangedSubviews.count == 1 })
    var evaluated: LAContext?
    auth.willEvaluate = { ctx in
      evaluated = ctx
      nonisolated(unsafe) let c = ctx
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { c.invalidate() }
    }
    core.picked("tid2", "fill:" + origin + " probe@den.test")
    #expect(try await wait { h.events.contains { $0.0 == "vault.result" } })
    let r = h.events.first { $0.0 == "vault.result" }!.1
    let o = try #require(auth.last)
    print("touchid.probe mode=\(store.mode) result=\(r) outcome=\(o.name) code=\(o.code) ms=\(o.ms) biometryType=\(evaluated?.biometryType.rawValue ?? -1)")
    #expect(evaluated != nil)
    // The prompt was really on screen: either someone touched the sensor (then the Keychain read
    // and the fill ran), or it stayed up until den cancelled it (appCancel, -9, after ~3 s).
    // Never an immediate failure such as biometryNotAvailable (-6) or a Keychain error.
    let filled = await js(w, "return document.getElementById('p').value")
    if o.ok {
      #expect(r.b("ok") && filled == "probe-pw-1")
    } else {
      #expect(SystemAuth.isCancel(o.code) && o.ms >= 2500, "\(o.name) \(o.code) after \(o.ms) ms")
      #expect(r.s("error") == "cancelled" && filled == "")
    }
  }

  @Test func strongPasswords() {
    let all = (0..<200).map { _ in VaultService.strongPassword() }
    #expect(Set(all).count == 200)
    for p in all {
      #expect(p.count == 20 && p.contains { $0.isUppercase } && p.contains { $0.isNumber })
    }
  }

  @Test func passwordsSheetNeedsTouchID() async throws {
    let e = start()
    _ = e.store.save(origin: "https://login.test", username: "ada", password: Data("pw".utf8))
    #expect(e.h.rt.call("vault", "accounts").isErr)  // locked
    e.auth.approve = false
    e.core.open()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!e.core.sheetOpen && e.h.rt.ui.sheets["overlay.passwords"] == nil)
    e.auth.approve = true
    e.core.open()
    #expect(try await wait { e.core.sheetOpen })
    #expect(e.h.rt.ui.sheets["overlay.passwords"] != nil)
    #expect(e.h.rt.call("vault", "accounts").array?.count == 1)
    e.h.action("passwords.row:https://login.test ada", "secondary")  // Delete
    #expect(e.store.items.isEmpty)
    e.h.action("passwords", "dismiss")
    #expect(e.h.rt.ui.sheets["overlay.passwords"] == nil && e.h.rt.call("vault", "accounts").isErr)
  }

  /// Copy from the Passwords sheet: Touch ID, the password on the pasteboard marked concealed, a
  /// toast naming the account, and the pasteboard cleared later, unless something else was copied
  /// since. A private pasteboard and a short delay stand in for the general one and 60 s.
  @Test func copiedPasswordIsClearedUnlessReplaced() async throws {
    let e = start()
    let pb = NSPasteboard(name: NSPasteboard.Name("den-vault-test-\(UUID())"))
    defer { pb.releaseGlobally() }
    e.h.rt.vault.pasteboard = pb
    e.h.rt.vault.clipboardClearSeconds = 0.4
    _ = e.store.save(origin: "https://login.test", username: "ada", password: Data("pw".utf8))
    e.core.open()
    #expect(try await wait { e.core.sheetOpen })
    e.h.action("passwords.row:https://login.test ada", "click")
    #expect(try await wait { pb.string(forType: .string) == "pw" })
    #expect(pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
    #expect(try await wait { e.h.rt.ui.toasts.last?.label.stringValue == "Copied password for ada on login.test · clears in 60 s" })
    #expect(try await wait { pb.string(forType: .string) == nil })
    // Copied again, then something else is copied before the delay: that is left alone.
    e.h.action("passwords.row:https://login.test ada", "click")
    #expect(try await wait { pb.string(forType: .string) == "pw" })
    pb.clearContents()
    pb.setString("mine", forType: .string)
    try await Task.sleep(for: .milliseconds(700))
    #expect(pb.string(forType: .string) == "mine")
  }

  /// The real Keychain store, on a `.invalid` origin that is removed again. An ad-hoc signed
  /// process has no keychain-access-groups entitlement, so it lands in the login keychain ("app").
  @Test func systemKeychainRoundTrip() {
    let k = SystemKeychain()
    let origin = "https://den-vault-test.invalid"
    for a in k.accounts() where a.origin == origin { _ = k.delete(a) }
    #expect(k.save(origin: origin, username: "tester", password: Data("first".utf8)) == errSecSuccess)
    #expect(k.save(origin: origin, username: "tester", password: Data("second".utf8)) == errSecSuccess)  // update
    #expect(["acl", "app"].contains(k.mode))
    let mine = k.accounts().filter { $0.origin == origin }
    #expect(mine.map(\.username) == ["tester"])
    #expect(k.password(for: mine[0], context: nil) == Data("second".utf8))
    #expect(k.delete(mine[0]))
    #expect(!k.accounts().contains { $0.origin == origin })
  }
}
