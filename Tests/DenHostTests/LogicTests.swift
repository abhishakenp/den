import CordisValue
import CoreGraphics
import Foundation
import DenTestSupport
import Testing

@testable import DenHost
import PluginCores

@Suite(.watchdog)
struct LogicTests {
  @Test func themeParsesAndClamps() {
    let t = Theme(["colors": ["#ff0000", "0f0", "#0000ff", "#ffffff"], "intensity": 2.0, "grain": -1, "appearance": "dark"])
    #expect(t.colors.count == 3)
    #expect(t.colors[1] == RGB(0, 1, 0))
    #expect(t.intensity == 1 && t.grain == 0 && t.appearance == .dark)
    #expect(Theme(.null).colors.isEmpty)
    #expect(Theme(.null).stops(dark: false).count == 2)
    let a = Theme(colors: [RGB(0, 0, 0)]), b = Theme(colors: [RGB(1, 1, 1)])
    #expect(a.interpolated(to: b, 0.5).colors[0] == RGB(0.5, 0.5, 0.5))
  }

  @Test func chordsParse() {
    #expect(Chord.parse("cmd+t") == Chord(mods: [.cmd], key: "t"))
    #expect(Chord.parse("Cmd+Shift+K") == Chord(mods: [.cmd, .shift], key: "k"))
    #expect(Chord.parse("ctrl+1") == Chord(mods: [.ctrl], key: "1"))
    #expect(Chord.parse("cmd+opt+left")?.key == "\u{F702}")
    #expect(Chord.parse("ctrl+shift+=")?.key == "=")
    #expect(Chord.parse("hyper+x") == nil)
  }

  @Test func linkPolicyRoutesCrossSiteClicks() {
    let rules = [LinkRule(when: .crossSite, event: "peek.open")]
    let src = URL(string: "https://mail.google.com/inbox")
    func route(_ t: String, click: Bool = true, main: Bool = true, mods: Set<Chord.Mod> = []) -> String? {
      LinkPolicy.route(rules: rules, source: src, target: URL(string: t)!, isLinkClick: click, isMainFrame: main, modifiers: mods)
    }
    #expect(route("https://github.com/x") == "peek.open")
    #expect(route("https://docs.google.com/x") == nil)  // same site
    #expect(route("https://github.com/x", click: false) == nil)
    #expect(route("https://github.com/x", main: false) == nil)
    #expect(route("https://github.com/x", mods: [.cmd]) == nil)
    #expect(route("mailto:a@b.c") == nil)
    #expect(LinkPolicy.site("a.b.bbc.co.uk") == "bbc.co.uk")
    let hostRule = [LinkRule(when: .any, hosts: ["youtube.com"], event: "yt")]
    #expect(LinkPolicy.route(rules: hostRule, source: src, target: URL(string: "https://m.youtube.com/w")!, isLinkClick: true, isMainFrame: true, modifiers: []) == "yt")
    #expect(LinkRule(["when": "sameSite", "event": "e", "modifiers": ["cmd"]]) == LinkRule(when: .sameSite, modifiers: [.cmd], event: "e"))
  }

  @Test func splitLayoutFrames() {
    let b = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let h = SplitLayout.frames(count: 2, orientation: .horizontal, in: b, gap: 10)
    #expect(h == [CGRect(x: 0, y: 0, width: 495, height: 600), CGRect(x: 505, y: 0, width: 495, height: 600)])
    let v = SplitLayout.frames(count: 3, orientation: .vertical, in: b, gap: 0)
    #expect(v.count == 3 && v[2].maxY == 600)
    let g = SplitLayout.frames(count: 4, orientation: .grid, in: b, gap: 10)
    #expect(g.count == 4 && g[0].width == 495 && g[0].height == 295)
    let g3 = SplitLayout.frames(count: 3, orientation: .grid, in: b, gap: 10)
    #expect(g3[0].height == 600 && g3[1].height == 295)
    #expect(SplitLayout.frames(count: 1, orientation: .grid, in: b, gap: 10) == [b])
    // A 3–4 pane grid takes two column ratios.
    let gr = SplitLayout.frames(count: 3, orientation: .grid, in: b, gap: 10, ratios: [0.3, 0.7])
    #expect(gr[0].width == 297 && gr[1].minX == 307 && gr[1].maxX == 1000)
  }

