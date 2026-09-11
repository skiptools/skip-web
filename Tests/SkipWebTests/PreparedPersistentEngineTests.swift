// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import SkipWeb

#if SKIP || os(iOS)
final class PreparedPersistentEngineTests: XCTestCase {
    // SKIP INSERT: @androidx.test.annotation.UiThreadTest
    @MainActor
    func testPreparationReusesConfigurationAndEvictionReplacesEngine() {
        let id = "preparation-\(UUID().uuidString)"
        let config = WebEngineConfiguration(customUserAgent: "PreparedEngineTest")
        let first = WebView.preparePersistentEngine(id: id, configuration: config)
        let second = WebView.preparePersistentEngine(id: id, configuration: WebEngineConfiguration())
        XCTAssertTrue(first === second)
        XCTAssertTrue(first.configuration === config)
        XCTAssertFalse(first.hasRequestedContent)
        #if SKIP
        XCTAssertNil(first.webView.parent)
        XCTAssertTrue(first.webView.settings.javaScriptEnabled)
        XCTAssertTrue(first.webView.settings.domStorageEnabled)
        XCTAssertEqual(first.webView.settings.userAgentString, "PreparedEngineTest")
        #else
        XCTAssertNil(first.webView.superview)
        #endif
        WebView.removePersistentWebView(id: id)
        let replacement = WebView.preparePersistentEngine(id: id, configuration: config)
        XCTAssertFalse(first === replacement)
        WebView.removePersistentWebView(id: id)
    }

    // SKIP INSERT: @androidx.test.annotation.UiThreadTest
    @MainActor
    func testNavigatorReservesInitialLoadBeforeReturningAndEvictionCancelsIt() {
        let id = "queued-\(UUID().uuidString)"
        let engine = WebView.preparePersistentEngine(id: id, configuration: WebEngineConfiguration())
        let navigator = WebViewNavigator()
        navigator.webEngine = engine
        navigator.load(url: URL(string: "about:blank")!)
        XCTAssertTrue(engine.hasRequestedContent)
        WebView.removePersistentWebView(id: id)
        XCTAssertNil(WebView.cachedPersistentWebEngine(id: id))
    }

    // Keep Android's real UI dispatcher available while WebView delivers callbacks.
    // Skip's generated async XCTest wrapper replaces it with a virtual-time dispatcher.
    /* SKIP INSERT:
    @Test
    fun testPreparedEngineLoadsDocumentStartScriptAndMessageTransport() = kotlinx.coroutines.runBlocking {
        kotlinx.coroutines.withTimeout(15_000) {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                verifyPreparedDocument()
            }
        }
    }
    */
    #if !SKIP
    @MainActor
    func testPreparedEngineLoadsDocumentStartScriptAndMessageTransport() async throws {
        try await verifyPreparedDocument()
    }
    #endif

    @MainActor
    private func verifyPreparedDocument() async throws {
        let id = "prepared-script-\(UUID().uuidString)"
        let config = WebEngineConfiguration(
            userScripts: [WebViewUserScript(source: "window.preparedValue = 42;", injectionTime: .atDocumentStart, forMainFrameOnly: true)],
            scriptMessageHandlerNames: ["prepared"]
        )
        let engine = WebView.preparePersistentEngine(id: id, configuration: config)
        defer { WebView.removePersistentWebView(id: id) }
        try await engine.awaitPageLoaded {
            engine.loadHTML("<html><body>prepared</body></html>")
        }
        let value = try await engine.evaluate(js: "window.preparedValue")
        XCTAssertEqual(value, "42")
        let bridge = try await engine.evaluate(js: "typeof window.webkit.messageHandlers.prepared.postMessage")
        XCTAssertEqual(bridge, "\"function\"")
    }
}
#endif
