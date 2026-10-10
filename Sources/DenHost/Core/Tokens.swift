import CoreGraphics
import Foundation
import PluginCores

/// Every visual constant of den's chrome lives here, so estimates can be swapped for values
/// measured on a real Arc build (docs/reference/arc-ui-spec.md) in one place.
/// `// spec` = measured on Arc 1.166.0, see docs/reference/arc-ui-spec.md (section noted).
/// `// estimate` = not measured (UNVERIFIED in the spec); taken from taste or third-party write-ups.
public enum Tokens {
  // MARK: Window / content card
  public static let windowMinSize = CGSize(width: 640, height: 420)  // estimate
  public static let windowDefaultSize = CGSize(width: 1280, height: 820)  // estimate
  public static let cardInset: CGFloat = 10  // spec §1: top/right/bottom 10, left flush to the sidebar; 10 all round when hidden
  public static let cardCornerRadius: CGFloat = 6  // spec §1
  public static let cardShadowOpacity: Float = 0.14  // estimate
  public static let cardShadowRadius: CGFloat = 3  // estimate
  public static let cardShadowOffsetY: CGFloat = -1  // estimate (AppKit y-up)
  public static let cardBorderOpacity: CGFloat = 0.06  // estimate: hairline around the card
  public static let splitGap: CGFloat = 8  // estimate
  public static let splitFocusRingWidth: CGFloat = 2  // estimate (Arc's split chrome is UNVERIFIED, spec §12)
  public static let splitFocusRingOutset: CGFloat = 2  // estimate: ring drawn in the gap, outside the card
  public static let splitControlsHeight: CGFloat = 30  // estimate
  public static let splitControlsTop: CGFloat = 8  // estimate
  public static let splitMinPane: CGFloat = 200  // estimate: narrowest a drag leaves a split pane
  public static let splitDividerSlop: CGFloat = 3  // estimate: the drag area reaches this far over each pane's edge
  public static let splitHandleLength: CGFloat = 36  // estimate: the grip shown in the gap on hover
  public static let splitHandleThickness: CGFloat = 4  // estimate
  public static let dropZoneFillAlpha: CGFloat = 0.18  // estimate: theme-tinted drop indicator over the content
  public static let dropZoneBorderWidth: CGFloat = 2  // estimate

  // MARK: Sidebar
  public static let sidebarDefaultWidth: CGFloat = 228  // spec §1
  public static let sidebarMinWidth: CGFloat = 180  // estimate
  public static let sidebarMaxWidth: CGFloat = 420  // estimate
  public static let sidebarCollapseDragWidth: CGFloat = 120  // estimate: dragging below this hides the sidebar
  public static let sidebarResizeHandleWidth: CGFloat = 8  // estimate
  public static let sidebarPadding: CGFloat = 8  // estimate: horizontal padding inside the sidebar
  public static let sidebarHoverRevealZone: CGFloat = 8  // estimate: screen-edge hot zone when hidden
  public static let sidebarOverlayCornerRadius: CGFloat = 10  // estimate
  public static let sidebarOverlayInset: CGFloat = 6  // estimate
  public static let sidebarSectionSpacing: CGFloat = 10  // estimate

  // MARK: Traffic lights + header
  public static let trafficLightXs: [CGFloat] = [12, 35, 58]  // spec §1: left edges of the 16 pt buttons
  public static let trafficLightTop: CGFloat = 16  // spec §1: top edge, from window top
  public static let trafficLightSize: CGFloat = 16  // spec §1
  public static let navRowHeight: CGFloat = 46  // spec §1: URL pill starts at y = 46
  public static let navButtonSize: CGFloat = 32  // spec §1: toggle at (77,7), back/fwd/reload at x 122/156/190, y 7
  public static let urlPillHeight: CGFloat = 36  // spec §1: x 8–220, y 46–82
  public static let urlPillCornerRadius: CGFloat = 12  // spec §1
  public static let urlPillFontSize: CGFloat = 13  // spec §1 (derived from x-height)
  /// "Add to den" in the URL pill on a store item page (estimate: fits the 36 pt pill with 6 pt around).
  public static let urlPillStoreButtonHeight: CGFloat = 24
  public static let urlPillStoreButtonRadius: CGFloat = 8

