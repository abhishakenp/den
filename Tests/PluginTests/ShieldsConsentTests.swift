import DenTestSupport
import AppKit
import CordisValue
import Foundation
import Testing
import WebKit

@testable import DenHost
@testable import PluginCores

/// Shields answering cookie consent dialogs (Consent.swift, resources/consent.js and
/// consent-frame.js) on local pages that mimic each platform's markup and storage, as seen on
/// live sites in October 2026 (nvidia.com, as.com, ilgiornale.it, theguardian.com, ibm.com, bt.dk).
/// The real path: den's `notify` rule list sees the platform's script load, `sitepolicy.notified`
/// reaches the plugin, consent.js runs in Shields' isolated world, the frame script runs in
/// Sourcepoint's message frame by match pattern. Platforms whose loader only lives on their own
/// host (Quantcast, TrustArc, Cookiebot) get the notification the host would send; their
/// url-filters are checked against real loader URLs below. Each fixture records a click on
/// "accept" in `window.accepted`, which must never happen.
@MainActor
@Suite(.serialized, .watchdog(seconds: 300))
struct ShieldsConsentTests {
  // MARK: Detection

  /// Loader URLs seen on live sites, and what must not match.
  static let loaderURLs: [(String, String?)] = [
    ("https://cdn.cookielaw.org/scripttemplates/otSDKStub.js", "onetrust"),
    ("https://www.example.com/scripts/otSDKStub.js", "onetrust"),
    ("https://cdn.cookielaw.org/scripttemplates/202608.1.0/otBannerSdk.js", "onetrust"),
    ("https://sdk.privacy-center.org/8ba38674-edba-484d-8053-435051d79f72/loader.js?target=as.com", "didomi"),
    ("https://www.lequipe.fr/api/didomi/c6616eb3-2250-4f20-a1f6-11a6ad14835c/loader.js?target=www.lequipe.fr", "didomi"),
    ("https://cmp.inmobi.com/choice/hMU0XDu2_Mqb_/www.ilgiornale.it/choice.js?tag_version=V3", "quantcast"),
    ("https://quantcast.mgr.consensu.org/choice/x/www.example.com/choice.js", "quantcast"),
    ("https://sourcepoint.theguardian.com/unified/wrapperMessagingWithoutDetection.js", "sourcepoint"),
    ("https://cdn.privacy-mgmt.com/unified/wrapperMessagingWithoutDetection.js", "sourcepoint"),
    ("https://consent.trustarc.com/notice?domain=trustarc.com&c=teconsent&js=nj&noticeType=bb", "trustarc"),
    ("https://consent.cookiebot.com/uc.js", "cookiebot"),
    ("https://consent.cookiebot.eu/uc.js?cbid=x", "cookiebot"),
    ("https://example.com/", nil),
    ("https://www.google-analytics.com/analytics.js", nil),
    ("https://cdn.example.com/didomi-logo.png", nil),
  ]

  @Test func detectionRulesMatchEachPlatformsLoaderAndNothingElse() throws {
    for (url, want) in Self.loaderURLs {
      var got: [String] = []
      for (filter, cmp) in Consent.loaders {
        // The Swift literal is JSON-escaped (`\\.`); the regex is what JSON decodes it to.
        let re = try NSRegularExpression(pattern: filter.replacingOccurrences(of: "\\\\", with: "\\"), options: [.caseInsensitive])
        if re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil, !got.contains(cmp) { got.append(cmp) }
      }
      #expect(got == (want.map { [$0] } ?? []), "\(url): \(got)")
    }
    // Valid JSON, every platform named, only notify actions.
    let rules = try #require(JSONSerialization.jsonObject(with: Data(Consent.rulesJSON().utf8)) as? [[String: Any]])
    #expect(rules.count == Consent.loaders.count)
    #expect(rules.allSatisfy { ($0["action"] as? [String: Any])?["type"] as? String == "notify" })
    #expect(Set(Consent.loaders.map { $0.1 }) == Set(Consent.platforms.map { $0.0 }))
  }

  // MARK: Fixtures

  /// OneTrust: a banner with Accept and Reject All; the choice is the OptanonConsent cookie.
  static let oneTrust = """
    setTimeout(() => {
      const b = document.createElement('div'); b.id = 'onetrust-banner-sdk';
      b.innerHTML = '<button id="onetrust-accept-btn-handler">Accept All Cookies</button><button id="onetrust-reject-all-handler">Reject All</button>';
      document.body.append(b);
      const set = g => { document.cookie = 'OptanonConsent=groups=' + encodeURIComponent(g) + '; path=/'; document.cookie = 'OptanonAlertBoxClosed=' + new Date().toISOString() + '; path=/'; b.remove(); };
      b.querySelector('#onetrust-accept-btn-handler').onclick = () => { window.accepted = true; set('C0001:1,C0002:1,C0003:1,C0004:1'); };
      b.querySelector('#onetrust-reject-all-handler').onclick = () => set('C0001:1,C0002:0,C0003:0,C0004:0');
    }, 400);
    """

