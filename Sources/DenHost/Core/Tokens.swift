import CoreGraphics
import Foundation

/// Every visual constant of den's chrome lives here, so estimates can be swapped for values
/// measured on a real Arc build (docs/reference/arc-ui-spec.md) in one place.
/// `// estimate` = not measured; taken from screenshots, third-party write-ups, or taste.
public enum Tokens {
  // MARK: Window / content card
  public static let windowMinSize = CGSize(width: 640, height: 420)  // estimate
  public static let windowDefaultSize = CGSize(width: 1280, height: 820)  // estimate
  public static let cardInset: CGFloat = 8  // estimate: gap between card and window edge (top/right/bottom)
  public static let cardCornerRadius: CGFloat = 8  // estimate
  public static let cardShadowOpacity: Float = 0.14  // estimate
  public static let cardShadowRadius: CGFloat = 3  // estimate
  public static let cardShadowOffsetY: CGFloat = -1  // estimate (AppKit y-up)
  public static let cardBorderOpacity: CGFloat = 0.06  // estimate: hairline around the card
  public static let splitGap: CGFloat = 8  // estimate

  // MARK: Sidebar
  public static let sidebarDefaultWidth: CGFloat = 240  // estimate (third-party ~240 px)
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
  public static let trafficLightLeading: CGFloat = 16  // estimate: x of the close button
  public static let trafficLightCenterY: CGFloat = 20  // estimate: from window top
  public static let trafficLightSpacing: CGFloat = 20  // system default spacing (centre to centre) // estimate
  public static let navRowHeight: CGFloat = 40  // estimate: row shared with traffic lights
  public static let navButtonSize: CGFloat = 26  // estimate
  public static let urlPillHeight: CGFloat = 34  // estimate
  public static let urlPillCornerRadius: CGFloat = 10  // estimate
  public static let urlPillFontSize: CGFloat = 13  // estimate

  // MARK: Rows
  public static let tabRowHeight: CGFloat = 34  // estimate
  public static let tabRowCornerRadius: CGFloat = 8  // estimate
  public static let tabRowSpacing: CGFloat = 2  // estimate
  public static let tabRowIconSize: CGFloat = 16  // estimate
  public static let tabRowPaddingX: CGFloat = 10  // estimate
  public static let tabRowFontSize: CGFloat = 13  // estimate
  public static let folderIndent: CGFloat = 14  // estimate
  public static let dividerHeight: CGFloat = 24  // estimate

  // MARK: Favorites
  public static let favoriteColumns = 4  // estimate
  public static let favoriteTileHeight: CGFloat = 46  // estimate
  public static let favoriteTileCornerRadius: CGFloat = 10  // estimate
  public static let favoriteTileSpacing: CGFloat = 8  // estimate
  public static let favoriteIconSize: CGFloat = 20  // estimate

  // MARK: Footer / space switcher
  public static let footerHeight: CGFloat = 44  // estimate
  public static let spaceIconSize: CGFloat = 24  // estimate
  public static let spaceDotSize: CGFloat = 6  // estimate

  // MARK: Overlays
  public static let commandBarWidth: CGFloat = 680  // estimate
  public static let commandBarTopRatio: CGFloat = 0.18  // estimate: top of bar as fraction of window height
  public static let commandBarCornerRadius: CGFloat = 14  // estimate
  public static let commandBarInputHeight: CGFloat = 54  // estimate
  public static let commandBarInputFontSize: CGFloat = 18  // estimate
  public static let commandBarRowHeight: CGFloat = 40  // estimate
  public static let commandBarMaxRows = 8  // estimate
  public static let peekInset: CGFloat = 44  // estimate: peek card inset from the content area
  public static let peekCornerRadius: CGFloat = 10  // estimate
  public static let peekBackdropAlpha: CGFloat = 0.18  // estimate
  public static let dialogWidth: CGFloat = 380  // estimate
  public static let dialogCornerRadius: CGFloat = 14  // estimate
  public static let dialogBackdropAlpha: CGFloat = 0.2  // estimate
  public static let toastHeight: CGFloat = 36  // estimate
  public static let toastCornerRadius: CGFloat = 10  // estimate
  public static let toastBottomInset: CGFloat = 18  // estimate
  public static let toastDefaultDurationMs = 2200  // estimate

  // MARK: Theme rendering
  public static let lightBase: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.95, 0.95, 0.96)  // estimate
  public static let darkBase: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.11, 0.11, 0.12)  // estimate
  public static let defaultIntensity: CGFloat = 0.55  // estimate
  public static let defaultGrain: CGFloat = 0.25  // estimate
  public static let grainMaxAlpha: CGFloat = 0.12  // estimate: grain=1 draws noise at this alpha
  public static let grainTileSize = 128  // estimate

  // MARK: Motion
  public static let animationDuration: TimeInterval = 0.2  // estimate (third-party "0.2 s ease-out")
  public static let spaceSwitchDuration: TimeInterval = 0.28  // estimate
  public static let swipeCommitFraction: CGFloat = 0.35  // estimate: swipe past this fraction commits
}
