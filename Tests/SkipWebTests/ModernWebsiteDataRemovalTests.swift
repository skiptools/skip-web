// Copyright 2026-2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if os(iOS) && !SKIP
import WebKit
import XCTest
@testable import SkipWeb

/// Runs its fixture on the device so these tests need no external server or port forwarding.
@MainActor
final class ModernWebsiteDataRemovalTests: XCTestCase {
    func testCacheRemovalPreservesSiteStorageAndOtherProfile() async throws {
        try await verifyRemoval(cookiesAndStorage: false, cache: true)
    }

    func testSiteDataRemovalPreservesHTTPCacheAndOtherProfile() async throws {
        try await verifyRemoval(cookiesAndStorage: true, cache: false)
    }

    func testCombinedRemovalClearsFetchCacheAndServiceWorkers() async throws {
        try await verifyRemoval(cookiesAndStorage: true, cache: true)
    }

    private func verifyRemoval(cookiesAndStorage: Bool, cache: Bool) async throws {
        let server = try WebsiteDataTestServer()
        let url = try await server.start()
        defer { server.stop() }
        let profileA = WebProfile.named("modern-a-\(UUID().uuidString)")
        let profileB = WebProfile.named("modern-b-\(UUID().uuidString)")
        var a = await makeEngine(profile: profileA)
        let b = await makeEngine(profile: profileB)
        try await a.load(url: url)
        try await b.load(url: url)
        try await seed(a, value: "A")
        try await seed(b, value: "B")
        let beforeA = try await read(a, key: "A")
        let beforeB = try await read(b, key: "B")
        XCTAssertEqual(beforeA.cache, "A")
        XCTAssertEqual(beforeA.workers, 1)
        XCTAssertEqual(beforeB.cache, "B")
        XCTAssertEqual(beforeB.workers, 1)

        if cookiesAndStorage {
            try await WebEngine.retireRuntimes(for: profileA)
            a = await makeEngine(profile: profileA)
        } else {
            WebEngine.stopRuntimes(for: profileA)
        }
        let completed = try await a.removeBrowsingData(
            cookiesAndStorage: cookiesAndStorage, cache: cache, modifiedSince: .distantPast
        )
        XCTAssertTrue(completed)
        if cookiesAndStorage { try await a.load(url: url) }
        let afterA = try await read(a, key: "A")
        let afterB = try await read(b, key: "B")
        XCTAssertEqual(afterA.cache, cookiesAndStorage ? "" : "A")
        XCTAssertEqual(afterA.workers, cookiesAndStorage ? 0 : 1)
        if cache {
            XCTAssertNotEqual(afterA.httpCache, beforeA.httpCache, server.diagnostics)
            XCTAssertEqual(server.requestCount(for: "/http-cache?key=A"), 2, server.diagnostics)
        } else {
            XCTAssertEqual(afterA.httpCache, beforeA.httpCache, server.diagnostics)
            XCTAssertEqual(server.requestCount(for: "/http-cache?key=A"), 1, server.diagnostics)
        }
        XCTAssertEqual(afterB.cache, beforeB.cache)
        XCTAssertEqual(afterB.workers, beforeB.workers)
        XCTAssertEqual(afterB.httpCache, beforeB.httpCache, server.diagnostics)
        XCTAssertEqual(server.requestCount(for: "/http-cache?key=B"), 1, server.diagnostics)

        try await WebEngine.retireRuntimes(for: profileA)
        try await WebEngine.retireRuntimes(for: profileB)
        for engine in [a, b] {
            await engine.webView.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
            )
        }
    }

    private func makeEngine(profile: WebProfile) async -> WebEngine {
        let configuration = WebEngineConfiguration(profile: profile)
        let nativeConfiguration = await configuration.makeWebViewConfiguration()
        // WebKit enables service workers for app-bound views; loopback is app-bound.
        nativeConfiguration.limitsNavigationsToAppBoundDomains = true
        return WebEngine(configuration: configuration,
            webView: WKWebView(frame: .zero, configuration: nativeConfiguration))
    }

    private func seed(_ engine: WebEngine, value: String) async throws {
        _ = try await engine.webView.callAsyncJavaScript("""
            const cache = await caches.open('fixture');
            await cache.put('/saved', new Response(value));
            await navigator.serviceWorker.register('/worker.js');
            await navigator.serviceWorker.ready;
            return true;
            """, arguments: ["value": value], in: nil, contentWorld: .page)
    }

    private func read(_ engine: WebEngine, key: String) async throws -> (cache: String, workers: Int, httpCache: String) {
        let result = try await engine.webView.callAsyncJavaScript("""
            const response = await caches.match('/saved');
            return {
                cache: response ? await response.text() : '',
                workers: (await navigator.serviceWorker.getRegistrations()).length,
                httpCache: await fetch('/http-cache?key=' + key).then(response => response.text())
            };
            """, arguments: ["key": key], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        return (
            try XCTUnwrap(values["cache"] as? String),
            try XCTUnwrap(values["workers"] as? Int),
            try XCTUnwrap(values["httpCache"] as? String)
        )
    }
}

#endif
