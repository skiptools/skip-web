// Copyright 2024–2026 Skip
import XCTest
#if os(iOS) && !SKIP
import WebKit
@testable import SkipWeb

final class PersistentScriptMessageHandlerTests: XCTestCase {
    @MainActor
    func testRefreshingAfterPersistentWebViewRebindRestoresPageWorldMessageHandler() async throws {
        let handlerName = "persistentBridge"
        let configuration = WebEngineConfiguration(
            scriptMessageHandlerNames: [handlerName],
            capturesConsoleOutput: false
        )
        let engine = WebEngine(configuration: configuration)

        engine.refreshMessageHandlers()
        try await loadProbePage(in: engine)
        let initiallyInstalledType = try await handlerType(named: handlerName, in: engine)
        XCTAssertEqual(initiallyInstalledType, "object")

        // Match WebView.makeWebEngine's cached-engine rebind path.
        engine.webView.configuration.userContentController.removeScriptMessageHandler(
            forName: handlerName,
            contentWorld: .page
        )
        engine.refreshMessageHandlers()
        try await loadProbePage(in: engine)

        let refreshedType = try await handlerType(named: handlerName, in: engine)
        XCTAssertEqual(refreshedType, "object")
    }

    @MainActor
    private func loadProbePage(in engine: WebEngine) async throws {
        try await engine.awaitPageLoaded {
            engine.loadHTML("<html><body>message-handler probe</body></html>")
        }
    }

    @MainActor
    private func handlerType(named handlerName: String, in engine: WebEngine) async throws -> String {
        let result = try await engine.evaluate(
            js: "typeof window.webkit?.messageHandlers?.\(handlerName)"
        )
        let encodedResult = try XCTUnwrap(result)
        let data = try XCTUnwrap(encodedResult.data(using: .utf8))
        return try JSONDecoder().decode(String.self, from: data)
    }
}
#endif
