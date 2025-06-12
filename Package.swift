// swift-tools-version:5.11
import PackageDescription

let package = Package(
  name: "readSpatial",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-argument-parser.git",
      from: "1.1.0"
    ),
  ],
  targets: [
    .executableTarget(
      name: "readSpatial",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "read_heif"   // ← Converter.swift と takeTwoSight.swift があるフォルダ名
    ),
  ]
)

