// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "skip-web",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .watchOS(.v10), .macCatalyst(.v17)],
    products: [
        .library(name: "SkipWeb", targets: ["SkipWeb"]),
        .library(name: "SkipWebWasm", targets: ["SkipWebWasm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/skiptools/skip.git", from: "1.8.9"),
        .package(url: "https://github.com/skiptools/skip-ui.git", from: "1.54.0"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.58.0")
    ],
    targets: [
        .target(name: "SkipWeb", dependencies: [.product(name: "SkipUI", package: "skip-ui")], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "SkipWebWasm", dependencies: [.product(name: "JavaScriptKit", package: "JavaScriptKit")]),
        .testTarget(name: "SkipWebTests", dependencies: ["SkipWeb", .product(name: "SkipTest", package: "skip")], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "SkipWebWasmTests", dependencies: ["SkipWebWasm"]),
    ]
)

if Context.environment["SKIP_BRIDGE"] ?? "0" != "0" {
    package.dependencies += [
        .package(url: "https://github.com/skiptools/skip-bridge.git", "0.0.0"..<"2.0.0"),
        .package(url: "https://github.com/skiptools/skip-fuse-ui.git", from: "1.15.2")
    ]
    package.targets.filter({ target in
        target.name == "SkipWeb" || target.name == "SkipWebTests"
    }).forEach({ target in
        target.dependencies += [
            .product(name: "SkipBridge", package: "skip-bridge"),
            .product(name: "SkipFuseUI", package: "skip-fuse-ui")
        ]
    })
    // Only the native SkipWeb product participates in bridge mode. SkipWebWasm is a browser
    // target and must not acquire Android bridge dependencies or dynamic-library requirements.
    package.products = package.products.map({ product in
        guard let libraryProduct = product as? Product.Library, libraryProduct.name == "SkipWeb" else { return product }
        return .library(name: libraryProduct.name, type: .dynamic, targets: libraryProduct.targets)
    })
}
