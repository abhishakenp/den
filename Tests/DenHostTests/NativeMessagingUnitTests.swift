import Foundation
import Testing

@testable import DenHost

/// The parts of native messaging that need no extension: host names, manifest lookup and
/// precedence, Chrome/Firefox access rules, arguments and message framing.
@MainActor
@Suite struct NativeMessagingUnitTests {
  func folder(_ manifests: [String: String]) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("den-nmu-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    for (name, body) in manifests { try body.write(to: d.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8) }
    return d
  }

  @Test func hostNames() {
    for ok in ["com.8bit.bitwarden", "com.1password.1password", "a", "io.den.test_echo"] { #expect(NativeMessaging.isValidName(ok), "\(ok)") }
    for bad in ["", ".a", "a.", "a..b", "../x", "A.b", "a/b", "a b", "com.bitwarden-desktop"] { #expect(!NativeMessaging.isValidName(bad), "\(bad)") }
  }

  @Test func manifestsAccessAndArguments() throws {
    let exe = "/bin/cat"
    let caller = NativeMessaging.Caller(id: "x", chromeId: "nngceckbapebfimnlniiiahkandclblb", geckoId: "{446900e4-71c2-419f-a6a7-df9c091e268b}")
    let denOwn = try folder(["com.example.pm": #"{"name": "com.example.pm", "path": "\#(exe)", "type": "stdio", "allowed_origins": ["chrome-extension://nngceckbapebfimnlniiiahkandclblb/"]}"#])
    let chrome = try folder([
      "com.example.pm": #"{"name": "com.example.pm", "path": "\#(exe)", "type": "stdio", "allowed_origins": ["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]}"#,
      "com.example.wrongname": #"{"name": "something.else", "path": "\#(exe)", "type": "stdio", "allowed_origins": []}"#,
      "com.example.notexec": #"{"name": "com.example.notexec", "path": "/etc/hosts", "type": "stdio", "allowed_origins": ["chrome-extension://nngceckbapebfimnlniiiahkandclblb/"]}"#,
    ])
    let firefox = try folder(["com.example.ff": #"{"name": "com.example.ff", "path": "\#(exe)", "type": "stdio", "allowed_extensions": ["{446900e4-71c2-419f-a6a7-df9c091e268b}"]}"#])

    // The app's Chrome manifest doesn't list the extension: refused, as in Chrome.
    var nm = NativeMessaging(directories: [chrome, firefox])
    #expect(nm.resolve("com.example.pm", for: caller) == .failure(.forbidden))
    #expect(nm.resolve("com.example.missing", for: caller) == .failure(.notFound))
    #expect(nm.resolve("com.example.wrongname", for: caller) == .failure(.notFound))
    #expect(nm.resolve("com.example.notexec", for: caller) == .failure(.failedToStart))
    #expect(nm.resolve(nil, for: caller) == .failure(.notFound))
    // A den-only manifest that lists it lets it in, and comes first.
    nm = NativeMessaging(directories: [denOwn, chrome, firefox])
    let h = try #require(try? nm.resolve("com.example.pm", for: caller).get())
    #expect(h.flavor == "chrome" && h.manifest.hasPrefix(denOwn.path) && h.path == exe)
    #expect(NativeMessaging.arguments(h, caller) == ["chrome-extension://nngceckbapebfimnlniiiahkandclblb/"])
    #expect(nm.manifests(named: "com.example.pm").count == 2)
    // Firefox manifests: allowed_extensions, and Firefox's arguments (manifest path, extension id).
    let ff = try #require(try? nm.resolve("com.example.ff", for: caller).get())
    #expect(ff.flavor == "firefox")
    #expect(NativeMessaging.arguments(ff, caller) == [ff.manifest, "{446900e4-71c2-419f-a6a7-df9c091e268b}"])
    #expect(nm.resolve("com.example.ff", for: .init(id: "y", chromeId: "nngceckbapebfimnlniiiahkandclblb", geckoId: nil)) == .failure(.forbidden))
    // An extension with no Chrome id can't use a Chrome-format manifest.
    #expect(nm.resolve("com.example.pm", for: .init(id: "z", chromeId: nil, geckoId: nil)) == .failure(.forbidden))
  }

  @Test func defaultFoldersCoverChromeFamilyAndFirefox() {
    let home = URL(fileURLWithPath: "/Users/someone")
    let dirs = NativeMessaging.defaultDirectories(home: home, denHome: URL(fileURLWithPath: "/Users/someone/.den")).map(\.path)
    #expect(dirs.first == "/Users/someone/.den/NativeMessagingHosts")
    #expect(dirs[1] == "/Users/someone/Library/Application Support/den/NativeMessagingHosts")
    #expect(dirs.contains("/Users/someone/Library/Application Support/Google/Chrome/NativeMessagingHosts"))
    #expect(dirs.contains("/Users/someone/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"))
    #expect(dirs.contains("/Library/Google/Chrome/NativeMessagingHosts"))
    #expect(dirs.contains("/Users/someone/Library/Application Support/Mozilla/NativeMessagingHosts"))
  }

  @Test func framing() throws {
    var buf = try NativeMessaging.frame(["a": 1, "s": "é"])
    #expect(buf.count == 4 + Int(buf.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
    buf += try NativeMessaging.frame("two")
    // A partial third message stays in the buffer until the rest arrives.
    let third = try NativeMessaging.frame([1, 2, 3])
    buf += third.prefix(6)
    let got = try NativeMessaging.unframe(&buf)
    #expect(got.count == 2)
    #expect((got[0] as? [String: Any])?["s"] as? String == "é")
    #expect(got[1] as? String == "two")
    #expect(buf.count == 6)
    buf += third.dropFirst(6)
    #expect((try NativeMessaging.unframe(&buf).first as? [Int]) == [1, 2, 3])
    #expect(buf.isEmpty)
    // Over 1 MB from a host, or bytes that aren't JSON: refused.
    var big = Data()
    var n = UInt32(NativeMessaging.maxIncoming + 1)
    big.append(Data(bytes: &n, count: 4))
    #expect(throws: NativeMessaging.Failure.self) { _ = try NativeMessaging.unframe(&big) }
    var junk = Data()
    var m = UInt32(3)
    junk.append(Data(bytes: &m, count: 4))
    junk.append(Data("{{{".utf8))
    #expect(throws: NativeMessaging.Failure.self) { _ = try NativeMessaging.unframe(&junk) }
  }
}
