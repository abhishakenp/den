# den — Dark mode for every website: options, cost, Apple Pay

> Research snapshot, 2026-09-27. Decisions made later are in [ROADMAP.md](../../ROADMAP.md) / [FEATURES.md](../FEATURES.md).

Researched and measured 2026-09-27 on macOS 26.5 (WebKit 21624.2.5.11.4), a heavily loaded machine (load average 260–500 during the runs; other agents were compiling). Implementation: [`pagestyle`](../host-api.md#pagestyle) + [`darkmode`](../plugin-services.md#darkmode-plugin-darkmode).

## Options

| Option | Verdict |
|---|---|
| Follow den's appearance (`prefers-color-scheme`) | **Always on.** Web views inherit the window's `NSAppearance`; checked in a probe (`matchMedia('(prefers-color-scheme: dark)')` is true under `.darkAqua`) and in `DarkModeTests`. github.com and accounts.google.com render their own dark themes. Free. |
| `color-scheme: dark` forced by a user sheet | Only changes UA defaults (form controls, the canvas). Nearly every site sets its own white background, so it darkens almost nothing. Rejected. |
| Dark Reader "dynamic" (walk every stylesheet and element, rewrite colors in JS) | Best-looking, but a script that parses every stylesheet and watches the DOM on every page. Against den's cost budget. Rejected. |
| **Root filter**: `html { filter: invert(1) hue-rotate(180deg) }`, media inverted back | **Chosen.** One declarative user stylesheet, no script on the hot path, applied before the first paint. Keeps photos and video in their real colors, keeps hues (links stay blue). The root element is exempt from the "filter creates a containing block" rule, so `position: fixed` keeps working. |

**What den adds:** a tone detector, so pages that are already dark aren't inverted, and a cache of natively dark hosts, so their next visit carries no sheet at all.

Delivery: WebKit's user stylesheet SPI `_WKUserStyleSheet` (`initWithSource:forMainFrameOnly:`, `-[WKUserContentController _addUserStyleSheet:]` / `_removeUserStyleSheet:`), present since macOS 10.12. It was checked on 26.5 in a probe (an `html{background:rgb(1,2,3)!important}` sheet gave a computed `rgb(1, 2, 3)`). No public API adds CSS without a script.

## Cost (measured)

Bench: `scratchpad/probe/bench.swift`, an on-screen 1200x800 WKWebView with the same sheet and detector. Page: en.wikipedia.org/wiki/List_of_cat_breeds, 18,130 px tall and image-heavy. Runs were interleaved: none / root filter only / full sheet. Each run measured the WebContent footprint (`footprint <pid>`) after load plus 2.5 s, and rAF frame deltas while scrolling 60 px per frame for 180 frames.

| Variant | Footprint (3 runs) | Mean frame | p95 frame |
|---|---|---|---|
| none | 468, 501, 534 MB (mean 501) | 33.3–34.3 ms | 34–49 ms |
| root filter only | 483, 622, 573 MB (mean 559) | 33.3–35.9 ms | 35–49 ms |
| full sheet (root + media re-invert) | 638, 659, 613 MB (mean 637) | 33.5–35.6 ms | 45–60 ms |

An earlier 4-run A/B (none vs full sheet) gave 501/456/492/389 MB vs 645/596/612 MB.

- **Memory:** the full sheet costs about +136 MB on this 300-image page: about +58 MB for the root filter and +78 MB for re-inverting the images. That cost scales with the number of media elements. It's why natively dark sites get no sheet at all, and why the sheet is keyed off when the tone is dark.
- **Frames:** the means stay at ~33 ms with or without the sheet. The machine held rAF at 30 Hz under that load, so this shows no regression, not headroom. p95 rose by ~10 ms with the full sheet. Re-measure on an idle machine before optimizing further.
- **Layout:** none. `filter` doesn't affect layout (identical `scrollHeight` with and without the sheet). FCP numbers varied 202–1610 ms from network and load noise, with no consistent difference.
- **Launch:** the `darkmode` plugin's `apply` defines two sheets and one rule table (no WebKit objects). Sheets and the detector attach to web views, which are created after the first frame. See the launch numbers in the commit message.

## Snapshots (real app, `--scenario page --url <url> --appearance dark|light`)

- example.com and news.ycombinator.com, dark: inverted to near-black with light text. HN's orange header keeps its hue. Light: untouched.
- github.com and accounts.google.com, dark: their own dark themes. The detector says `dark`, so there's no filter.
- en.wikipedia.org/wiki/Cat, dark: the article is inverted and the cat photos keep their real colors.

## Apple Pay

- The rule that Apple Pay "cannot be used alongside script injection APIs" ([WebKit bug 197751](https://bugs.webkit.org/show_bug.cgi?id=197751)) was removed from WebKit in 2022. The commit is `aa041a623c`, "Permit simultaneous Apple Pay and script injection" ([bug 236254](https://bugs.webkit.org/show_bug.cgi?id=236254)). It deleted `Document::hasEvaluatedUserAgentScripts`, `isApplePayActive`, `ScriptController::shouldAllowUserAgentScripts` and `PaymentCoordinator::shouldAllowUserAgentScripts`.
- On main, `PaymentSession::canCreateSession` (`Source/WebCore/Modules/applepay/PaymentSession.cpp`) checks only the `payment` permissions policy, a secure frame and secure ancestors. WebKit's API tests `UserScriptAtDocumentStartDoesNotDisableApplePay` and `UserAgentScriptEvaluationDoesNotDisableApplePay` (`Tools/TestWebKitAPI/Tests/WebKit/WKWebView/ApplePay.mm`) cover this.
- User stylesheets never set `Page::setHasInjectedUserScript` anyway, and that flag no longer affects payments.
- **So den doesn't skip checkout pages.** Neither dark mode's sheet and detector nor den's other scripts (media, favicon, vault) disable Apple Pay, per source.
- **Not tested end to end:** in a plain WKWebView on this machine, `typeof ApplePaySession` is `undefined` (probe, https origin). That's likely an entitlement/merchant gate for non-Safari apps (**UNVERIFIED**). There was no way to exercise a real Apple Pay sheet. Which OS release first shipped `aa041a623c` is **UNVERIFIED**; it's well before macOS 26.
