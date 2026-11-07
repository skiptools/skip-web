// Copyright 2026 Skip
import XCTest
import Foundation
@testable import SkipWeb

final class AndroidAssetURLTests: XCTestCase {
    func testMapsAssetURLToAndroidAssetURL() {
        let url = URL(string: "asset:/myproject/module/Resources/mylocalpage.html")!

        XCTAssertEqual(
            WebURLUtilities.androidAssetURL(for: url)?.absoluteString,
            "file:///android_asset/myproject/module/Resources/mylocalpage.html"
        )
    }

    func testMapsAssetURLWithTripleSlash() {
        let url = URL(string: "asset:///myproject/module/Resources/mylocalpage.html")!

        XCTAssertEqual(
            WebURLUtilities.androidAssetURL(for: url)?.absoluteString,
            "file:///android_asset/myproject/module/Resources/mylocalpage.html"
        )
    }

    func testPreservesPercentEncodingQueryAndFragment() {
        let url = URL(string: "asset:/foo%20bar.html?x=1#frag")!

        XCTAssertEqual(
            WebURLUtilities.androidAssetURL(for: url)?.absoluteString,
            "file:///android_asset/foo%20bar.html?x=1#frag"
        )
    }

    func testIgnoresNonAssetURLs() {
        XCTAssertNil(WebURLUtilities.androidAssetURL(for: URL(string: "https://example.com")!))
        XCTAssertNil(WebURLUtilities.androidAssetURL(for: URL(string: "file:///android_asset/foo.html")!))
    }

    func testIgnoresEmptyAssetPath() {
        XCTAssertNil(WebURLUtilities.androidAssetURL(for: URL(string: "asset:/")!))
    }
}
