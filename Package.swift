// swift-tools-version: 5.9
// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
import PackageDescription

let package = Package(
    name: "skip-web",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v13), .tvOS(.v17), .watchOS(.v10), .macCatalyst(.v17)],
    products: [
        .library(name: "SkipWeb", targets: ["SkipWeb"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.0.10"),
        .package(url: "https://source.skip.tools/skip-ui.git", from: "1.6.1")
    ],
    targets: [
        .target(name: "SkipWeb", dependencies: [.product(name: "SkipUI", package: "skip-ui")], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "SkipWebTests", dependencies: ["SkipWeb", .product(name: "SkipTest", package: "skip")], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)

if Context.environment["SKIP_BRIDGE"] ?? "0" != "0" {
    package.dependencies += [.package(url: "https://source.skip.tools/skip-fuse-ui.git", from: "1.0.0")]
    package.targets.forEach({ target in
        target.dependencies += [.product(name: "SkipFuseUI", package: "skip-fuse-ui")]
    })
    // all library types must be dynamic to support bridging
    package.products = package.products.map({ product in
        guard let libraryProduct = product as? Product.Library else { return product }
        return .library(name: libraryProduct.name, type: .dynamic, targets: libraryProduct.targets)
    })
}
