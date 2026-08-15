// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "QuotaAppleShared",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "QuotaPresentation", targets: ["QuotaPresentation"])
  ],
  targets: [
    .target(name: "QuotaPresentation"),
    .testTarget(
      name: "QuotaPresentationTests",
      dependencies: ["QuotaPresentation"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
