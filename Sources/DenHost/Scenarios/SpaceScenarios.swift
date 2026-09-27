import AppKit
import CordisValue

/// `--scenario` states for the space context menu, icon picker, inline rename and the footer's
/// live drag-reorder. They drive the real `spaces` plugin (run with the bundled plugins).
@MainActor
public enum SpaceScenarios {
  public static let names = ["spaceMenu", "spaceIconPicker", "spaceRename", "spaceReorder"]

  public static func apply(_ name: String, runtime rt: DenRuntime) -> NSWindow? {
    guard names.contains(name) else { return nil }
    let w = rt.window.window
    guard let sid = rt.call("spaces", "current")["id"].string else { return w }
    let icon = "spaces.icon:" + sid
    switch name {
    case "spaceMenu":
      // A native menu is its own window (scripts/snapshots.sh captures it with screencapture -l).
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        guard let v = HostScenarios.find(icon, in: rt.ui.sidebarView),
              let m = v.menu(for: NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!) else { return }
        m.popUp(positioning: nil, at: NSPoint(x: v.bounds.midX, y: 0), in: v)
      }
    case "spaceIconPicker":
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { rt.plugins.emit("ui.action", ["id": .string(icon), "action": "menu", "value": "icon"]) }
    case "spaceRename":
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { rt.plugins.emit("ui.action", ["id": .string("spaces.title:" + sid), "action": "menu", "value": "rename"]) }
    case "spaceReorder":
      // Mid-drag: the first icon lifted and carried over the second, which has slid aside.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        let icons = (HostScenarios.find("spaces.footer", in: rt.ui.sidebarView)?.subviews ?? []).compactMap { $0 as? SpaceIconNode }.sorted { $0.frame.minX < $1.frame.minX }
        guard icons.count > 1 else { return }
        let a = icons[0], pitch = icons[1].frame.minX - icons[0].frame.minX
        func ev(_ t: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
          NSEvent.mouseEvent(with: t, location: a.convert(NSPoint(x: a.bounds.midX + dx, y: a.bounds.midY), to: nil), modifierFlags: [], timestamp: 0,
                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        a.mouseDown(with: ev(.leftMouseDown, 0))
        a.mouseDragged(with: ev(.leftMouseDragged, 6))
        a.mouseDragged(with: ev(.leftMouseDragged, pitch * 0.8))
      }
    default: break
    }
    return w
  }
}
