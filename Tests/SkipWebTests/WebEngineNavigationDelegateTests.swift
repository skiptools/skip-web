// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if os(iOS) && !SKIP
import XCTest
import WebKit
@testable import SkipWeb

final class WebEngineNavigationDelegateTests: XCTestCase {
    @MainActor
    private final class RecordingNavigationDelegate: SkipWebNavigationDelegate {
        var requestedURLs: [URL] = []
        var events: [String] = []

        func webEngine(_ engine: WebEngine, shouldOverrideURLLoading url: URL) -> Bool {
            requestedURLs.append(url)
            return false
        }

        func webEngineDidStartProvisionalNavigation(_ engine: WebEngine) {
            events.append("started")
        }

        func webEngineDidCommitNavigation(_ engine: WebEngine) {
            events.append("committed")
        }

        func webEngineDidFinishNavigation(_ engine: WebEngine) {
            events.append("finished")
        }

        func webEngine(_ engine: WebEngine, didFailNavigation error: Error) {
            events.append("failed")
        }
    }

    @MainActor
    func testLoadForwardsNavigationCallbacksToConfigurationDelegate() async throws {
        let delegate = RecordingNavigationDelegate()
        let configuration = WebEngineConfiguration(navigationDelegate: delegate)
        let engine = WebEngine(configuration: configuration)
        let url = try XCTUnwrap(URL(string: "about:blank"))

        try await engine.load(url: url)

        XCTAssertEqual(delegate.requestedURLs, [url])
        XCTAssertEqual(delegate.events, ["started", "committed", "finished"])
        XCTAssertFalse(engine.hasPendingURLLoad)
    }

    @MainActor
    func testRejectedProfileFinishesPendingURLLoad() async {
        let engine = WebEngine(configuration: WebEngineConfiguration(profile: .named("")))
        do {
            try await engine.load(url: URL(string: "about:blank")!)
            XCTFail("Invalid profile should reject navigation")
        } catch {
            XCTAssertTrue(engine.hasRequestedContent)
            XCTAssertFalse(engine.hasPendingURLLoad)
            XCTAssertNil(engine.url)
        }
    }
    @MainActor
    func testCancelledLoadCannotClearReplacementReservation() async throws {
        let started = expectation(description: "First navigation started")
        let handler = StalledSchemeHandler(started: started)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "pending-test")
        let engine = WebEngine(webView: WKWebView(frame: .zero, configuration: configuration))
        let first = Task { try await engine.load(url: URL(string: "pending-test://first")!) }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(engine.hasPendingURLLoad)

        engine.stopLoading()
        let navigator = WebViewNavigator()
        navigator.webEngine = engine
        navigator.load(url: URL(string: "pending-test://replacement")!)
        do {
            try await first.value
            XCTFail("Stopped navigation should fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(engine.hasPendingURLLoad, "Old completion must preserve the replacement")
        engine.stopLoading()
        XCTAssertFalse(engine.hasPendingURLLoad)
    }

    @MainActor
    func testContentProcessTerminationFinishesPendingURLLoad() async throws {
        let started = expectation(description: "Navigation started")
        let handler = StalledSchemeHandler(started: started)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "pending-test")
        let engine = WebEngine(webView: WKWebView(frame: .zero, configuration: configuration))
        let load = Task { try await engine.load(url: URL(string: "pending-test://terminated")!) }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(engine.hasPendingURLLoad)
        engine.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(engine.webView)
        do {
            try await load.value
            XCTFail("Terminated content process should fail navigation")
        } catch {
            XCTAssertEqual((error as NSError).domain, WKErrorDomain)
            XCTAssertEqual((error as NSError).code, WKError.webContentProcessTerminated.rawValue)
        }
        XCTAssertFalse(engine.hasPendingURLLoad)
        engine.stopLoading()
    }

    /// Holds real WebKit navigation open until the test cancels it or reports termination.
    private final class StalledSchemeHandler: NSObject, WKURLSchemeHandler {
        private var started: XCTestExpectation?

        init(started: XCTestExpectation) { self.started = started }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            started?.fulfill()
            started = nil
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    }

}
#endif
