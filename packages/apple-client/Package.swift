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
    .library(name: "QuotaRelay", targets: ["QuotaRelay"]),
    .library(name: "QuotaAccount", targets: ["QuotaAccount"]),
    .library(name: "QuotaWidgetData", targets: ["QuotaWidgetData"]),
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
      name: "QuotaRelay",
      dependencies: ["QuotaWire"]
    ),
    .target(
      name: "QuotaAccount",
      dependencies: ["QuotaWire", "QuotaRelay"]
    ),
    .target(
      name: "QuotaWidgetData",
      dependencies: [.product(name: "QuotaPresentation", package: "QuotaAppleShared")]
    ),
    .testTarget(
      name: "QuotaAppleClientTests",
      dependencies: ["QuotaWire", "QuotaRelay", "QuotaAccount", "QuotaWidgetData"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