  /// Didomi: the token exists before any choice; Disagree adds the disabled purposes and vendors.
  static let didomi = """
    document.cookie = 'didomi_token=' + btoa(JSON.stringify({user_id: 'u', version: null})) + '; path=/';
    setTimeout(() => {
      const h = document.createElement('div'); h.id = 'didomi-host';
      h.innerHTML = '<div id="didomi-notice"><button id="didomi-notice-agree-button">Agree and close</button><button id="didomi-notice-disagree-button">Disagree and close</button></div>';
      document.body.append(h);
      const set = (on) => { document.cookie = 'didomi_token=' + btoa(JSON.stringify({user_id: 'u', purposes: on ? {enabled: ['a', 'b']} : {disabled: ['a', 'b']}, vendors: on ? {enabled: ['v']} : {disabled: ['v']}})) + '; path=/'; h.innerHTML = ''; };
      h.querySelector('#didomi-notice-agree-button').onclick = () => { window.accepted = true; set(true); };
      h.querySelector('#didomi-notice-disagree-button').onclick = () => set(false);
    }, 400);
    """

  /// InMobi (Quantcast) Choice: Disagree leaves legitimate interest on; More options → Legitimate
  /// interest → Reject all objects to it; Reject all on the purposes screen saves at once.
  static let quantcast = """
    <div id="qc-cmp2-container"><div id="qc-cmp2-ui"><div class="qc-cmp2-summary-buttons">
      <button mode="secondary" id="more-options-btn">MORE OPTIONS</button><button mode="secondary" id="disagree-btn">DISAGREE</button><button mode="primary" id="accept-btn">AGREE</button>
    </div></div></div>
    <script>
    const ui = document.getElementById('qc-cmp2-ui');
    let screen = 'summary', li = true;
    const save = (consent) => { document.cookie = 'euconsent-v2=' + (consent ? 'all' : 'none') + (li ? '-li' : '-noli') + '; path=/'; document.getElementById('qc-cmp2-container').remove(); };
    document.getElementById('accept-btn').onclick = () => { window.accepted = true; li = true; save(true); };
    document.getElementById('disagree-btn').onclick = () => save(false);
    document.getElementById('more-options-btn').onclick = () => {
      ui.innerHTML = '<div class="qc-cmp2-header-links"><button mode="link" id="reject-all-btn">REJECT ALL</button><button mode="link" id="accept-all-btn">ACCEPT ALL</button></div>' +
        '<button id="partners-link">partners</button><button id="legitimate-interest">LEGITIMATE INTEREST</button><button mode="primary" id="save-and-exit">SAVE & EXIT</button>';
      screen = 'purposes';
      ui.onclick = e => {
        const id = e.target.id;
        if (id === 'accept-all-btn') { window.accepted = true; save(true); }
        if (id === 'legitimate-interest') screen = 'li';
        if (id === 'reject-all-btn') { if (screen === 'li') li = false; else save(false); }
        if (id === 'save-and-exit') save(false);
      };
    };
    </script>
    """

  /// Cookiebot: Deny / Allow all; the choice is the CookieConsent cookie.
  static let cookiebot = """
    <div id="CybotCookiebotDialog"><button id="CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll">Allow all</button><button id="CybotCookiebotDialogBodyButtonDecline">Deny</button></div>
    <script>
    const set = on => { document.cookie = "CookieConsent={stamp:'x',necessary:true,preferences:" + on + ",statistics:" + on + ",marketing:" + on + ",method:'explicit'}; path=/"; document.getElementById('CybotCookiebotDialog').remove(); };
    document.getElementById('CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll').onclick = () => { window.accepted = true; set(true); };
    document.getElementById('CybotCookiebotDialogBodyButtonDecline').onclick = () => set(false);
    </script>
    """

