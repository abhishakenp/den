import AppKit
import CordisValue
import Foundation
import Testing

@testable import DenHost

/// The theme-token layer: derived from the space theme, contrast-enforced, cached, and used by
/// every surface (dialogs, command bar, toasts, hover cards, popovers, Settings).
@MainActor
@Suite(.serialized)
struct ThemeTokenTests {
  /// The themes the user asked about, plus extremes: sandy/grainy, deep purple, near-black, pastel.
  static let themes: [(String, Theme)] = [
    ("sandy", Theme(colors: ["#E8D5B0", "#D9BF8C"].compactMap(RGB.init(hex:)), intensity: 0.75, grain: 0.8)),
    ("purple", Theme(colors: ["#4B2A7B", "#2D1B4E"].compactMap(RGB.init(hex:)), intensity: 0.85, grain: 0.2)),
    ("nearBlack", Theme(colors: ["#141414", "#0A0A0A"].compactMap(RGB.init(hex:)), intensity: 1, grain: 0.1)),
    ("pastel", Theme(colors: ["#FBEAF3", "#E0F2FB"].compactMap(RGB.init(hex:)), intensity: 0.6, grain: 0.3)),
    ("white", Theme(colors: [RGB(1, 1, 1)], intensity: 1, grain: 0)),
    ("yellow", Theme(colors: ["#FFE600"].compactMap(RGB.init(hex:)), intensity: 1, grain: 0)),
    ("none", Theme()),
  ]

  @Test func contrastMathMatchesWCAG() {
    #expect(abs(RGB(0, 0, 0).contrast(RGB(1, 1, 1)) - 21) < 0.01)
    #expect(abs(RGB(1, 1, 1).contrast(RGB(1, 1, 1)) - 1) < 0.001)
    // #767676 on white is the classic 4.54:1.
    #expect(abs(RGB(hex: "#767676")!.contrast(RGB(1, 1, 1)) - 4.54) < 0.02)
    #expect(ThemeTokens.ensure(RGB(0.8, 0.8, 0.8), on: RGB(1, 1, 1), 4.5).contrast(RGB(1, 1, 1)) >= 4.5)
    let h = RGB(hex: "#3139fb")!.hsb
    let back = RGB(hue: h.h, saturation: h.s, brightness: h.v)
    #expect(abs(back.r - RGB(hex: "#3139fb")!.r) < 0.002 && abs(back.b - RGB(hex: "#3139fb")!.b) < 0.002)
  }

  @Test func everyThemeMeetsItsContrastTargetsInBothAppearances() {
    for (name, theme) in Self.themes {
      for dark in [false, true] {
        let t = ThemeTokens.make(theme: theme, dark: dark)
        let tag = "\(name) \(dark ? "dark" : "light")"
        #expect(t.textPrimary.contrast(t.surface) >= 7, "\(tag) primary \(t.textPrimary.contrast(t.surface))")
        #expect(t.textSecondary.contrast(t.surface) >= 4.5, "\(tag) secondary")
        #expect(t.textTertiary.contrast(t.surface) >= 3, "\(tag) tertiary")
        #expect(t.textPrimary.contrast(t.elevated) >= 4.5, "\(tag) primary on elevated")
        #expect(t.onAccent.contrast(t.accent) >= 4.5, "\(tag) onAccent \(t.onAccent.contrast(t.accent))")
        #expect(t.accent.contrast(t.surface) >= (dark ? 1.8 : 3), "\(tag) accent vs surface \(t.accent.contrast(t.surface))")
        #expect(t.onDestructive.contrast(t.destructive) >= 4.5, "\(tag) destructive")
        #expect(t.onToast.contrast(t.toast) >= 4.5, "\(tag) toast")
        for stop in theme.stops(dark: dark) {
          #expect(t.sidebarText.contrast(stop) >= 4.5, "\(tag) sidebar text")
          #expect(t.sidebarSecondary.contrast(stop) >= 3, "\(tag) sidebar secondary")
        }
        // Light stays light and dark stays dark, whatever the theme.
        #expect(dark ? t.surface.relativeLuminance <= 0.04 : t.surface.relativeLuminance >= 0.7, "\(tag) surface luminance")
      }
    }
  }

