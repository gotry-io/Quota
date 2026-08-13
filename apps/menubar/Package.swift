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
    .package(url: "https://github.com/steipete/SweetCookieKit.git", exact: "0.5.2")
  ],
  targets: [
    .executableTarget(
      name: "QuotaBar",
      dependencies: [
        .product(name: "SweetCookieKit", package: "SweetCookieKit")
      ],
      resources: [.process("Resources")]),
    .testTarget(
      name: "QuotaBarTests",
      dependencies: ["QuotaBar"]),
  ])