  /// TrustArc as on ibm.com: no reject on the banner; More options opens the preference centre in
  /// a shadow root, whose Decline All stores "required only".
  static let trustArc = """
    <div id="truste-consent-track"><button id="truste-consent-button">Accept All</button><button id="truste-show-consent">More options</button></div>
    <script>
    const set = v => { document.cookie = 'notice_preferences=' + v + '; path=/'; document.cookie = 'notice_gdpr_prefs=' + v + '; path=/'; document.getElementById('truste-consent-track').remove(); };
    document.getElementById('truste-consent-button').onclick = () => { window.accepted = true; set('2:'); };
    document.getElementById('truste-show-consent').onclick = () => {
      const host = document.createElement('div'); host.className = 'trustarc_newcm_container truste_popframe';
      document.body.append(host);
      const root = host.attachShadow({mode: 'open'});
      setTimeout(() => {
        root.innerHTML = '<button id="accept_all_button">Accept All</button><button id="decline_all_button">Decline All</button>';
        root.getElementById('accept_all_button').onclick = () => { window.accepted = true; set('2:'); host.remove(); };
        root.getElementById('decline_all_button').onclick = () => { set('0:'); host.remove(); };
      }, 300);
    };
    </script>
    """

  /// Sourcepoint: the wrapper puts the message in a frame on /index.html?message_id=…; the frame
  /// posts the choice back, the wrapper stores grants and a uuid and removes the message.
  static let sourcepointWrapper = """
    window._sp_ = {};
    addEventListener('DOMContentLoaded', () => {
      const box = document.createElement('div'); box.id = 'sp_message_container_1';
      box.innerHTML = '<iframe src="/index.html?message_id=1' + (location.pathname.includes('wall') ? '&wall=1' : '') + '" width=600 height=300></iframe>';
      document.body.append(box);
    });
    addEventListener('message', e => {
      if (!e.data || !e.data.sp) return;
      const on = e.data.sp === 'accept';
      if (on) window.accepted = true;
      localStorage.setItem('_sp_user_consent_1', JSON.stringify({gdpr: {uuid: 'u1', grants: {v1: {vendorGrant: on, purposeGrants: {p1: on}}, v2: {vendorGrant: true, purposeGrants: {necessary: true}}},
        consentStatus: {consentedToAny: on, consentedAll: on, rejectedAny: !on, rejectedLI: !on, granularStatus: {purposeConsent: on ? 'ALL' : 'NONE', purposeLegInt: on ? 'ALL' : 'NONE'}}}}));
      document.getElementById('sp_message_container_1').remove();
    });
    """

  static let sourcepointMessage = """
    <div class="message-component">
      <button class="message-button sp_choice_type_11">Accept all</button>
      <button class="message-button sp_choice_type_12">Manage</button>
      <button class="message-button sp_choice_type_13">Reject all</button>
    </div>
    <script>
    if (new URLSearchParams(location.search).get('wall')) {
      document.querySelector('.sp_choice_type_13').remove();
      document.querySelector('.message-component').insertAdjacentHTML('beforeend', '<button class="sp_choice_type_9">Subscribe</button>');
    }
    for (const [cls, v] of [['sp_choice_type_11', 'accept'], ['sp_choice_type_13', 'reject'], ['sp_choice_type_12', 'manage']]) {
      const b = document.querySelector('.' + cls); if (b) b.onclick = () => parent.postMessage({sp: v}, '*');
    }
    </script>
    """

  // MARK: Harness

  func start(_ h: Harness) -> ShieldsCore {
    h.rt.permissions.grant("shields", ["pages:*"])
    let core = ShieldsCore(env: h.env)
    h.rt.plugins.provide("shields") { m, a in core.handle(m, a) }
    core.start()
    return core
  }

