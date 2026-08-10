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
    .package(
      url: "https://github.com/pointfreeco/swift-snapshot-testing.git",
      exact: "1.19.4")
  ],
  targets: [
    .executableTarget(
      name: "QuotaBar",
      resources: [.process("Resources")]),
    .testTarget(
      name: "QuotaBarTests",
      dependencies: [
        "QuotaBar",
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
      ],
      resources: [.copy("__Snapshots__")]),
  ])