  /// Dragging the gap between split panes: one divider per gap (the column gap for a grid), the
  /// two panes beside it share their size, neither below the minimum.
  @Test func splitDividersResizeTheirNeighbours() {
    let b = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let d2 = SplitLayout.dividers(count: 2, orientation: .horizontal, in: b, gap: 10)
    #expect(d2.count == 1 && d2[0].alongX && d2[0].rect == CGRect(x: 495, y: 0, width: 10, height: 600))
    let dv = SplitLayout.dividers(count: 3, orientation: .vertical, in: b, gap: 10)
    #expect(dv.count == 2 && !dv[0].alongX && dv[0].rect.width == 1000 && dv[0].rect.height == 10)
    #expect(SplitLayout.dividers(count: 4, orientation: .grid, in: b, gap: 10).count == 1)
    #expect(SplitLayout.dividers(count: 1, orientation: .horizontal, in: b, gap: 10).isEmpty)
    // Drag the middle of two halves to x = 300 (the gap's centre): the left pane is 295 wide.
    let r = SplitLayout.dragged(count: 2, orientation: .horizontal, in: b, gap: 10, ratios: [], divider: 0, to: CGPoint(x: 300, y: 50), minPane: 200)
    let f = SplitLayout.frames(count: 2, orientation: .horizontal, in: b, gap: 10, ratios: r)
    #expect(abs(r.reduce(0, +) - 1) < 0.0001)
    #expect(f[0].width == 295 && f[1].minX == 305)
    // Never below the minimum, on either side.
    let lo = SplitLayout.dragged(count: 2, orientation: .horizontal, in: b, gap: 10, ratios: [], divider: 0, to: CGPoint(x: 5, y: 0), minPane: 200)
    #expect(SplitLayout.frames(count: 2, orientation: .horizontal, in: b, gap: 10, ratios: lo)[0].width == 200)
    let hi = SplitLayout.dragged(count: 2, orientation: .horizontal, in: b, gap: 10, ratios: [], divider: 0, to: CGPoint(x: 990, y: 0), minPane: 200)
    #expect(SplitLayout.frames(count: 2, orientation: .horizontal, in: b, gap: 10, ratios: hi)[1].width == 200)
    // Three panes top to bottom: the second gap moves only the second and third panes.
    let v = SplitLayout.dragged(count: 3, orientation: .vertical, in: b, gap: 0, ratios: [], divider: 1, to: CGPoint(x: 0, y: 500), minPane: 50)
    let fv = SplitLayout.frames(count: 3, orientation: .vertical, in: b, gap: 0, ratios: v)
    #expect(fv[0].height == 200 && fv[1].height == 300 && fv[2].height == 100)
    // A grid resizes its columns.
    let g = SplitLayout.dragged(count: 4, orientation: .grid, in: b, gap: 10, ratios: [], divider: 0, to: CGPoint(x: 705, y: 0), minPane: 200)
    #expect(g.count == 2 && SplitLayout.frames(count: 4, orientation: .grid, in: b, gap: 10, ratios: g)[0].width == 700)
  }

  @Test func siteTileDerivesFromTheDomain() {
    // FNV-1a hash -> hue: fixed values, so a tile keeps its color across launches.
    #expect(Sites.hue("example.com") == CGFloat(278) / 360)
    #expect(Sites.hue("news.ycombinator.com") == CGFloat(62) / 360)
    #expect(Sites.hue("www.Example.com") == Sites.hue("example.com"))
    #expect(Sites.hue("swift.org") != Sites.hue("github.com"))
    #expect(Sites.letter("www.github.com") == "G")
    #expect(Sites.letter("") == "")
    #expect(Sites.domain("https://www.GitHub.com/x") == "github.com")
    #expect(Sites.domain("data:text/html,x") == "" && Sites.domain("about:blank") == "" && Sites.domain("file:///a") == "")
    #expect(Sites.domain(ofIcon: "https://www.google.com/s2/favicons?domain=swift.org&sz=64") == "swift.org")
    #expect(Sites.domain(ofIcon: "https://www.google.com/s2/favicons?domain=data&sz=64") == "")
    #expect(Sites.domain(ofIcon: "https://cdn.site.io/favicon.ico") == "cdn.site.io")
    #expect(Sites.label("file:///Users/me/a%20b.pdf") == "a b.pdf")
    #expect(Sites.label("data:text/html,x") == "")
  }
}
