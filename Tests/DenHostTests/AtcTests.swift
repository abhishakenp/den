import CordisValue
import Foundation
import Testing
@testable import DenHost

/// Tests for ATC (Air Traffic Control) — per-site link routing from config.toml.
@Suite(.serialized)
struct AtcTests {

  // MARK: - Parsing

  @Test func parsesEmptyAtcFromNullValue() {
    let atc = ATC(nil)
    #expect(atc == nil)
  }

  @Test func parsesEmptyAtcFromEmptyMap() {
    let atc = ATC(.map([:]))
    #expect(atc?.rules.isEmpty ?? false)
  }

  @Test func parsesRulesFromAtcValue() {
    let rulesArr: Value = .array([
      .map(["url_pattern": .string(".*\\.pdf"),
            "hosts": .array([.string("github.com")]),
            "action": .string("newTab"),
            "when": .string("crossSite"),
            "modifiers": .array([.string("cmd")])]),
      .map(["url_pattern": .string(".*\\.png|.*\\.jpg"),
            "hosts": .array([.string("cdn.example.com")]),
            "action": .string("peek")])
    ])
    let atcV = Value.map(["rules": rulesArr])
    let atc = ATC(atcV)
    #expect(atc != nil)
    #expect(atc!.rules.count == 2)
    #expect(atc!.rules[0].urlPattern == ".*\\.pdf")
    #expect(atc!.rules[0].hosts == ["github.com"])
    #expect(atc!.rules[0].action == .newTab)
    #expect(atc!.rules[0].when == .crossSite)
    #expect(atc!.rules[1].urlPattern == ".*\\.png|.*\\.jpg")
    #expect(atc!.rules[1].hosts == ["cdn.example.com"])
    #expect(atc!.rules[1].action == .peek)
  }

  @Test func parsesDefaultAction() {
    let atcV = Value.map(["default_action": .string("split")])
    let atc = ATC(atcV)
    #expect(atc?.defaultAction == .split)
  }

  @Test func fallbacksToNewTabForBadAction() {
    let rulesArr: Value = .array([
      .map(["url_pattern": .string("test"), "action": .string("nonexistent")])
    ])
    let atcV = Value.map(["rules": rulesArr])
    let atc = ATC(atcV)
    #expect(atc?.rules.first?.action == .newTab)
  }

  @Test func skipsRulesWithEmptyUrlPattern() {
    let rulesArr: Value = .array([
      .map(["url_pattern": .string(""), "action": .string("newTab")])
    ])
    let atcV = Value.map(["rules": rulesArr])
    let atc = ATC(atcV)
    #expect(atc?.rules.isEmpty ?? true)
  }

  // MARK: - ATCMod

  @Test func atcModChordMapping() {
    #expect(ATCMod.cmd.chords == [.cmd])
    #expect(ATCMod.shift.chords == [.shift])
    #expect(ATCMod.opt.chords == [.opt])
    #expect(ATCMod.ctrl.chords == [.ctrl])
    #expect(ATCMod.cmdShift.chords == [.cmd, .shift])
    #expect(ATCMod.cmdOpt.chords == [.cmd, .opt])
    #expect(ATCMod.shiftOpt.chords == [.shift, .opt])
  }

  // MARK: - decide()

  @Test func noRulesReturnsNil() {
    let atc = ATC()
    let target = URL(string: "https://example.com/path")!
    #expect(atc.decide(source: nil, target: target, isLinkClick: true, isMainFrame: true, modifiers: []) == nil)
  }

  @Test func notLinkClickReturnsNil() {
    let atc = ATC(rules: [ATCRule(urlPattern: ".*", action: .newTab)])
    let target = URL(string: "https://example.com/path")!
    #expect(atc.decide(source: nil, target: target, isLinkClick: false, isMainFrame: true, modifiers: []) == nil)
  }

  @Test func notMainFrameReturnsNil() {
    let atc = ATC(rules: [ATCRule(urlPattern: ".*", action: .newTab)])
    let target = URL(string: "https://example.com/path")!
    #expect(atc.decide(source: nil, target: target, isLinkClick: true, isMainFrame: false, modifiers: []) == nil)
  }

  @Test func nonHttpSchemeReturnsNil() {
    let atc = ATC(rules: [ATCRule(urlPattern: ".*", action: .newTab)])
    let target = URL(string: "mailto:test@example.com")!
    #expect(atc.decide(source: nil, target: target, isLinkClick: true, isMainFrame: true, modifiers: []) == nil)
  }

  @Test func ruleMatchesWithoutHostFilter() {
    let atc = ATC(rules: [ATCRule(urlPattern: "example\\.com", action: .newTab)])
    let target = URL(string: "https://example.com/page")!
    let result = atc.decide(source: URL(string: "https://other.com"), target: target, isLinkClick: true, isMainFrame: true, modifiers: [])
    #expect(result != nil)
    #expect(result!.event == "atc.newTab")
    #expect(result!.payload["url"]?.string == "https://example.com/page")
  }