  // MARK: Rows
  public static let tabRowHeight: CGFloat = 41  // spec §1: row pitch
  public static let tabRowCornerRadius: CGFloat = 12  // spec §1: selected highlight radius
  public static let tabRowSpacing: CGFloat = 0  // spec §1: the 41 pt pitch includes the gap
  public static let tabRowIconSize: CGFloat = 18  // spec §1: favicon 18x18 at x = 17
  public static let tabRowPaddingX: CGFloat = 9  // spec §1: favicon at x = 17 (8 sidebar padding + 9)
  public static let tabRowFontSize: CGFloat = 13.5  // spec §1 (derived from cap height)
  public static let folderIndent: CGFloat = 14  // estimate
  public static let groupCornerRadius: CGFloat = 12  // estimate: the row highlight's radius (Dia's group panel is "rounded", dia-ui-spec §6)
  public static let groupShimmerDuration: CFTimeInterval = 1.4  // estimate (Dia shows a skeleton, not a shimmer over text)
  public static let groupRevealDuration: CFTimeInterval = 0.4  // dia-ui-spec §6: the gradient sweep, about 0.4 s
  /// Longest the previous page stays on screen while a new one hasn't painted (den's choice:
  /// long enough for a warm page, short enough that a slow one shows its own progress).
  public static let paintHoldTimeout: TimeInterval = 1.0
  public static let dividerHeight: CGFloat = 24  // estimate (line itself: 0.5 pt, spec §1)
  public static let spaceTitleHeight: CGFloat = 38  // estimate (icon 26 at x 13, name at x 41: spec §1)

  // MARK: Favorites
  public static let favoriteColumns = 4  // estimate
  public static let favoriteTileHeight: CGFloat = 46  // estimate
  public static let favoriteTileCornerRadius: CGFloat = 10  // estimate
  public static let favoriteTileSpacing: CGFloat = 8  // estimate
  public static let favoriteIconSize: CGFloat = 20  // estimate
  /// Narrowest tile before a row takes one tile fewer: a narrow sidebar gets rows of 3, then 2,
  /// so the icon and the speaker badge never crowd each other (den's choice).
  public static let favoriteMinTileWidth: CGFloat = 44

  // MARK: Footer / space switcher
  public static let footerHeight: CGFloat = 50  // spec §1: switcher strip 144x50 at y 750 of 800
  public static let spaceIconSize: CGFloat = 26  // spec §1 (space title icon 26x26)
  public static let spaceDotSize: CGFloat = 6  // estimate
  /// Footer icon drag-reorder: the lifted icon's scale and the slide of its neighbours. Arc's
  /// values were never measured (spec §12); Dia's (0.2, 0.8, 0.2, 1) curve is used.
  public static let spaceIconLiftScale: CGFloat = 1.15  // estimate
  public static let spaceIconReorderDuration: CFTimeInterval = 0.2  // estimate

  // MARK: Icon picker (the space's "Change Space Icon…")
  public static let iconPickerWidth: CGFloat = 300  // den's own
  public static let iconPickerPadding: CGFloat = 14  // den's own
  public static let iconPickerCell: CGFloat = 32  // den's own (the 32 pt buttons of the theme picker, spec §4)
  public static let iconPickerColumns = 8
  public static let iconPickerRadius: CGFloat = 20  // matches the theme picker (spec §4)

