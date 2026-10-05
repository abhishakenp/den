import AppIntents
import DenHost

/// The phrases Siri and Spotlight offer for den's actions (DenHost/Intents). Every phrase names
/// the app, as App Shortcuts require.
struct DenShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: NewTabIntent(), phrases: ["New tab in \(.applicationName)", "Open a new \(.applicationName) tab"],
                shortTitle: "New Tab", systemImageName: "plus.square.on.square")
    AppShortcut(intent: SwitchSpaceIntent(), phrases: ["Switch \(.applicationName) space", "Switch to \(\.$space) in \(.applicationName)"],
                shortTitle: "Switch Space", systemImageName: "square.stack.3d.up")
    AppShortcut(intent: SearchTabsIntent(), phrases: ["Find tabs in \(.applicationName)", "Search \(.applicationName) tabs"],
                shortTitle: "Find Tabs", systemImageName: "magnifyingglass")
    AppShortcut(intent: GetCurrentPageIntent(), phrases: ["Get the current page from \(.applicationName)"],
                shortTitle: "Current Page", systemImageName: "link")
    AppShortcut(intent: TogglePictureInPictureIntent(), phrases: ["Toggle picture in picture in \(.applicationName)"],
                shortTitle: "Picture in Picture", systemImageName: "pip")
  }
}
