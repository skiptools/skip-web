// Copyright 2024–2026 Skip
import Foundation

enum WebURLUtilities {
    /// Maps an Android `asset:` URL to the equivalent `file:///android_asset/` URL.
    static func androidAssetURL(for url: URL) -> URL? {
        guard url.scheme == "asset" else {
            return nil
        }

        let absoluteString = url.absoluteString
        guard let schemeRange = absoluteString.range(of: "asset:") else {
            return nil
        }

        var assetPath = String(absoluteString[schemeRange.upperBound...])
        while assetPath.hasPrefix("/") {
            assetPath = String(assetPath.dropFirst())
        }
        guard !assetPath.isEmpty else {
            return nil
        }

        return URL(string: "file:///android_asset/\(assetPath)")
    }
}