  // MARK: Overlays
  public static let commandBarWidth: CGFloat = 766  // spec §2
  public static let commandBarTopRatio: CGFloat = 231.0 / 800.0  // spec §2: top y = 231 in an 800 pt window
  public static let commandBarCornerRadius: CGFloat = 15  // spec §2
  public static let commandBarInputHeight: CGFloat = 54  // estimate
  public static let commandBarInputFontSize: CGFloat = 18  // estimate
  public static let commandBarRowHeight: CGFloat = 50  // spec §2
  public static let commandBarMaxRows = 8  // estimate
  public static let commandBarRowInset: CGFloat = 7  // spec §2: rows inset 7 from the panel
  public static let commandBarHighlightInsetX: CGFloat = 10  // spec §2 (inside the row)
  public static let commandBarHighlightInsetY: CGFloat = 2  // spec §2
  public static let commandBarHighlightRadius: CGFloat = 6  // spec §2
  public static let peekInsetX: CGFloat = 56  // estimate: room for the button column on the right
  public static let peekInsetY: CGFloat = 40  // estimate
  public static let peekCornerRadius: CGFloat = 10  // estimate (Dia's web card radius is 10, spec §13)
  public static let peekBackdropAlpha: CGFloat = 0.25  // estimate
  public static let peekShadowRadius: CGFloat = 28  // estimate (Dia's web shadow is 0 8 28, spec §13)
  public static let peekShadowOpacity: Float = 0.35  // estimate
  public static let peekButtonSize = CGSize(width: 34, height: 33)  // spec §8: Little Arc side controls
  public static let peekButtonGap: CGFloat = 9  // estimate
  public static let peekOpenScale: CGFloat = 0.94  // estimate
  public static let peekOpenDuration: TimeInterval = 0.28  // estimate
  public static let peekCloseDuration: TimeInterval = 0.16  // estimate
  public static let dialogWidth: CGFloat = 450  // spec §5 (quit sheet 450x248)
  public static let dialogCornerRadius: CGFloat = 26.5  // spec §5
  public static let dialogPadding: CGFloat = 38  // spec §5: icon at (38,38), title at (38,117)
  public static let dialogIconSize: CGFloat = 62  // spec §5
  public static let dialogHeroIconSize: CGFloat = 76  // spec §5: dialog hero icons 76x76
  public static let dialogHeroGlyphSize: CGFloat = 36  // estimate
  public static let dialogButtonHeight: CGFloat = 38  // spec §5 (37–40)
  public static let dialogButtonGap: CGFloat = 7  // spec §5
  public static let dialogButtonInset: CGFloat = 27.5  // PX: button row 27.5 pt from the sides and bottom
  public static let dialogButtonCornerRadius: CGFloat = 6  // PX: rough fit on arc_quit_dialog.png
  public static let dialogBackdropAlpha: CGFloat = 0.55  // spec §3/§5
  public static let toastHeight: CGFloat = 36  // estimate
  public static let toastCornerRadius: CGFloat = 10  // estimate
  public static let toastTopInset: CGFloat = 12  // estimate: spec §6 anchors toasts to the window's top-right; margin UNVERIFIED
  public static let toastRightInset: CGFloat = 20  // estimate
  public static let toastDefaultDurationMs = 2200  // estimate

  // MARK: Link status pill (Arc: the hovered link's address, bottom of the page; docs/research/arc.md "Status pill")
  public static let statusPillHeight: CGFloat = 22  // estimate
  public static let statusPillCornerRadius: CGFloat = 7  // estimate
  public static let statusPillInset: CGFloat = 6  // estimate: from the page's bottom-left (or bottom-right) corner
  public static let statusPillPadding: CGFloat = 9  // estimate: text inset on each side
  public static let statusPillFontSize: CGFloat = 11.5  // estimate
  /// The pill moves to the other corner when the pointer comes this close (pt).
  public static let statusPillAvoid: CGFloat = 16  // estimate
  public static let statusPillFadeIn: TimeInterval = 0.10  // estimate
  public static let statusPillFadeOut: TimeInterval = 0.16  // estimate
  public static let statusPillMove: TimeInterval = 0.18  // estimate

  // MARK: Archive / Library sheet (Arc's archive view is UNVERIFIED, spec §12: all estimates)
  public static let libraryWidth: CGFloat = 640  // estimate
  public static let libraryInset: CGFloat = 40  // estimate: from the content area's edges
  public static let libraryCornerRadius: CGFloat = 20  // estimate: same as the theme picker popover
  public static let libraryPadding: CGFloat = 24  // estimate
  public static let libraryRowHeight: CGFloat = 48  // estimate
  public static let libraryRowRadius: CGFloat = 10  // estimate
  public static let libraryBackdropAlpha: CGFloat = 0.35  // estimate (dialogs use the measured 0.55)

  // MARK: Briefing page / connections sheet (den's own UI, not in Arc: all estimates)
  public static let sheetWidth: CGFloat = 560  // estimate: the `sheet` style (connections settings)
  public static let sheetInset: CGFloat = 40  // estimate: from the content area's edges
  public static let sheetCornerRadius: CGFloat = 20  // estimate: same as the library sheet
  public static let sheetPadding: CGFloat = 24  // estimate
  public static let pageColumnMaxWidth: CGFloat = 680  // estimate: the `page` style's centered column
  public static let pageTopPadding: CGFloat = 40  // estimate
  public static let pageSideMargin: CGFloat = 40  // estimate
  public static let sheetHeaderHeight: CGFloat = 44  // estimate: icon + title (+ subtitle) row
  public static let sheetStackSpacing: CGFloat = 14  // estimate
  public static let sectionHeaderHeight: CGFloat = 26  // estimate
  public static let sectionCardRadius: CGFloat = 10  // estimate (Dia's card radius is 10, spec §13)
  public static let sectionDividerInset: CGFloat = 44  // estimate
  public static let todoRowHeight: CGFloat = 48  // estimate
  public static let todoCheckboxSize: CGFloat = 18  // estimate
  public static let feedRowHeight: CGFloat = 52  // estimate
  public static let connectionRowHeight: CGFloat = 56  // estimate
  public static let settingRowHeight: CGFloat = 44  // estimate: toggleRow / choiceRow
  public static let sheetButtonHeight: CGFloat = 32  // estimate: actionButton
  public static let sheetRowRadius: CGFloat = 8  // estimate: row hover fill

