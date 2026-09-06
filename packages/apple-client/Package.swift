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
    .library(name: "QuotaProviderWeb", targets: ["QuotaProviderWeb"]),
    .library(name: "QuotaProviderSessions", targets: ["QuotaProviderSessions"]),
  ],
  dependencies: [
    .package(name: "QuotaAppleShared", path: "../apple-shared")
  ],
  targets: [
    .target(
      name: "QuotaWire",
      dependencies: [.product(name: "QuotaPresentation", package: "QuotaAppleShared")]
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
    .testTarget(
      name: "QuotaAppleClientTests",
      dependencies: [
        "QuotaWire", "QuotaRelay", "QuotaAccount", "QuotaWidgetData", "QuotaKeychain",
      ]
    ),
    .testTarget(
      name: "QuotaProviderWebTests",
      dependencies: ["QuotaProviderWeb"]
    ),
    .testTarget(
      name: "QuotaProviderSessionsTests",
      dependencies: ["QuotaProviderSessions", "QuotaKeychain"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
