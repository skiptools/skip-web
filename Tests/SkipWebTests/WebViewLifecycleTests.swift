// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if os(iOS) && !SKIP
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import SkipWeb

final class WebViewLifecycleTests: XCTestCase {
    @MainActor
    func testNavigatorOwnedEngineIsMountedWithoutCreatingAReplacement() {
        let navigator = WebViewNavigator()
        let ownedEngine = WebEngine(configuration: WebEngineConfiguration())
        navigator.webEngine = ownedEngine

        withMountedWebView(SkipWeb.WebView(navigator: navigator)) { mountedWebView in
            XCTAssertTrue(mountedWebView === ownedEngine.webView)
            XCTAssertTrue(navigator.webEngine === ownedEngine)
        }
    }

    @MainActor
    func testNavigatorOwnedChildUsesMountedScriptDelegate() async throws {
        try await verifyMountedScriptDelegate(persistentID: nil)
    }

    @MainActor
    func testPersistentEngineUsesMountedScriptDelegate() async throws {
        try await verifyMountedScriptDelegate(persistentID: "script-owner-\(UUID().uuidString)")
    }

    /// Exercises actual page messages after adoption, preserving the child's page and parent owner.
    @MainActor
    private func verifyMountedScriptDelegate(persistentID: String?) async throws {
        let parentSink = RecordingScriptDelegate()
        let childSink = RecordingScriptDelegate()
        let parentConfiguration = WebEngineConfiguration(
            scriptMessageHandlerNames: ["ownerProbe"],
            scriptMessageDelegate: parentSink,
            capturesConsoleOutput: false
        )
        let inheritedConfiguration = parentConfiguration.popupChildMirroredConfiguration()
        let engine: WebEngine
        if let persistentID {
            engine = SkipWeb.WebView.preparePersistentEngine(id: persistentID, configuration: inheritedConfiguration)
        } else {
            engine = WebEngine(configuration: inheritedConfiguration)
            engine.refreshMessageHandlers()
        }
        defer {
            if let persistentID { SkipWeb.WebView.removePersistentWebView(id: persistentID) }
        }
        try await engine.awaitPageLoaded {
            engine.loadHTML("<html><body><script>window.mediaId = 'child-media-id';</script></body></html>")
        }
        let navigator = WebViewNavigator()
        if persistentID == nil { navigator.webEngine = engine }
        let mountedConfiguration = WebEngineConfiguration(
            scriptMessageHandlerNames: ["ownerProbe"],
            scriptMessageDelegate: childSink,
            capturesConsoleOutput: false
        )
        let host = UIHostingController(rootView: SkipWeb.WebView(
            configuration: mountedConfiguration, navigator: navigator, persistentWebViewID: persistentID
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        XCTAssertTrue(navigator.webEngine === engine)
        XCTAssertTrue(findWebView(in: host.view) === engine.webView)
        // Sending after mount must use the new owner without reloading the document or its ID.
        _ = try await engine.webView.evaluateJavaScript("window.webkit.messageHandlers.ownerProbe.postMessage(window.mediaId); true")
        for _ in 0..<50 {
            if !childSink.messages.isEmpty || !parentSink.messages.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(childSink.messages, ["\"child-media-id\""])
        XCTAssertTrue(parentSink.messages.isEmpty)
        XCTAssertTrue(parentConfiguration.scriptMessageDelegate === parentSink)
    }

    @MainActor
    func testUnderlyingWebViewIsReleasedAfterSwiftUIHostIsReleased() {
        let retainedWebView = mountAndRelease(SkipWeb.WebView())

        drainMainRunLoop()
        XCTAssertNil(retainedWebView.value)
    }

    @MainActor
    func testPersistentWebViewIsReleasedAfterCacheEviction() {
        let persistentWebViewID = "lifecycle-\(UUID().uuidString)"
        let retainedWebView = mountAndRelease(SkipWeb.WebView(persistentWebViewID: persistentWebViewID))
        let retainedEngine = WeakReference<WebEngine>()
        retainedEngine.value = SkipWeb.WebView.cachedPersistentWebEngine(id: persistentWebViewID)

        drainMainRunLoop()
        XCTAssertNotNil(retainedWebView.value)
        XCTAssertNotNil(retainedEngine.value)

        SkipWeb.WebView.removePersistentWebView(id: persistentWebViewID)
        drainMainRunLoop()
        XCTAssertNil(SkipWeb.WebView.cachedPersistentWebEngine(id: persistentWebViewID))
        XCTAssertNil(retainedEngine.value)
        XCTAssertNil(retainedWebView.value)
    }

    @MainActor
    func testPreparedEngineLoadsScriptsWithoutMountingThenAdoptsSamePage() async throws {
        let id = "prepared-\(UUID().uuidString)"
        defer { SkipWeb.WebView.removePersistentWebView(id: id) }
        let configuration = WebEngineConfiguration(
            userScripts: [WebViewUserScript(source: "window.preparedToken = 'ready';", injectionTime: .atDocumentStart, forMainFrameOnly: true)],
            scriptMessageHandlerNames: ["preparedBridge"]
        )
        let engine = SkipWeb.WebView.preparePersistentEngine(id: id, configuration: configuration)
        XCTAssertNil(engine.webView.superview)
        XCTAssertNil(engine.webView.window)
        XCTAssertFalse(engine.hasRequestedContent)
        let reused = SkipWeb.WebView.preparePersistentEngine(id: id, configuration: WebEngineConfiguration(javaScriptEnabled: false))
        XCTAssertTrue(engine === reused)
        XCTAssertTrue(engine.configuration === configuration)
        try await engine.awaitPageLoaded {
            engine.loadHTML("<html><body><script>window.pageToken = 'original'</script></body></html>")
        }
        let result = try await engine.evaluate(js: "[window.preparedToken, window.pageToken, typeof window.webkit.messageHandlers.preparedBridge].join(',')")
        XCTAssertEqual(result, "\"ready,original,object\"")
        let navigator = WebViewNavigator()
        withMountedWebView(SkipWeb.WebView(configuration: configuration, navigator: navigator, url: URL(string: "https://example.invalid/should-not-load"), persistentWebViewID: id)) { view in
            XCTAssertTrue(view === engine.webView)
            XCTAssertTrue(navigator.webEngine === engine)
        }
        let token = try await engine.evaluate(js: "window.pageToken")
        XCTAssertEqual(token, "\"original\"")
    }

    @MainActor
    func testMountBeforeFirstNavigationCompletesPreservesLoadDelegate() async throws {
        let id = "inflight-\(UUID().uuidString)"
        defer { SkipWeb.WebView.removePersistentWebView(id: id) }
        let engine = SkipWeb.WebView.preparePersistentEngine(id: id, configuration: WebEngineConfiguration())
        let navigator = WebViewNavigator()
        var host: UIHostingController<SkipWeb.WebView>?
        var window: UIWindow?
        defer {
            window?.isHidden = true
            window?.rootViewController = nil
            host = nil
        }
        try await engine.awaitPageLoaded {
            engine.loadHTML("<html><body>in flight</body></html>")
            host = UIHostingController(rootView: SkipWeb.WebView(navigator: navigator, url: URL(string: "https://example.invalid/duplicate"), persistentWebViewID: id))
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
            window?.rootViewController = host
            window?.makeKeyAndVisible()
            host?.view.layoutIfNeeded()
        }
        XCTAssertTrue(navigator.webEngine === engine)
        let body = try await engine.evaluate(js: "document.body.textContent")
        XCTAssertEqual(body, "\"in flight\"")
    }

    @MainActor
    func testMountTransfersPreparedPopupOwnershipAndCloseHandling() throws {
        let id = "prepared-popup-\(UUID().uuidString)"
        defer { SkipWeb.WebView.removePersistentWebView(id: id) }
        let closeDelegate = PopupCloseDelegate()
        let configuration = WebEngineConfiguration(uiDelegate: closeDelegate)
        let engine = SkipWeb.WebView.preparePersistentEngine(id: id, configuration: configuration)
        let preparedCoordinator = try XCTUnwrap(engine.preparedUIDelegate)
        let retainedChild = WeakReference<WebEngine>()
        let childID = autoreleasepool {
            let child = WebEngine()
            let childID = ObjectIdentifier(child.webView)
            // Model a popup returned by createWebViewWith before its parent is mounted.
            preparedCoordinator.childEnginesByWebViewID[childID] = child
            retainedChild.value = child
            return childID
        }

        withMountedWebView(SkipWeb.WebView(configuration: configuration, persistentWebViewID: id)) { view in
            guard let mountedCoordinator = view.uiDelegate as? WebViewCoordinator else {
                XCTFail("Expected the mounted coordinator")
                return
            }
            XCTAssertNil(engine.preparedUIDelegate)
            XCTAssertTrue(preparedCoordinator.childEnginesByWebViewID.isEmpty)
            XCTAssertNotNil(retainedChild.value)
            XCTAssertTrue(mountedCoordinator.childEnginesByWebViewID[childID] === retainedChild.value)
            if let childView = retainedChild.value?.webView {
                mountedCoordinator.webViewDidClose(childView)
            }
            XCTAssertEqual(closeDelegate.closedChildID, childID)
            XCTAssertTrue(mountedCoordinator.childEnginesByWebViewID.isEmpty)
        }
        drainMainRunLoop()
        XCTAssertNil(retainedChild.value)
    }

    @MainActor
    func testRemovingPreparedEngineAllowsFreshPreparation() {
        let id = "replace-\(UUID().uuidString)"
        let first = SkipWeb.WebView.preparePersistentEngine(id: id, configuration: WebEngineConfiguration())
        SkipWeb.WebView.removePersistentWebView(id: id)
        let second = SkipWeb.WebView.preparePersistentEngine(id: id, configuration: WebEngineConfiguration())
        defer { SkipWeb.WebView.removePersistentWebView(id: id) }
        XCTAssertFalse(first === second)
        XCTAssertFalse(second.hasRequestedContent)
    }

    /// Records the receiving owner while using the real platform script-message transport.
    @MainActor
    private final class RecordingScriptDelegate: WebViewScriptMessageDelegate {
        var messages: [String] = []

        func webEngine(_ webEngine: WebEngine, didReceiveScriptMessage message: WebViewScriptMessage) {
            messages.append(message.bodyJSON)
        }
    }

    @MainActor
    private func mountAndRelease(_ webView: SkipWeb.WebView) -> WeakReference<WKWebView> {
        let retainedWebView = WeakReference<WKWebView>()

        autoreleasepool {
            let host = UIHostingController(rootView: webView)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()

            retainedWebView.value = findWebView(in: host.view)
            XCTAssertNotNil(retainedWebView.value)

            window.rootViewController = nil
            window.isHidden = true
        }

        return retainedWebView
    }

    @MainActor
    private func withMountedWebView(
        _ webView: SkipWeb.WebView,
        assertions: (WKWebView) -> Void
    ) {
        autoreleasepool {
            let host = UIHostingController(rootView: webView)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()

            guard let mountedWebView = findWebView(in: host.view) else {
                XCTFail("Expected a mounted WKWebView")
                return
            }
            assertions(mountedWebView)

            window.rootViewController = nil
            window.isHidden = true
        }
    }

    @MainActor
    private func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView {
            return webView
        }
        for subview in view.subviews {
            if let webView = findWebView(in: subview) {
                return webView
            }
        }
        return nil
    }

    @MainActor
    private func drainMainRunLoop(iterations: Int = 5) {
        for _ in 0..<iterations {
            autoreleasepool {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?
}

@MainActor
private final class PopupCloseDelegate: @preconcurrency SkipWebUIDelegate {
    var closedChildID: ObjectIdentifier?

    func webViewDidClose(_ webView: SkipWeb.WebView, child: WebEngine) {
        closedChildID = ObjectIdentifier(child.webView)
    }
}
#endif