  // MARK: Little Arc (spec §8; PX = measured on the spec's arc_littlearc_page.png)
  public static let miniDefaultSize = CGSize(width: 1185, height: 832)  // spec §8 (after a URL loads)
  public static let miniMinSize = CGSize(width: 490, height: 329)  // spec §8: the command-bar-only state
  public static let miniScreenMargin: CGFloat = 20  // spec §8: 20 pt from the screen's right edge and below the menu bar
  public static let miniBarHeight: CGFloat = 47  // spec §8
  public static let miniTrafficLightOrigin = CGPoint(x: 9, y: 15)  // spec §8
  public static let miniTrafficLightPitch: CGFloat = 23  // PX: centers at about 17 / 40 / 63 pt
  public static let miniFieldX: CGFloat = 83  // PX
  public static let miniFieldTop: CGFloat = 8  // PX
  public static let miniFieldHeight: CGFloat = 30.5  // PX
  public static let miniFieldRadius: CGFloat = 8  // estimate
  public static let miniOpenButtonRightInset: CGFloat = 7  // PX: button x 1033–1178 in a 1185 window

  // MARK: Theme picker (spec §4; PX = measured on the spec's arc_theme_picker.png, @2x)
  public static let themePickerSize = CGSize(width: 356, height: 508)  // spec §4
  public static let themePickerCornerRadius: CGFloat = 20  // spec §4 (continuous)
  public static let themePickerSidebarGap: CGFloat = 13  // spec §4: body x = 241 with a 228 sidebar
  public static let themePickerAnchorOffsetY: CGFloat = -40  // estimate: popover top relative to the anchor's top
  public static let themePickerPadInset: CGFloat = 8  // spec §4
  public static let themePickerPadSize: CGFloat = 340  // spec §4
  public static let themePickerPadRadius: CGFloat = 7  // PX (rough fit)
  public static let themePickerDotPitch: CGFloat = 4.25  // PX: 8.5 px dot pitch
  public static let themePickerDotSize: CGFloat = 1  // PX
  public static let themePickerDotAlpha: CGFloat = 0.27  // PX: 134 over 90
  public static let themePickerModeTop: CGFloat = 32  // PX: selected mode button at (122, 32)
  public static let themePickerModeSize: CGFloat = 32  // spec §4
  public static let themePickerModePitch: CGFloat = 40  // spec §4
  public static let themePickerModeRadius: CGFloat = 8  // estimate
  public static let themePickerSelectedModeAlpha: CGFloat = 0.12  // PX: 113 over 94
  public static let themePickerAddRemoveCenterY: CGFloat = 316.5  // PX
  public static let themePickerSwatchCenterY: CGFloat = 380.5  // PX
  public static let themePickerSwatchSize: CGFloat = 24  // spec §4
  public static let themePickerSwatchPitch: CGFloat = 29.5  // spec §4
  public static let themePickerSwatchFirstX: CGFloat = 60  // PX: first swatch center
  public static let themePickerPagerCenterX: CGFloat = 23.5  // PX: prev/next page buttons at 23.5 / 332.5
  public static let themePickerSliderFrame = CGRect(x: 18, y: 429.5, width: 224, height: 44)  // spec §4 size, PX position
  public static let themePickerTrackHeight: CGFloat = 20  // PX
  public static let themePickerWavePeriod: CGFloat = 32.5  // PX
  public static let themePickerWaveAmplitude: CGFloat = 12  // PX
  public static let themePickerWaveWidth: CGFloat = 5  // PX
  public static let themePickerDialCenter = CGPoint(x: 298, y: 452)  // PX
  public static let themePickerDialInnerRadius: CGFloat = 20.5  // PX
  public static let themePickerDialDotRadius: CGFloat = 32.5  // PX
  public static let themePickerDialDots = 24  // estimate (PX count unclear)
  public static let themePickerHandleSize: CGFloat = 34  // estimate: primary color handle
  public static let themePickerSecondaryHandleSize: CGFloat = 26  // estimate
  public static let themePickerBodyDark = (r: 86.0 / 255, g: 86.0 / 255, b: 87.0 / 255)  // PX (no color picked)
  public static let themePickerBodyLight = (r: 0.95, g: 0.95, b: 0.96)  // estimate
  public static let themePickerBodyTint: CGFloat = 0.14  // estimate: body blends toward the first color