  @Test func ruleMatchesWithHostFilter() {
    let atc = ATC(rules: [ATCRule(hosts: ["github.com"], urlPattern: "pull/.*", action: .split)])
    let target = URL(string: "https://github.com/owner/repo/pull/123")!
    let result = atc.decide(source: nil, target: target, isLinkClick: true, isMainFrame: true, modifiers: [])
    #expect(result != nil)
    #expect(result!.event == "atc.split")
  }

  @Test func ruleDoesNotMatchNonMatchingHost() {
    let atc = ATC(rules: [ATCRule(hosts: ["github.com"], urlPattern: ".*", action: .newTab)])
    let target = URL(string: "https://example.com/page")!
    #expect(atc.decide(source: nil, target: target, isLinkClick: true, isMainFrame: true, modifiers: []) == nil)
  }

  @Test func ruleDoesNotMatchNonMatchingUrl() {
    let atc = ATC(rules: [ATCRule(hosts: ["github.com"], urlPattern: "issue/.*", action: .split)])
    let target = URL(string: "https://github.com/owner/repo/pull/123")!
    #expect(atc.decide(source: nil, target: target, isLinkClick: true, isMainFrame: true, modifiers: []) == nil)
  }

  @Test func crossSiteWhenRequiresDifferentHosts() {
    let atc = ATC(rules: [
      ATCRule(hosts: ["github.com"], urlPattern: ".*", action: .split, when: .crossSite)
    ])
    let target = URL(string: "https://github.com/owner/repo/pull/1")!
    #expect(atc.decide(source: target, target: target, isLinkClick: true, isMainFrame: true, modifiers: []) == nil)

    let source = URL(string: "https://google.com")!
    let result = atc.decide(source: source, target: target, isLinkClick: true, isMainFrame: true, modifiers: [])
    #expect(result != nil)
  }

  @Test func sameSiteWhenRequiresSameHost() {
    let atc = ATC(rules: [
      ATCRule(hosts: ["github.com"], urlPattern: ".*", action: .split, when: .sameSite)
    ])
    let target = URL(string: "https://github.com/owner/repo")!
    let result = atc.decide(source: URL(string: "https://github.com/owner/repo/old"), target: target, isLinkClick: true, isMainFrame: true, modifiers: [])
    #expect(result != nil)

    #expect(atc.decide(source: URL(string: "https://example.com"), target: target, isLinkClick: true, isMainFrame: true, modifiers: []) == nil)
  }

  @Test func modifierRequired() {
    let atc = ATC(rules: [
      ATCRule(hosts: ["github.com"], urlPattern: ".*", action: .newTab, modifiers: [.cmd])
    ])
    let target = URL(string: "https://github.com/owner/repo")!

    #expect(atc.decide(source: nil, target: target, isLinkClick: true, isMainFrame: true, modifiers: []) == nil)

    var mods = Set<Chord.Mod>()
    mods.insert(.cmd)
    let result = atc.decide(source: nil, target: target, isLinkClick: true, isMainFrame: true, modifiers: mods)
    #expect(result != nil)
    #expect(result!.event == "atc.newTab")
  }

  @Test func wildcardHostMatch() {
    let atc = ATC(rules: [
      ATCRule(hosts: ["example.com"], urlPattern: ".*", action: .newTab)
    ])
    let target = URL(string: "https://docs.example.com/page")!
    let result = atc.decide(source: nil, target: target, isLinkClick: true, isMainFrame: true, modifiers: [])
    #expect(result != nil)
  }

  @Test func multipleRulesFirstMatchWins() {
    let atc = ATC(rules: [
      ATCRule(urlPattern: ".*", action: .newTab),
      ATCRule(urlPattern: ".*", action: .split)
    ])
    let target = URL(string: "https://example.com")!
    let result = atc.decide(source: nil, target: target, isLinkClick: true, isMainFrame: true, modifiers: [])
    #expect(result?.event == "atc.newTab")
  }

  @Test func passesPayloadWithData() {
    let atc = ATC(rules: [ATCRule(urlPattern: ".*", action: .peek)])
    let source = URL(string: "https://example.com")!
    let target = URL(string: "https://cdn.example.com/img.png")!
    let result = atc.decide(source: source, target: target, isLinkClick: true, isMainFrame: true, modifiers: [])
    #expect(result != nil)
    #expect(result!.payload["url"]?.string == "https://cdn.example.com/img.png")
    #expect(result!.payload["source"]?.string == "https://example.com")
    #expect(result!.payload["rule_hosts"]?.array?.isEmpty ?? true)
  }
}
