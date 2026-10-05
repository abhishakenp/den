import AppKit
import CordisValue
import DenTestSupport
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// `runtime.sendNativeMessage` / `runtime.connectNative` end to end: a local extension with the
/// `nativeMessaging` permission, loaded in a real `WKWebExtensionController`, talks to a fake
/// desktop-app host (a Perl script speaking Chrome's length-prefixed JSON) through a Chrome-format
/// manifest in a temporary NativeMessagingHosts folder. No real password manager is involved.
@MainActor
@Suite(.serialized, .watchdog)
struct NativeMessagingTests {
  /// Any base64 works as a manifest `key` for the id (Chrome hashes the bytes).
  static let key = "ZGVuLW5hdGl2ZS1tZXNzYWdpbmctdGVzdA=="
  static var chromeId: String { ExtensionPackage.chromeId(publicKey: Data(base64Encoded: key)!) }

  /// Echoes each message back as `{"echo": <message>, "argv": [args]}`; `{"cmd":"exit"}` exits,
  /// `{"cmd":"pid"}` answers its process id.
  static let echoHost = #"""
    #!/usr/bin/perl
    use strict; binmode STDIN; binmode STDOUT; $| = 1;
    my $args = join('","', @ARGV);
    sub out { my $j = shift; print pack("L", length($j)) . $j; }
    while (1) {
      my $n = read(STDIN, my $len, 4); last unless defined $n && $n == 4;
      my $l = unpack("L", $len); my $msg = ''; read(STDIN, $msg, $l);
      exit 0 if $msg eq '{"cmd":"exit"}';
      if ($msg eq '{"cmd":"pid"}') { out('{"pid":' . $$ . '}'); next; }
      out('{"echo":' . $msg . ',"argv":["' . $args . '"]}');
    }
    """#

  /// A NativeMessagingHosts folder with `io.den.test_echo` (allows the test extension) and
  /// `io.den.test_other` (allows another extension only).
  static func hosts() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("den-nm-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    let bin = d.appendingPathComponent("echo-host")
    try echoHost.write(to: bin, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    try #"{"name": "io.den.test_echo", "description": "test", "path": "\#(bin.path)", "type": "stdio", "allowed_origins": ["chrome-extension://\#(chromeId)/"]}"#
      .write(to: d.appendingPathComponent("io.den.test_echo.json"), atomically: true, encoding: .utf8)
    try #"{"name": "io.den.test_other", "description": "test", "path": "\#(bin.path)", "type": "stdio", "allowed_origins": ["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]}"#
      .write(to: d.appendingPathComponent("io.den.test_other.json"), atomically: true, encoding: .utf8)
    return d
  }

  static func fixture() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("den-nm-ext-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    try """
      {"manifest_version": 3, "name": "Native Test", "version": "1.0", "key": "\(key)",
       "permissions": ["nativeMessaging"], "background": {"service_worker": "bg.js"}, "options_page": "options.html"}
      """.write(to: d.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try "".write(to: d.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8)
    try "<!doctype html><title>Native Test</title>".write(to: d.appendingPathComponent("options.html"), atomically: true, encoding: .utf8)
    return d
  }

  func wait(_ seconds: Double = 45, file: StaticString = #fileID, line: UInt = #line, _ cond: () -> Bool) async -> Bool {
    await Wait.until("a condition", seconds: seconds, file: file, line: line) { cond() }
  }

  /// A page of the extension's own (where `chrome.runtime` is).
  func page(_ h: Harness, _ id: String) async throws -> WKWebView {
    let ctx = try #require(h.rt.extensions.contexts[id])
    let cfg = try #require(ctx.webViewConfiguration)
    let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
    w.load(URLRequest(url: ctx.baseURL.appendingPathComponent("options.html")))
    #expect(await wait(20) { !w.isLoading && w.url != nil })
    return w
  }

  /// Runs `script` (an async function body) in a fresh page of the extension, or in `w`.
  func run(_ h: Harness, _ id: String, in w: WKWebView? = nil, _ script: String) async throws -> String {
    let web: WKWebView
    if let w { web = w } else { web = try await page(h, id) }
    defer { if w == nil { web.stopLoading() } }
    let r: String? = await Wait.callback("native script", seconds: 30) { done in
      web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { res in
        switch res {
        case .success(let v): done(v as? String ?? "\(String(describing: v))")
        case .failure(let e): done("js error: \(e)")
        }
      }
    }
    return try #require(r)
  }

  func json(_ s: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:] }

  @Test func extensionTalksToADesktopAppsHost() async throws {
    let hostDir = try Self.hosts()
    let h = Harness()
    h.startTabs()
    h.record(["webext.installed", "webext.failed"])
    h.rt.extensions.native.directories = [hostDir]
    #expect(h.rt.call("webext", "install", ["path": .string(try Self.fixture().path)])["pending"] == true)
    #expect(await wait { h.rt.ui.dialogOpen })
    #expect(h.rt.ui.dialog.message.stringValue.contains("Communicate with cooperating native apps"))
    h.action("extensions.prompt:1", "button", ["button": "ok"])
    #expect(await wait { h.events.contains { $0.0 == "webext.installed" } })
    let id = Self.chromeId
    #expect(await wait { h.rt.extensions.contexts[id]?.isLoaded == true })

    // sendNativeMessage: one host per message, Chrome's argument (the caller's origin).
    let one = json(try await run(h, id, """
      try { return JSON.stringify({reply: await chrome.runtime.sendNativeMessage('io.den.test_echo', {hello: 1, text: 'héllo'})}); }
      catch (e) { return JSON.stringify({error: String(e.message || e)}); }
      """))
    let reply = one["reply"] as? [String: Any]
    #expect((reply?["echo"] as? [String: Any])?["hello"] as? Int == 1, "\(one)")
    #expect((reply?["echo"] as? [String: Any])?["text"] as? String == "héllo")
    #expect(reply?["argv"] as? [String] == ["chrome-extension://\(id)/"])
    // The one-shot host is closed after its answer.
    #expect(await wait(10) { h.rt.extensions.native.running.isEmpty })

    // Not listed in the manifest, and no manifest at all: Chrome's errors.
    let refused = json(try await run(h, id, """
      const out = {};
      for (const n of ['io.den.test_other', 'io.den.missing', '../escape']) {
        try { await chrome.runtime.sendNativeMessage(n, {}); out[n] = 'answered'; } catch (e) { out[n] = String(e.message || e); }
      }
      return JSON.stringify(out);
      """))
    #expect((refused["io.den.test_other"] as? String)?.contains("forbidden") == true, "\(refused)")
    #expect((refused["io.den.missing"] as? String)?.contains("not found") == true, "\(refused)")
    #expect((refused["../escape"] as? String)?.contains("not found") == true, "\(refused)")

    // connectNative: one host for the life of the port; messages both ways, in order; the host
    // exiting disconnects the port with Chrome's message.
    let port = json(try await run(h, id, """
      const port = chrome.runtime.connectNative('io.den.test_echo');
      const got = [];
      const ended = new Promise((r) => port.onDisconnect.addListener(() => r(String(chrome.runtime.lastError?.message || port.error?.message || 'disconnected'))));
      const two = new Promise((r) => port.onMessage.addListener((m) => { got.push(m); if (got.length === 3) r(); }));
      port.postMessage({n: 1}); port.postMessage({n: 2}); port.postMessage({cmd: 'pid'});
      await Promise.race([two, new Promise((r) => setTimeout(r, 10000))]);
      port.postMessage({cmd: 'exit'});
      const why = await Promise.race([ended, new Promise((r) => setTimeout(() => r('still connected'), 10000))]);
      return JSON.stringify({got, why});
      """))
    let got = port["got"] as? [[String: Any]] ?? []
    #expect(got.count == 3, "\(port)")
    #expect(got.prefix(2).map { ($0["echo"] as? [String: Any])?["n"] as? Int } == [1, 2])
    let pid = got.last?["pid"] as? Int32
    #expect(pid != nil)
    // WebKit disconnects the port; it doesn't hand the reason (Chrome's "Native host has exited.")
    // to the page's onDisconnect.
    #expect(port["why"] as? String != "still connected", "\(port)")
    #expect(await wait(10) { h.rt.extensions.native.running.isEmpty })

    // A port the extension closes stops its host (stdin closed, then SIGTERM).
    let closed = json(try await run(h, id, """
      const port = chrome.runtime.connectNative('io.den.test_echo');
      const pid = await new Promise((r) => { port.onMessage.addListener((m) => r(m.pid)); port.postMessage({cmd: 'pid'}); setTimeout(() => r(0), 10000); });
      port.disconnect();
      return JSON.stringify({pid});
      """))
    let livePid = try #require(closed["pid"] as? Int32, "\(closed)")
    #expect(await wait(10) { h.rt.extensions.native.running.isEmpty && kill(livePid, 0) != 0 })

    // Unloading the extension stops whatever hosts it still runs.
    let keeper = try await page(h, id)
    _ = try await run(h, id, in: keeper, "globalThis.keep = chrome.runtime.connectNative('io.den.test_echo'); keep.postMessage({n: 9}); await new Promise((r) => setTimeout(r, 500)); return 'ok';")
    #expect(await wait(10) { h.rt.extensions.native.running.count == 1 })
    let pids = h.rt.extensions.native.running.values.map { $0.process.processIdentifier }
    #expect(h.rt.call("webext", "setEnabled", ["id": .string(id), "enabled": false]) == .ok)
    #expect(await wait(10) { h.rt.extensions.native.running.isEmpty && pids.allSatisfy { kill($0, 0) != 0 } })
    keeper.stopLoading()
    h.rt.tearDown()
  }
}
