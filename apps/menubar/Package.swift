// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "QuotaBar",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "QuotaBar", targets: ["QuotaBar"])
  ],
  dependencies: [
    .package(path: "../../packages/apple-client"),
    .package(path: "../../packages/apple-shared"),
    .package(url: "https://github.com/steipete/SweetCookieKit.git", exact: "0.5.2"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
  ],
  targets: [
    .target(
      name: "QuotaBarKeychainShim",
      linkerSettings: [
        .linkedFramework("Security"),
        .linkedFramework("CoreFoundation"),
      ]),
    .executableTarget(
      name: "QuotaBar",
      dependencies: [
        .product(name: "QuotaWire", package: "apple-client"),
        .product(name: "QuotaPresentation", package: "apple-shared"),
        .product(name: "QuotaAlerts", package: "apple-shared"),
        .product(name: "SweetCookieKit", package: "SweetCookieKit"),
        .product(name: "Sparkle", package: "Sparkle"),
        "QuotaBarKeychainShim",
      ],
      resources: [.process("Resources")],
      linkerSettings: [
        .linkedFramework("UserNotifications")
      ]),
    .testTarget(
      name: "QuotaBarTests",
      dependencies: [
        "QuotaBar",
        .product(name: "QuotaAlerts", package: "apple-shared"),
      ]),
  ])
