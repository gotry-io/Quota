// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "QuotaAppleShared",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "QuotaPresentation", targets: ["QuotaPresentation"]),
    .library(name: "QuotaAlerts", targets: ["QuotaAlerts"]),
    .library(name: "QuotaObservations", targets: ["QuotaObservations"]),
  ],
  targets: [
    .target(name: "QuotaPresentation"),
    .target(
      name: "QuotaAlerts",
      dependencies: ["QuotaPresentation"]
    ),
    .target(
      name: "QuotaObservations",
      dependencies: ["QuotaPresentation"]
    ),
    .testTarget(
      name: "QuotaPresentationTests",
      dependencies: ["QuotaPresentation"]
    ),
    .testTarget(
      name: "QuotaAlertsTests",
      dependencies: ["QuotaAlerts"]
    ),
    .testTarget(
      name: "QuotaObservationsTests",
      dependencies: ["QuotaObservations"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
