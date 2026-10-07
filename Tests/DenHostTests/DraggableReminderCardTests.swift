import AppKit
import Foundation
import Testing
@testable import DenHost

@Suite struct DraggableReminderCardTests {

  @Test func nearestCornerSelectsClosestOnASingleScreen() {
    let screen = NSScreen.main!
    let screenRect = screen.frame
    let cardSize = NSSize(width: 200, height: 80)
    let center = NSPoint(x: screenRect.midX, y: screenRect.midY)
    let corner = ScreenCorner.nearest(to: center, in: screenRect, cardSize: cardSize, inset: 16)
    #expect(corner != nil)
  }

  @Test func nearestCornerPicksBottomRightWhenCardIsCloseToIt() {
    let screen = NSScreen.main!
    let screenRect = screen.frame
    let cardSize = NSSize(width: 200, height: 80)
    let center = NSPoint(x: screenRect.maxX - 40, y: screenRect.minY + 40)
    let corner = ScreenCorner.nearest(to: center, in: screenRect, cardSize: cardSize, inset: 16)
    #expect(corner == .bottomRight)
  }

  @Test func nearestCornerPicksTopLeftWhenCardIsCloseToIt() {
    let screen = NSScreen.main!
    let screenRect = screen.frame
    let cardSize = NSSize(width: 200, height: 80)
    let center = NSPoint(x: screenRect.minX + 40, y: screenRect.maxY - 40)
    let corner = ScreenCorner.nearest(to: center, in: screenRect, cardSize: cardSize, inset: 16)
    #expect(corner == .topLeft)
  }

  @Test func cornerPointsAreInsetFromScreenEdge() {
    let screen = NSScreen.main!
    let screenRect = screen.frame
    let cardSize = NSSize(width: 200, height: 80)
    let inset: CGFloat = 16
    let topLeft = ScreenCorner.topLeft.anchor(in: screenRect, cardSize: cardSize, inset: inset)
    #expect(topLeft.x > screenRect.minX)
    #expect(topLeft.y < screenRect.maxY)
    let bottomRight = ScreenCorner.bottomRight.anchor(in: screenRect, cardSize: cardSize, inset: inset)
    #expect(bottomRight.x + cardSize.width < screenRect.maxX)
    #expect(bottomRight.y + cardSize.height < screenRect.maxY)
  }

  @Test func cornerPointsStayInsideScreenBounds() {
    let screen = NSScreen.main!
    let screenRect = screen.frame
    let cardSize = NSSize(width: 100, height: 50)
    let inset: CGFloat = 8
    for corner in ScreenCorner.allCases {
      let anchor = corner.anchor(in: screenRect, cardSize: cardSize, inset: inset)
      let cardRect = NSRect(origin: anchor, size: cardSize)
      #expect(cardRect.minX >= screenRect.minX)
      #expect(cardRect.maxY <= screenRect.maxY)
    }
  }

  @Test func cornerDistanceCalculatesEuclideanDistanceCorrectly() {
    let screenRect = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let cardSize = NSSize(width: 200, height: 80)
    let inset: CGFloat = 16
    let topRight = ScreenCorner.topRight
    let anchor = topRight.anchor(in: screenRect, cardSize: cardSize, inset: inset)
    #expect(topRight.distance(from: anchor, in: screenRect, cardSize: cardSize, inset: inset) == 0)
  }

  @Test func reminderTokensHaveReasonableValues() {
    #expect(Tokens.reminderCornerRadius > 0)
    #expect(Tokens.reminderShadowRadius > 0)
    #expect(Tokens.reminderShadowOpacity >= 0 && Tokens.reminderShadowOpacity <= 1)
    #expect(Tokens.reminderDragHandleHeight > 0)
    #expect(Tokens.reminderCloseButtonSize > 0)
    #expect(Tokens.reminderMinWidth > 0)
    #expect(Tokens.reminderMinHeight > 0)
    #expect(Tokens.reminderDragThreshold > 0)
    #expect(Tokens.reminderCornerInset > 0)
    #expect(Tokens.reminderSnapDuration > 0)
  }

  @Test func screenContainingReturnsCorrectScreen() {
    let screen = NSScreen.main!
    let center = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
    let found = NSScreen.screenContaining(center)
    #expect(found == screen)
    let outside = NSPoint(x: -99999, y: -99999)
    #expect(NSScreen.screenContaining(outside) == nil)
  }
}