  func until(_ seconds: Double = 30, _ f: () async -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if await f() { return true }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  /// A web view (created after the rules exist, as a tab would be) showing `url`.
  func open(_ h: Harness, _ id: String, _ url: String) async throws -> WKWebView {
    h.rt.call("webviews", "create", ["id": .string(id), "url": .string(url)])
    let w = try #require(h.rt.webviews.materialize(id))
    w.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    if w.superview == nil { h.rt.window.window.contentView?.addSubview(w) }
    w.load(URLRequest(url: URL(string: url)!))
    _ = try await until { !w.isLoading && w.url?.absoluteString == url }
    return w
  }

  func result(_ core: ShieldsCore, _ id: String) -> (cmp: String, result: String, detail: String)? {
    core.consentResults[id].map { ($0.cmp, $0.result, $0.detail) }
  }

  func accepted(_ w: WKWebView) async -> Bool {
    (try? await w.callAsyncJavaScript("return window.accepted === true", contentWorld: .page)) as? Bool ?? true
  }

  func cookie(_ w: WKWebView, _ name: String) async -> String {
    let all = (try? await w.callAsyncJavaScript("return document.cookie", contentWorld: .page)) as? String ?? ""
    for c in all.components(separatedBy: "; ") where c.hasPrefix(name + "=") { return String(c.dropFirst(name.count + 1)) }
    return ""
  }

  func ready(_ h: Harness) async throws -> Bool {
    try await until(120) {
      let l = (h.rt.call("sitepolicy", "list").array ?? []).filter { $0.flag("ready") }.map { $0.str("name") }
      return l.contains(Consent.list) && l.contains(Consent.frames)
    }
  }

  // MARK: Tests

  /// Every platform, end to end on local pages: the most private choice is stored, the dialog is
  /// gone, nothing was accepted, and the panel says what happened.
  @Test func answersEachPlatformWithItsMostPrivateChoice() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/ot/", "<p>OneTrust</p><script src='/ot/scripttemplates/otSDKStub.js'></script>")
    mock.page("/ot/scripttemplates/otSDKStub.js", Self.oneTrust, type: "text/javascript")
    mock.page("/dd/", "<p>Didomi</p><script src='/dd/didomi/abc/loader.js'></script>")
    mock.page("/dd/didomi/abc/loader.js", Self.didomi, type: "text/javascript")
    mock.page("/qc/", Self.quantcast)
    mock.page("/cb/", Self.cookiebot)
    mock.page("/ta/", Self.trustArc)
    mock.page("/sp/", "<p>Sourcepoint</p><script src='/sp/unified/wrapperMessagingWithoutDetection.js'></script>")
    mock.page("/sp/unified/wrapperMessagingWithoutDetection.js", Self.sourcepointWrapper, type: "text/javascript")
    mock.page("/index.html", Self.sourcepointMessage)

    let h = Harness()
    let core = start(h)
    #expect(try await ready(h), "\(h.rt.call("sitepolicy", "list"))")
    #expect(h.rt.sitePolicy.defaultRule.lists.contains(Consent.list))
    #expect(h.rt.sitePolicy.defaultRule.scripts.contains(Consent.frames))
    let info = (h.rt.call("sitepolicy", "list").array ?? []).first { $0.str("name") == Consent.frames }
    #expect(info?["allFrames"] == true)  // WebKit filters the frames by pattern

    // Detected by the notify rules (paths den's rules know).
    let ot = try await open(h, "ot", mock.base + "/ot/")
    let dd = try await open(h, "dd", mock.base + "/dd/")
    let sp = try await open(h, "sp", mock.base + "/sp/")
    // Host-anchored loaders: the notification the host would send.
    let qc = try await open(h, "qc", mock.base + "/qc/")
    let cb = try await open(h, "cb", mock.base + "/cb/")
    let ta = try await open(h, "ta", mock.base + "/ta/")
    for (id, cmp) in [("qc", "quantcast"), ("cb", "cookiebot"), ("ta", "trustarc")] {
      h.rt.host.emit("sitepolicy.notified", ["id": .string(id), "notification": .string("consent:" + cmp), "blocked": false])
    }

    #expect(try await until(60) { ["ot", "dd", "sp", "qc", "cb", "ta"].allSatisfy { core.consentResults[$0] != nil } }, "\(core.consentResults)")
    #expect(result(core, "ot")?.result == "rejected" && result(core, "ot")?.detail == "C0001:1,C0002:0,C0003:0,C0004:0", "\(String(describing: result(core, "ot")))")
    #expect(await cookie(ot, "OptanonConsent") == "groups=C0001%3A1%2CC0002%3A0%2CC0003%3A0%2CC0004%3A0")
    #expect(result(core, "dd")?.result == "rejected" && result(core, "dd")?.detail == "purposes enabled 0 of 2, vendors enabled 0 of 1", "\(String(describing: result(core, "dd")))")
    #expect(result(core, "sp")?.result == "rejected" && result(core, "sp")?.detail == "consented to nothing, legitimate interests objected (purpose consent NONE, legitimate interest NONE)", "\(String(describing: result(core, "sp")))")
    #expect(result(core, "qc")?.result == "rejected" && result(core, "qc")?.detail == "consent off, legitimate interests objected", "\(String(describing: result(core, "qc")))")
    #expect(await cookie(qc, "euconsent-v2") == "none-noli")
    #expect(result(core, "cb")?.result == "rejected" && result(core, "cb")?.detail == "preferences:false,statistics:false,marketing:false", "\(String(describing: result(core, "cb")))")
    #expect(result(core, "ta")?.result == "rejected", "\(String(describing: result(core, "ta")))")
    #expect(await cookie(ta, "notice_preferences") == "0:")
    for w in [ot, dd, sp, qc, cb, ta] { #expect(await accepted(w) == false, "\(w.url!)") }
    // Nothing of den's is visible to the page: consent.js lives in Shields' isolated world.
    #expect((try? await ot.callAsyncJavaScript("return typeof window.__denConsent", contentWorld: .page)) as? String == "undefined")

    // The panel's "On this page".
    core.openPanel("ot")
    let rows = core.panelTree()["children"].array?.first { $0["id"] == "shields.privacy" }?["children"].array ?? []
    #expect(rows.first { $0["id"] == "shields.consentResult" }?["value"] == "Rejected (OneTrust)", "\(rows)")
    core.closePanel()
    core.stop()
  }

  /// "Pay or accept" walls are left alone, an earlier answer is kept, and the switch works per
  /// site and globally.
  @Test func leavesWallsAndEarlierAnswersAloneAndFollowsTheSwitches() async throws {
    let mock = MockServices()
    try mock.start()
    defer { mock.stop() }
    mock.page("/wall/", "<p>Wall</p><script src='/wall/unified/wrapperMessagingWithoutDetection.js'></script>")
    mock.page("/wall/unified/wrapperMessagingWithoutDetection.js", Self.sourcepointWrapper, type: "text/javascript")
    mock.page("/index.html", Self.sourcepointMessage)
    mock.page("/ot/", "<p>OneTrust</p><script src='/ot/scripttemplates/otSDKStub.js'></script>")
    mock.page("/ot/scripttemplates/otSDKStub.js", Self.oneTrust, type: "text/javascript")

    let h = Harness()
    let core = start(h)
    #expect(try await ready(h))
    let wall = try await open(h, "wall", mock.base + "/wall/")
    #expect(try await until(90) { core.consentResults["wall"] != nil }, "\(core.consentResults)")
    #expect(result(core, "wall")?.result == "open")
    #expect(await accepted(wall) == false)
    #expect((try? await wall.callAsyncJavaScript("return !!document.getElementById('sp_message_container_1')", contentWorld: .page)) as? Bool == true)

    // An answer from an earlier visit: nothing clicked, reported as answered. (Cookies are per host,
    // not port: an earlier test's OneTrust answer on 127.0.0.1 goes first.)
    let store = wall.configuration.websiteDataStore.httpCookieStore
    for c in await store.allCookies() where c.name.hasPrefix("Optanon") { await store.deleteCookie(c) }
    let ot = try await open(h, "ot", mock.base + "/ot/")
    #expect(try await until(60) { core.consentResults["ot"] != nil })
    #expect(result(core, "ot")?.result == "rejected")
    core.consentResults["ot"] = nil
    ot.reload()
    #expect(try await until(60) { core.consentResults["ot"] != nil })
    #expect(result(core, "ot")?.result == "answered")

    // Off for the site: the detection list and frame script leave its rule, nothing is injected.
    #expect(h.rt.call("shields", "site", ["host": "127.0.0.1", "consent": false]).isError == false)
    #expect(h.storage("shields", "sites")["127.0.0.1"]["consent"] == false)
    #expect(!h.rt.sitePolicy.rule(for: "127.0.0.1").lists.contains(Consent.list))
    #expect(!h.rt.sitePolicy.rule(for: "127.0.0.1").scripts.contains(Consent.frames))
    #expect(core.handle("get", ["host": "127.0.0.1"])["consent"] == false)
    core.consentResults = [:]
    h.rt.host.emit("sitepolicy.notified", ["id": "ot", "notification": "consent:onetrust", "blocked": false])
    try await Task.sleep(for: .seconds(2))
    #expect(core.consentResults["ot"] == nil)
    // A load another list blocked isn't answered either.
    h.rt.call("shields", "site", ["host": "127.0.0.1", "consent": true])
    h.rt.host.emit("sitepolicy.notified", ["id": "wall", "notification": "consent:sourcepoint", "blocked": true])
    try await Task.sleep(for: .seconds(1))
    #expect(core.consentResults["wall"] == nil)

    // The command toggles the current site; the global switch in Settings.
    #expect(Self.commandTitles.contains("Reject Cookie Consent on This Site: On/Off"))
    h.rt.call("settings", "set", ["id": "shields", "key": "consent", "value": false])
    #expect(!h.rt.sitePolicy.defaultRule.lists.contains(Consent.list))
    #expect(!h.rt.sitePolicy.defaultRule.scripts.contains(Consent.frames))
    h.rt.call("settings", "set", ["id": "shields", "key": "consent", "value": true])
    #expect(h.rt.sitePolicy.defaultRule.lists.contains(Consent.list))
    core.stop()
  }

  static var commandTitles: [String] { ShieldsCore.commands.map { $0.1 } }
}
