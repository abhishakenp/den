import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost

/// `session.watchCookies`: event-driven sign-in detection (auto-connect). No observer, timer or
/// read exists until something watches, and only real changes on the watched domain are reported.
/// The sign-ins are real: pages of the local fake GitHub/Slack (`MockServices`) set cookies in a tab.
@MainActor
@Suite(.serialized)
struct CookieWatchTests {
  func until(_ seconds: Double = 20, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if cond() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return cond()
  }

  @Test func watchReportsOnlyRealChangesOnTheWatchedDomainAndStopsOnUnwatch() async throws {
    let m = MockServices()
    try m.start()
    defer { m.stop() }
    let rt = ServiceTests.runtime()
    // A persistent profile store, like the ones people sign in with.
    let profile = "cookiewatch-\(UUID().uuidString)"
    rt.permissions.grant("gh", ["session:127.0.0.1", "session:example.com"])
    var events: [Value] = []
    rt.plugins.on("session.cookiesChanged") { events.append($0) }
    let session = rt.session
    let tab = rt.call("webviews", "create", ["url": "about:blank", "profile": .string(profile)]).str("id")
    rt.call("content", "show", ["panes": [.string(tab)]])
    let w = rt.webviews.materialize(tab)!
    // At rest: no observer, no load observation, no pending read.
    #expect(session.observedProfiles.isEmpty && session.observedLoads == 0 && session.pendingCookieReads == 0)
    // Undeclared domain: refused.
    #expect(rt.call("session", "watchCookies", ["plugin": "gh", "domain": "github.com", "profile": .string(profile)]).isError)
    #expect(session.observedProfiles.isEmpty)

    #expect(rt.call("session", "watchCookies", ["plugin": "gh", "domain": "127.0.0.1", "profile": .string(profile)]) == .ok)
    #expect(rt.call("session", "watchCookies", ["plugin": "gh", "domain": "127.0.0.1", "profile": .string(profile)]) == .ok)  // idempotent
    #expect(rt.call("session", "watchCookies", ["plugin": "gh", "domain": "example.com", "profile": .string(profile)]) == .ok)
    #expect(await until { session.observedProfiles == [profile] && session.hasBaseline("127.0.0.1", profile: profile) && session.hasBaseline("example.com", profile: profile) })
    #expect(session.observedLoads == 1)

    func load(_ path: String) async -> Bool {
      w.load(URLRequest(url: URL(string: m.base + path)!))
      return await until(45) { !w.isLoading && w.url?.path == path }
    }

    // The user signs in to the site: its response sets three cookies. One event, no values, and
    // only for the domain whose cookies changed (example.com didn't).
    #expect(await load("/login"))
    #expect(await until { !events.isEmpty })
    try? await Task.sleep(for: .milliseconds(800))
    #expect(events == [["domain": "127.0.0.1", "profile": .string(profile)]])
    // (Alone, the cookie-store observer sees this sign-in; after other tests in the same process
    // have read cookie stores it may stay silent, and the page-load backstop reports it instead.)
    #expect(session.pendingCookieReads == 0)

    // Loading the site again with the same cookies: nothing to report.
    #expect(await load("/login"))
    try? await Task.sleep(for: .milliseconds(800))
    #expect(events.count == 1)

    // Another sign-in on the same domain (Slack's `d` cookie): reported again.
    #expect(await load("/slack/signin"))
    #expect(await until { events.count == 2 })

    // Unwatched: observers and load observation go away; changes are no longer read.
    #expect(rt.call("session", "unwatchCookies", ["plugin": "gh", "domain": "127.0.0.1", "profile": .string(profile)]) == .ok)
    #expect(session.observedProfiles == [profile])  // example.com is still watched
    #expect(rt.call("session", "unwatchCookies", ["plugin": "gh", "domain": "example.com", "profile": .string(profile)]) == .ok)
    #expect(session.observedProfiles.isEmpty && session.observedLoads == 0)
    let store = rt.webviews.store(for: profile).httpCookieStore
    for c in await store.allCookies() where c.name == "logged_in" { await store.deleteCookie(c) }
    #expect(await load("/login"))
    try? await Task.sleep(for: .milliseconds(800))
    #expect(events.count == 2)
    #expect(session.pendingCookieReads == 0)
    rt.call("webviews", "close", ["id": .string(tab)])
    for c in await store.allCookies() { await store.deleteCookie(c) }
  }
}
