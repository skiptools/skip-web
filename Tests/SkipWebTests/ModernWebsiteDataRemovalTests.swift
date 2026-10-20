// Copyright 2026-2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if os(iOS) && !SKIP
import Network
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
        let server = try ModernWebsiteDataServer()
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
        let beforeA = try await read(a)
        let beforeB = try await read(b)
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
        let afterA = try await read(a)
        let afterB = try await read(b)
        XCTAssertEqual(afterA.cache, cookiesAndStorage ? "" : "A")
        XCTAssertEqual(afterA.workers, cookiesAndStorage ? 0 : 1)
        if cache {
            XCTAssertNotEqual(afterA.httpCache, beforeA.httpCache)
        } else {
            XCTAssertEqual(afterA.httpCache, beforeA.httpCache)
        }
        XCTAssertEqual(afterB.cache, beforeB.cache)
        XCTAssertEqual(afterB.workers, beforeB.workers)
        XCTAssertEqual(afterB.httpCache, beforeB.httpCache)

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

    private func read(_ engine: WebEngine) async throws -> (cache: String, workers: Int, httpCache: String) {
        let result = try await engine.webView.callAsyncJavaScript("""
            const response = await caches.match('/saved');
            return {
                cache: response ? await response.text() : '',
                workers: (await navigator.serviceWorker.getRegistrations()).length,
                httpCache: await fetch('/http-cache').then(response => response.text())
            };
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        return (
            try XCTUnwrap(values["cache"] as? String),
            try XCTUnwrap(values["workers"] as? Int),
            try XCTUnwrap(values["httpCache"] as? String)
        )
    }
}

/// Minimal loopback HTTP fixture for Cache API and service-worker registration.
private final class ModernWebsiteDataServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SkipWebTests.ModernWebsiteDataServer")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let queue = queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receiveRequest(connection, received: Data())
        }
    }

    func start() async throws -> URL {
        let listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private static func receiveRequest(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            var request = received
            if let data { request.append(data) }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || error != nil || request.count > 16_384 {
                    connection.cancel()
                } else {
                    receiveRequest(connection, received: request)
                }
                return
            }
            let requestLine = String(decoding: request, as: UTF8.self)
            let body: String
            let mime: String
            let cacheControl: String
            if requestLine.hasPrefix("GET /http-cache ") {
                // A new value means the request reached the server instead of the HTTP cache.
                body = UUID().uuidString
                mime = "text/plain"
                cacheControl = "public, max-age=3600"
            } else if requestLine.hasPrefix("GET /worker.js ") {
                body = "self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));"
                mime = "text/javascript"
                cacheControl = "no-store"
            } else {
                body = "<!doctype html><html><body>Modern website data fixture</body></html>"
                mime = "text/html"
                cacheControl = "no-store"
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: \(cacheControl)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
#endif
