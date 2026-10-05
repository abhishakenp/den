// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "den",
  // `.v26` needs tools 6.2; the string form gives macOS 26 while keeping tools 6.1 (traits).
  platforms: [.macOS("26.0")],
  products: [
    .executable(name: "Den", targets: ["Den"]),
    .library(name: "DenHost", targets: ["DenHost"]),
  ],
  // `Scenarios`: --scenario fixtures and the local fake Slack/GitHub (Sources/DenHost/Scenarios, `#if Scenarios`).
  // On for swift build/test and snapshot bundles; scripts/bundle.sh builds release without it
  // (`--disable-default-traits`), so the shipped app carries no fixtures and doesn't link Network.framework.
  traits: [
    .trait(name: "Scenarios", description: "Dev fixtures: --scenario states and MockServices"),
    .default(enabledTraits: ["Scenarios"]),
  ],
  dependencies: [
    .package(url: "https://github.com/abhishakenp/cordis-swift", from: "0.1.2"),
    // Host updates (EdDSA-signed appcast). Embedded into den.app/Contents/Frameworks by scripts/bundle.sh.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
  ],
  targets: [
    .target(
      name: "DenHost",
      dependencies: [
        .product(name: "CordisValue", package: "cordis-swift"),
        .product(name: "Cordis", package: "cordis-swift"),
      ]
    ),
    .executableTarget(
      name: "Den",
      dependencies: ["DenHost", .product(name: "CordisValue", package: "cordis-swift"), .product(name: "Sparkle", package: "Sparkle")]
    ),
    // Plugin logic compiled as normal Swift so it can be tested against the real host services.
    // The same files are compiled as Embedded Swift plugins by scripts/bundle.sh (cordis-build).
    .target(
      name: "PluginCores",
      dependencies: [.product(name: "CordisValue", package: "cordis-swift")],
      path: "Plugins",
      exclude: ["pagetools/resources", "shields/resources"],
      sources: ["Shared/Env.swift", "spaces/SpacesCore.swift", "tabs/TabsCore.swift", "tabs/LiveFolders.swift", "tabs/TabsDownloads.swift", "tabs/TabsIcons.swift", "tabs/TabsEnergy.swift", "tabs/TabsWindows.swift", "tabs/TabsPopups.swift", "tabs/TabsSession.swift", "commandbar/CommandBarCore.swift", "commandbar/CommandIndex.swift", "commandbar/CommandLauncher.swift", "commandbar/WebSuggestions.swift", "commandbar/ConfigShortcuts.swift", "commandbar/CommandFiles.swift", "peek/PeekCore.swift", "theme/ThemeRules.swift", "theme/ThemeCore.swift", "quit/QuitCore.swift", "updates/UpdatesCore.swift", "updates/PluginNotices.swift", "Shared/Web.swift", "connections/ConnectionsCore.swift", "slack/SlackCore.swift", "github/GitHubCore.swift", "gmail/GmailCore.swift", "calendar/CalendarCore.swift", "calendar/ICS.swift", "notion/NotionCore.swift", "briefing/BriefingCore.swift", "previews/PreviewsCore.swift", "previews/Cards.swift", "previews/Providers.swift", "previews/OpenGraph.swift", "darkmode/DarkModeCore.swift", "passwords/PasswordsCore.swift", "extensions/ExtensionsCore.swift", "pagetools/PageToolsCore.swift", "pagetools/ReaderVoices.swift", "Shared/IDN.swift", "shields/ShieldsCore.swift", "shields/CleanLinks.swift", "shields/Lookalike.swift", "shields/ShieldsLists.swift", "media/MediaCore.swift", "panels/PanelsCore.swift", "tips/TipsCore.swift", "tabs/TabsTidy.swift", "continuity/ContinuityCore.swift"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // Test-only: the per-test watchdog trait and bounded waits shared by both test targets.
    .target(name: "DenTestSupport", dependencies: ["DenHost"], path: "Tests/DenTestSupport"),
    .testTarget(
      name: "PluginTests",
      dependencies: ["DenHost", "PluginCores", "DenTestSupport", .product(name: "CordisValue", package: "cordis-swift"), .product(name: "Cordis", package: "cordis-swift")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "DenHostTests",
      dependencies: ["DenHost", "DenTestSupport", .product(name: "CordisValue", package: "cordis-swift")]
    ),
  ]
)
