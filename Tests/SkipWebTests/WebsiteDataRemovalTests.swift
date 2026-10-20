// Copyright 2026-2026 Skip
// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import SkipWeb

#if SKIP || os(iOS)
/// Requires Tests/Fixtures/clear_data_server.py; Android uses adb reverse for port 18769.
final class WebsiteDataRemovalTests: XCTestCase {
    @MainActor
    func testNamedProfileRemovalPreservesUncheckedCategoriesAndOtherProfile() async throws {
        #if SKIP
        if isRobolectric { throw XCTSkip("Requires instrumented WebView") }
        if !WebEngine.isAndroidMultiProfileSupported() { throw XCTSkip("Named profiles unavailable") }
        // Native WebViews need the real main looper, not the generated XCTest test dispatcher.
        // SKIP INSERT: Dispatchers.resetMain()
        #endif
        let suffix = UUID().uuidString
        let profileA = WebProfile.named("clear-a-\(suffix)")
        let profileB = WebProfile.named("clear-b-\(suffix)")
        let keyA = "a-\(suffix)"
        let keyB = "b-\(suffix)"
        var a = await makeFixtureEngine(profile: profileA)
        let b = await makeFixtureEngine(profile: profileB)
        let url = URL(string: "http://127.0.0.1:18769/fixture")!
        try await a.load(url: url)
        try await b.load(url: url)
        _ = try await script("await seed('A', '\(keyA)'); return true", engine: a)
        _ = try await script("await seed('B', '\(keyB)'); return true", engine: b)
        let beforeA = try await read(a, key: keyA)
        let beforeB = try await read(b, key: keyB)
        XCTAssertTrue(beforeA.contains("\"cache\":\"1\""))
        XCTAssertTrue(beforeB.contains("\"cache\":\"1\""))

        _ = try await a.removeBrowsingData(cookiesAndStorage: false, cache: true, modifiedSince: .distantPast)
        let cacheCleared = try await read(a, key: keyA)
        XCTAssertTrue(cacheCleared.contains("\"cache\":\"2\""), cacheCleared)
        for field in ["local", "session", "indexed"] {
            XCTAssertTrue(cacheCleared.contains("\"\(field)\":\"A\""), cacheCleared)
        }
        XCTAssertTrue(cacheCleared.contains("fixture=A"), cacheCleared)
        let otherAfter1 = try await read(b, key: keyB)
        XCTAssertEqual(otherAfter1, beforeB)

        // Retiring the profile also removes per-view sessionStorage. Logical tabs can recreate views.
        try await WebEngine.retireRuntimes(for: profileA)
        a = await makeFixtureEngine(profile: profileA)
        _ = try await a.removeBrowsingData(cookiesAndStorage: true, cache: false, modifiedSince: .distantPast)
        try await a.load(url: url)
        let siteCleared = try await read(a, key: keyA)
        for field in ["local", "session", "indexed", "cookie"] {
            XCTAssertTrue(siteCleared.contains("\"\(field)\":\"\""), siteCleared)
        }
        XCTAssertTrue(siteCleared.contains("\"cache\":\"2\""), siteCleared)
        let otherAfter2 = try await read(b, key: keyB)
        XCTAssertEqual(otherAfter2, beforeB)

        _ = try await script("await seed('A', '\(keyA)'); return true", engine: a)
        try await WebEngine.retireRuntimes(for: profileA)
        a = await makeFixtureEngine(profile: profileA)
        _ = try await a.removeBrowsingData(cookiesAndStorage: true, cache: true, modifiedSince: .distantPast)
        try await a.load(url: url)
        let allCleared = try await read(a, key: keyA)
        XCTAssertTrue(allCleared.contains("\"cache\":\"3\""), allCleared)
        for field in ["local", "session", "indexed", "cookie"] {
            XCTAssertTrue(allCleared.contains("\"\(field)\":\"\""), allCleared)
        }
        let otherAfter3 = try await read(b, key: keyB)
        XCTAssertEqual(otherAfter3, beforeB)
    }

    @MainActor
    private func makeFixtureEngine(profile: WebProfile) async -> WebEngine {
        let engine = await makeCookieTestEngine(profile: profile)
        #if SKIP
        engine.webView.settings.javaScriptEnabled = true
        engine.webView.settings.domStorageEnabled = true
        #endif
        return engine
    }

    @MainActor
    private func read(_ engine: WebEngine, key: String) async throws -> String {
        try await script("return await read('\(key)')", engine: engine)
    }

    /// Waits for an explicit JavaScript completion flag, not for an assumed platform delay.
    @MainActor
    private func script(_ body: String, engine: WebEngine) async throws -> String {
        _ = try await engine.evaluate(js: "window.fixtureResult = null; (async () => { \(body) })().then(v => window.fixtureResult = JSON.stringify(v), e => window.fixtureResult = 'ERROR:' + e); null")
        for _ in 0..<200 {
            let result = try await engine.evaluate(js: "window.fixtureResult")
            if let result, result != "null" {
                let data = Data(result.utf8)
                return (try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String) ?? result
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Fixture did not report JavaScript completion")
        return "TIMEOUT"
    }
}
#endif
