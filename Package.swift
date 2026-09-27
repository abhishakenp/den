// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "den",
  // `.v26` needs tools 6.2; the string form gives macOS 26 while keeping tools 6.0.
  platforms: [.macOS("26.0")],
  products: [
    .executable(name: "Den", targets: ["Den"]),
    .library(name: "DenHost", targets: ["DenHost"]),
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
      sources: ["Shared/Env.swift", "spaces/SpacesCore.swift", "tabs/TabsCore.swift", "commandbar/CommandBarCore.swift", "commandbar/CommandIndex.swift", "commandbar/CommandLauncher.swift", "peek/PeekCore.swift", "theme/ThemeRules.swift", "theme/ThemeCore.swift", "quit/QuitCore.swift", "updates/UpdatesCore.swift", "Shared/Web.swift", "connections/ConnectionsCore.swift", "slack/SlackCore.swift", "github/GitHubCore.swift", "briefing/BriefingCore.swift", "previews/PreviewsCore.swift", "previews/Cards.swift", "previews/Providers.swift", "darkmode/DarkModeCore.swift", "passwords/PasswordsCore.swift", "extensions/ExtensionsCore.swift"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "PluginTests",
      dependencies: ["DenHost", "PluginCores", .product(name: "CordisValue", package: "cordis-swift"), .product(name: "Cordis", package: "cordis-swift")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "DenHostTests",
      dependencies: ["DenHost", .product(name: "CordisValue", package: "cordis-swift")]
    ),
  ]
)