  @Test func surfacesAreTintedByTheSpaceAndCached() {
    let sandy = ThemeTokens.make(theme: Self.themes[0].1, dark: false)
    let none = ThemeTokens.make(theme: Theme(), dark: false)
    // A sandy space gets a warm (red > blue) surface; no theme keeps Arc's cool #FAFBFF.
    #expect(sandy.surface.r > sandy.surface.b + 0.03)
    #expect(none.surface == RGB(0xFA / 255, 0xFB / 255, 1))
    // The purple space's accent keeps its hue.
    let purple = ThemeTokens.make(theme: Self.themes[1].1, dark: true)
    #expect(abs(purple.accent.hsb.h - RGB(hex: "#4B2A7B")!.hsb.h) < 0.03)
    #expect(sandy.grain > 0 && ThemeTokens.make(theme: Self.themes[4].1, dark: false).grain == 0)
    // The same inputs give the same tokens (cached).
    #expect(ThemeTokens.make(theme: Self.themes[0].1, dark: false) == sandy)
    // The system accent replaces the theme's when chosen.
    let sys = ThemeTokens.make(theme: Self.themes[0].1, dark: false, systemAccent: RGB(0, 0.48, 1))
    #expect(abs(sys.accent.hsb.h - RGB(0, 0.48, 1).hsb.h) < 0.02)
  }

  @Test func renderedSurfacesUseTheTokensAndUpdateLive() throws {
    let rt = ServiceTests.runtime()
    rt.window.window.orderFront(nil)
    func setTheme(_ t: Theme, _ appearance: String) {
      rt.call("window", "setTheme", ["colors": .array(t.colors.map { .string($0.hex) }), "intensity": .double(Double(t.intensity)),
                                     "grain": .double(Double(t.grain)), "appearance": .string(appearance)])
    }
    setTheme(Self.themes[0].1, "light")
    rt.call("ui", "set", ["slot": "dialog", "tree": ["type": "dialog", "id": "js", "title": "example.com says", "message": "Your changes were saved",
                                                    "buttons": [["id": "cancel", "title": "Cancel", "style": "cancel"], ["id": "ok", "title": "OK", "style": "default"]]]])
    rt.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": "Saved"]])
    let d = rt.ui.dialog
    func rgb(_ c: NSColor?) -> RGB { let s = (c ?? .clear).usingColorSpace(.sRGB)!; return RGB(s.redComponent, s.greenComponent, s.blueComponent) }
    func bg(_ l: CALayer?) -> RGB { rgb(l?.backgroundColor.flatMap { NSColor(cgColor: $0) }) }
    var t = rt.ui.renderer.palette.tokens
    #expect(bg(d.surface.layer) == t.surface)
    #expect(rgb(d.title.textColor) == t.textPrimary && rgb(d.message.textColor) == t.textSecondary)
    let ok = try #require(d.buttons.first { $0.style == "default" })
    #expect(rgb(ok.fill) == t.accent && rgb(ok.label.textColor) == t.onAccent)
    #expect(rgb(ok.label.textColor).contrast(rgb(ok.fill)) >= 4.5)
    let cancel = try #require(d.buttons.first { $0.style == "cancel" })
    #expect(rgb(cancel.label.textColor).contrast(rgb(cancel.fill)) >= 4.5)
    // The sandy theme has grain: the dialog surface carries it.
    #expect(d.surface.layer?.sublayers?.contains { $0.name == SurfaceGrain.layerName } == true)
    // Switch the space theme: the open dialog and the toast follow at once.
    setTheme(Self.themes[1].1, "dark")
    t = rt.ui.renderer.palette.tokens
    #expect(t.dark && bg(d.surface.layer) == t.surface && rgb(d.title.textColor) == t.textPrimary && rgb(ok.fill) == t.accent)
    #expect(rt.ui.toasts.allSatisfy { bg($0.layer) == t.toast })
    // Same theme again: nothing is re-applied (tokens unchanged).
    var applied = 0
    rt.ui.onPalette = { _ in applied += 1 }
    setTheme(Self.themes[1].1, "dark")
    #expect(applied == 0)
    setTheme(Self.themes[2].1, "dark")
    #expect(applied == 1)
  }
}
