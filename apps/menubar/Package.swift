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
    .package(url: "https://github.com/steipete/SweetCookieKit.git", exact: "0.5.2"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
  ],
  targets: [
    .executableTarget(
      name: "QuotaBar",
      dependencies: [
        .product(name: "SweetCookieKit", package: "SweetCookieKit"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      resources: [.process("Resources")]),
    .testTarget(
      name: "QuotaBarTests",
      dependencies: ["QuotaBar"]),
  ])
