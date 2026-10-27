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
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.50.0")
    ],
    targets: [
        .target(name: "SkipWeb", dependencies: [.product(name: "SkipUI", package: "skip-ui")], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "SkipWebWasm", dependencies: [
            .product(name: "SkipUI", package: "skip-ui"),
            .product(name: "JavaScriptKit", package: "JavaScriptKit")
        ], swiftSettings: [.define("SKIP_WEB")]),
        .testTarget(name: "SkipWebTests", dependencies: ["SkipWeb", .product(name: "SkipTest", package: "skip")], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)

private enum BuildFlag: String {
    case enabled = "1"
}

private enum SkipWebTarget: String {
    case native = "SkipWeb"
    case wasm = "SkipWebWasm"
    case tests = "SkipWebTests"

    var supportsBridge: Bool {
        switch self {
        case .native, .tests:
            true
        case .wasm:
            false
        }
    }
}

private func isEnabled(_ variable: String) -> Bool {
    BuildFlag(rawValue: Context.environment[variable] ?? "") == .enabled
}

if isEnabled("SKIP_BRIDGE") {
    package.dependencies += [
        .package(url: "https://github.com/skiptools/skip-bridge.git", "0.0.0"..<"2.0.0"),
        .package(url: "https://github.com/skiptools/skip-fuse-ui.git", from: "1.15.2")
    ]
    package.targets.filter({ target in
        SkipWebTarget(rawValue: target.name)?.supportsBridge == true
    }).forEach({ target in
        target.dependencies += [
            .product(name: "SkipBridge", package: "skip-bridge"),
            .product(name: "SkipFuseUI", package: "skip-fuse-ui")
        ]
    })
    // all library types must be dynamic to support bridging
    package.products = package.products.map({ product in
        guard let libraryProduct = product as? Product.Library else { return product }
        return .library(name: libraryProduct.name, type: .dynamic, targets: libraryProduct.targets)
    })
}
