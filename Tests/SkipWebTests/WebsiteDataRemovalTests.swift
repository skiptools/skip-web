// Copyright 2026-2026 Skip
// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import SkipWeb

#if SKIP || os(iOS)
/// Exercises website-data removal with an HTTP fixture running inside the test process.
final class WebsiteDataRemovalTests: XCTestCase {
    @MainActor
    func testNamedProfileRemovalPreservesUncheckedCategoriesAndOtherProfile() async throws {
        #if SKIP
        if isRobolectric { throw XCTSkip("Requires instrumented WebView") }
        if !WebEngine.isAndroidMultiProfileSupported() { throw XCTSkip("Named profiles unavailable") }
        // Native WebViews need the real main looper, not the generated XCTest test dispatcher.
        // SKIP INSERT: Dispatchers.resetMain()
        #endif
        let server = try WebsiteDataTestServer()
        print("[WebsiteDataFixture] BEGIN server.start")
        let url = try await server.start()
        print("[WebsiteDataFixture] END server.start url=\(url) \(server.diagnostics)")
        defer { server.stop() }
        let suffix = UUID().uuidString
        let profileA = WebProfile.named("clear-a-\(suffix)")
        let profileB = WebProfile.named("clear-b-\(suffix)")
        let keyA = "a-\(suffix)"
        let keyB = "b-\(suffix)"
        var a = await makeFixtureEngine(profile: profileA, operation: "A create engine", server: server)
        let b = await makeFixtureEngine(profile: profileB, operation: "B create engine", server: server)
        try await operation("A load fixture", server: server) { try await a.load(url: url) }
        try await operation("B load fixture", server: server) { try await b.load(url: url) }
        _ = try await script("await seed('A', '\(keyA)'); return true", operation: "A initial seed", engine: a, server: server)
        _ = try await script("await seed('B', '\(keyB)'); return true", operation: "B initial seed", engine: b, server: server)
        let beforeA = try await read(a, key: keyA, operation: "A initial read", server: server)
        let beforeB = try await read(b, key: keyB, operation: "B initial read", server: server)
        XCTAssertTrue(beforeA.contains("\"cache\":\"1\""))
        XCTAssertTrue(beforeB.contains("\"cache\":\"1\""))

        try await operation("A remove cache", server: server) {
            _ = try await a.removeBrowsingData(cookiesAndStorage: false, cache: true, modifiedSince: .distantPast)
        }
        let cacheCleared = try await read(a, key: keyA, operation: "A read after cache removal", server: server)
        XCTAssertTrue(cacheCleared.contains("\"cache\":\"2\""), cacheCleared)
        for field in ["local", "session", "indexed"] {
            XCTAssertTrue(cacheCleared.contains("\"\(field)\":\"A\""), cacheCleared)
        }
        XCTAssertTrue(cacheCleared.contains("fixture=A"), cacheCleared)
        let otherAfter1 = try await read(b, key: keyB, operation: "B read after A cache removal", server: server)
        XCTAssertEqual(otherAfter1, beforeB)

        // Retiring the profile also removes per-view sessionStorage. Logical tabs can recreate views.
        try await operation("A retire runtimes", server: server) { try await WebEngine.retireRuntimes(for: profileA) }
        a = await makeFixtureEngine(profile: profileA, operation: "A create engine", server: server)
        try await operation("A remove site data", server: server) {
            _ = try await a.removeBrowsingData(cookiesAndStorage: true, cache: false, modifiedSince: .distantPast)
        }
        try await operation("A load fixture", server: server) { try await a.load(url: url) }
        let siteCleared = try await read(a, key: keyA, operation: "A read after site-data removal", server: server)
        for field in ["local", "session", "indexed", "cookie"] {
            XCTAssertTrue(siteCleared.contains("\"\(field)\":\"\""), siteCleared)
        }
        XCTAssertTrue(siteCleared.contains("\"cache\":\"2\""), siteCleared)
        let otherAfter2 = try await read(b, key: keyB, operation: "B read after A site-data removal", server: server)
        XCTAssertEqual(otherAfter2, beforeB)

        _ = try await script("await seed('A', '\(keyA)'); return true", operation: "A reseed after site-data removal", engine: a, server: server)
        try await operation("A retire runtimes", server: server) { try await WebEngine.retireRuntimes(for: profileA) }
        a = await makeFixtureEngine(profile: profileA, operation: "A create engine", server: server)
        try await operation("A remove cache and site data", server: server) {
            _ = try await a.removeBrowsingData(cookiesAndStorage: true, cache: true, modifiedSince: .distantPast)
        }
        try await operation("A load fixture", server: server) { try await a.load(url: url) }
        let allCleared = try await read(a, key: keyA, operation: "A read after combined removal", server: server)
        XCTAssertTrue(allCleared.contains("\"cache\":\"3\""), allCleared)
        for field in ["local", "session", "indexed", "cookie"] {
            XCTAssertTrue(allCleared.contains("\"\(field)\":\"\""), allCleared)
        }
        let otherAfter3 = try await read(b, key: keyB, operation: "B read after A combined removal", server: server)
        XCTAssertEqual(otherAfter3, beforeB)
    }