  // MARK: Theme rendering
  public static let lightBase: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.95, 0.95, 0.96)  // estimate
  public static let darkBase: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.11, 0.11, 0.12)  // estimate
  public static let defaultIntensity: CGFloat = 0.55  // estimate
  public static let defaultGrain: CGFloat = 0.25  // estimate
  public static let grainMaxAlpha: CGFloat = 0.12  // estimate: grain=1 draws noise at this alpha
  public static let grainTileSize = 128  // estimate

  // MARK: Motion
  public static let animationDuration: TimeInterval = 0.2  // estimate (generic; sidebar uses the measured values below)
  public static let spaceSwitchDuration: TimeInterval = 0.29  // spec §7: sidebar slides ~280–300 ms; content swaps instantly
  public static let sidebarHideDuration: TimeInterval = 0.067  // spec §7: ~67 ms, strong ease-out
  public static let sidebarShowDuration: TimeInterval = 0.083  // spec §7: ~83 ms, ease-out
  public static let swipeCommitFraction: CGFloat = 0.35  // estimate: swipe past this fraction commits

  // Extensions (Arc's extension popovers were never measured: estimates, sized like its menus)
  public static let extensionPanelRadius: CGFloat = 12  // estimate
  public static let extensionPanelGap: CGFloat = 6  // estimate: below the URL pill
  public static let extensionMenuWidth: CGFloat = 300  // estimate
  public static let extensionMenuRowHeight: CGFloat = 34  // estimate
  public static let extensionMenuPadding: CGFloat = 6  // estimate
  public static let extensionPillButton: CGFloat = 24  // estimate: pinned extension buttons in the URL pill
  /// Chrome's documented popup limits (developer.chrome.com, action.setPopup): 25x25 to 800x600.
  public static let extensionPopupMin = CGSize(width: 25, height: 25)
  public static let extensionPopupMax = CGSize(width: 800, height: 600)
  public static let extensionRowHeight: CGFloat = 58  // estimate: the Extensions page rows
  // MARK: Page actions (find bar, zoom) — den's own; Arc's find bar was never measured
  public static let findBarWidth: CGFloat = 320  // den's own
  public static let findBarHeight: CGFloat = 36  // the URL pill's height (spec §1)
  public static let findBarInset: CGFloat = 12  // den's own: from the card's top and right edges
  /// Safari's page zoom steps (⌘+ / ⌘-), 50–300%.
  public static let zoomSteps: [Double] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]

  // MARK: Windows — den's own
  /// Private windows (⇧⌘N) are always dark (Dia 1.18.1: "can't mistake a private window for a
  /// normal one"): a deep violet-to-graphite gradient, no grain, whatever the space themes are.
  public static let privateTheme = Theme(colors: [RGB(hex: "#3a2f5c")!, RGB(hex: "#1c1b26")!], intensity: 0.9, grain: 0, appearance: .dark)
  /// A new window (⌘N) opens this far right and down from the one in front (invisible mode only;
  /// on screen AppKit's cascade places it).
  public static let windowCascadeOffset: CGFloat = 30
  /// "Open in another window" in a pane whose page another window shows.
  public static let elsewhereWidth: CGFloat = 360  // den's own
  public static let elsewhereButtonHeight: CGFloat = 30  // den's own: dialog buttons' height class
  // MARK: Draggable reminder card (den's own: the meeting reminder that snaps to corners)
  public static let reminderCornerRadius: CGFloat = 14  // estimate
  public static let reminderShadowRadius: CGFloat = 16  // estimate
  public static let reminderShadowOpacity: Float = 0.25  // estimate
  public static let reminderDragHandleHeight: CGFloat = 8  // estimate: thin grab bar at the top
  public static let reminderCloseButtonSize: CGFloat = 20  // estimate
  public static let reminderMinWidth: CGFloat = 200  // estimate: narrowest usable card
  public static let reminderMinHeight: CGFloat = 60  // estimate
  public static let reminderDragThreshold: CGFloat = 4  // estimate: drag starts after this movement
  public static let reminderCornerInset: CGFloat = 16  // estimate: snap offset from screen edges
  public static let reminderSnapDuration: TimeInterval = 0.35  // estimate
}
