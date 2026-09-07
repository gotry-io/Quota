// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "QuotaAppleClient",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "QuotaWire", targets: ["QuotaWire"]),
    .library(name: "QuotaKeychain", targets: ["QuotaKeychain"]),
    .library(name: "QuotaRelay", targets: ["QuotaRelay"]),
    .library(name: "QuotaAccount", targets: ["QuotaAccount"]),
    .library(name: "QuotaWidgetData", targets: ["QuotaWidgetData"]),
    .library(name: "QuotaWidgetViews", targets: ["QuotaWidgetViews"]),
    .library(name: "QuotaWidgetProjection", targets: ["QuotaWidgetProjection"]),
    .library(name: "QuotaProviderWeb", targets: ["QuotaProviderWeb"]),
    .library(name: "QuotaProviderSessions", targets: ["QuotaProviderSessions"]),
    .library(name: "QuotaProviderStatus", targets: ["QuotaProviderStatus"]),
  ],
  dependencies: [
    .package(name: "QuotaAppleShared", path: "../apple-shared")
  ],
  targets: [
    .target(
      name: "QuotaWire",
      dependencies: [
        .product(name: "QuotaPresentation", package: "QuotaAppleShared"),
        .product(name: "QuotaObservations", package: "QuotaAppleShared"),
      ]
    ),
    .target(
      name: "QuotaKeychain"
    ),
    .target(
      name: "QuotaRelay",
      dependencies: ["QuotaWire"]
    ),
    .target(
      name: "QuotaAccount",
      dependencies: ["QuotaWire", "QuotaRelay", "QuotaKeychain"]
    ),
    .target(
      name: "QuotaProviderWeb",
      dependencies: ["QuotaWire"]
    ),
    .target(
      name: "QuotaProviderSessions",
      dependencies: ["QuotaWire", "QuotaKeychain"]
    ),
    .target(
      name: "QuotaWidgetData",
      dependencies: [.product(name: "QuotaPresentation", package: "QuotaAppleShared")]
    ),
    // The widget extensions link this and nothing else that speaks to Relay: no QuotaWire, no
    // Keychain, no URLSession (docs/decisions/0014-nonsecret-ios-widget-snapshot.md).
    .target(
      name: "QuotaWidgetViews",
      dependencies: [
        "QuotaWidgetData",
        .product(name: "QuotaPresentation", package: "QuotaAppleShared"),
      ]
    ),
    // The publishing side, which speaks QuotaWire. Both apps use it; neither extension does.
    .target(
      name: "QuotaWidgetProjection",
      dependencies: [
        "QuotaWidgetData",
        "QuotaWire",
        .product(name: "QuotaPresentation", package: "QuotaAppleShared"),
      ]
    ),
    .target(
      name: "QuotaProviderStatus",
      dependencies: [
        "QuotaWire",
        .product(name: "QuotaPresentation", package: "QuotaAppleShared"),
      ]
    ),
    .testTarget(
      name: "QuotaAppleClientTests",
      dependencies: [
        "QuotaWire", "QuotaRelay", "QuotaAccount", "QuotaWidgetData", "QuotaKeychain",
      ]
    ),
    .testTarget(
      name: "QuotaWidgetViewsTests",
      dependencies: ["QuotaWidgetViews", "QuotaWidgetProjection", "QuotaWire"]
    ),
    .testTarget(
      name: "QuotaProviderWebTests",
      dependencies: ["QuotaProviderWeb"]
    ),
    .testTarget(
      name: "QuotaProviderSessionsTests",
      dependencies: ["QuotaProviderSessions", "QuotaKeychain"]
    ),
    .testTarget(
      name: "QuotaProviderStatusTests",
      dependencies: [
        "QuotaProviderStatus",
        "QuotaWire",
        .product(name: "QuotaPresentation", package: "QuotaAppleShared"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