    @MainActor
    private func makeFixtureEngine(profile: WebProfile, operation: String, server: WebsiteDataTestServer) async -> WebEngine {
        let started = Date()
        log(operation, "BEGIN", started: started, server: server)
        let engine = await makeCookieTestEngine(profile: profile)
        #if SKIP
        engine.webView.settings.javaScriptEnabled = true
        engine.webView.settings.domStorageEnabled = true
        #endif
        log(operation, "END", started: started, server: server)
        return engine
    }

    /// Logs before entering each native await, so an unreturned call still has a named start.
    @MainActor
    private func operation(_ name: String, server: WebsiteDataTestServer, body: @MainActor () async throws -> Void) async throws {
        let started = Date()
        log(name, "BEGIN", started: started, server: server)
        do {
            try await body()
            log(name, "END", started: started, server: server)
        } catch {
            log(name, "ERROR \(error)", started: started, server: server)
            throw error
        }
    }

    private func log(_ operation: String, _ message: String, started: Date, server: WebsiteDataTestServer) {
        print("[WebsiteDataFixture] \(operation) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000)) \(message) \(server.diagnostics)")
    }

    @MainActor
    private func read(_ engine: WebEngine, key: String, operation: String, server: WebsiteDataTestServer) async throws -> String {
        try await script("return await read('\(key)')", operation: operation, engine: engine, server: server)
    }

    /// Polls result and trace together; retains the last trace if a later evaluation fails.
    @MainActor
    private func script(_ body: String, operation: String, engine: WebEngine, server: WebsiteDataTestServer) async throws -> String {
        let started = Date()
        var diagnostics = "JavaScript has not reported a stage"
        log(operation, "BEGIN evaluate", started: started, server: server)
        do {
            _ = try await engine.evaluate(js: """
                window.fixtureResult = null;
                window.fixtureError = null;
                window.fixtureEvents = [];
                window.fixtureStarted = performance.now();
                fixtureEvent('script begin');
                (async () => { \(body) })().then(v => {
                  fixtureEvent('script complete');
                  window.fixtureResult = JSON.stringify(v);
                }, e => {
                  fixtureEvent('script error: ' + String(e));
                  window.fixtureError = String(e) + (e && e.stack ? ' ' + e.stack : '');
                });
                null
                """)
            log(operation, "END evaluate; BEGIN polling", started: started, server: server)
            for poll in 0..<200 {
                // A periodic start also identifies a native evaluate call that never returns.
                if poll % 20 == 0 { log(operation, "BEGIN poll=\(poll)", started: started, server: server) }
                let raw = try await engine.evaluate(js: "JSON.stringify({result: window.fixtureResult, error: window.fixtureError, trace: window.fixtureEvents.join(' | ')})")
                if let raw {
                    let json = (try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) as? String) ?? raw
                    let snapshot = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
                    let trace = snapshot?["trace"] as? String ?? "Missing fixture trace"
                    if trace != diagnostics {
                        diagnostics = trace
                        log(operation, "poll=\(poll) JS \(diagnostics)", started: started, server: server)
                    }
                    if let error = snapshot?["error"] as? String {
                        XCTFail("Fixture JavaScript failed: \(operation) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000)) error=\(error) trace=\(diagnostics) \(server.diagnostics)")
                        return "ERROR:" + error
                    }
                    if let result = snapshot?["result"] as? String {
                        log(operation, "END result=\(result)", started: started, server: server)
                        return result
                    }
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        } catch {
            log(operation, "ERROR \(error) lastTrace=\(diagnostics)", started: started, server: server)
            throw error
        }
        XCTFail("Fixture did not report JavaScript completion: \(operation) polls=200 elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000)) trace=\(diagnostics) \(server.diagnostics)")
        return "TIMEOUT"
    }
}
#endif
