// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TOML11ParserPOC",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "probe-tomldecoder", targets: ["ProbeTOMLDecoder"]),
        .executable(name: "probe-swift-toml", targets: ["ProbeSwiftTOML"]),
        .executable(name: "probe-tomlkit", targets: ["ProbeTOMLKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
        .package(url: "https://github.com/mattt/swift-toml.git", exact: "2.0.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
    ],
    targets: [
        .target(name: "ProbeSupport"),
        .executableTarget(name: "ProbeTOMLDecoder", dependencies: ["ProbeSupport", .product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .executableTarget(name: "ProbeSwiftTOML", dependencies: ["ProbeSupport", .product(name: "TOML", package: "swift-toml")]),
        .executableTarget(name: "ProbeTOMLKit", dependencies: ["ProbeSupport", .product(name: "TOMLKit", package: "TOMLKit")]),
    ]
)
