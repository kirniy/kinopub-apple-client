// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "KinoPubUI",
  platforms: [.macOS(.v13), .iOS(.v16), .visionOS("2.0")],
  products: [
    .library(
      name: "KinoPubUI",
      targets: ["KinoPubUI"])
  ],
  dependencies: [
    .package(name: "KinoPubBackend", path: "../KinoPubBackend"),
    .package(path: "../../Vendor/SkeletonUI")
  ],
  targets: [
    .target(
      name: "KinoPubUI",
      dependencies: [
        .product(name: "KinoPubBackend", package: "KinoPubBackend"),
        .product(name: "SkeletonUI", package: "SkeletonUI")
      ],
      resources: [
        .process("Media.xcassets")
      ]),
    .testTarget(
      name: "KinoPubUITests",
      dependencies: ["KinoPubUI"])
  ]
)
