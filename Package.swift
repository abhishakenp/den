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
    .package(path: "../cordis-swift")
  ],
  targets: [
    .target(
      name: "DenHost",
      dependencies: [.product(name: "CordisValue", package: "cordis-swift")]
    ),
    .executableTarget(
      name: "Den",
      dependencies: ["DenHost", .product(name: "CordisValue", package: "cordis-swift")]
    ),
    .testTarget(
      name: "DenHostTests",
      dependencies: ["DenHost", .product(name: "CordisValue", package: "cordis-swift")]
    ),
  ]
)
