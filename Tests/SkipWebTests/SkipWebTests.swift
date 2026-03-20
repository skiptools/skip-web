// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
import XCTest
import OSLog
import Foundation
#if !SKIP
import WebKit
#else
import androidx.webkit.WebViewFeature
#endif
@testable import SkipWeb

let logger: Logger = Logger(subsystem: "SkipWeb", category: "Tests")

// SKIP INSERT: @androidx.test.annotation.UiThreadTest
final class SkipWebTests: XCTestCase {
    #if SKIP || os(iOS)

    final class DummyUIDelegate: SkipWebUIDelegate { }
    final class NoOpScrollDelegate: SkipWebScrollDelegate { }

    @MainActor
    final class RecordingScrollDelegate: SkipWebScrollDelegate {
        var events: [String] = []
        var snapshots: [WebScrollViewProxy] = []

        func scrollViewDidScroll(_ scrollView: WebScrollViewProxy) {
            events.append("didScroll")
            snapshots.append(scrollView)
        }

        func scrollViewWillBeginDragging(_ scrollView: WebScrollViewProxy) {
            events.append("willBeginDragging")
            snapshots.append(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: WebScrollViewProxy, willDecelerate decelerate: Bool) {
            events.append("didEndDragging:\(decelerate)")
            snapshots.append(scrollView)
        }

        func scrollViewWillBeginDecelerating(_ scrollView: WebScrollViewProxy) {
            events.append("willBeginDecelerating")
            snapshots.append(scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: WebScrollViewProxy) {
            events.append("didEndDecelerating")
            snapshots.append(scrollView)
        }
    }

    #if !SKIP
    final class TestScrollView: UIScrollView {
        var forcedTracking = false
        var forcedDragging = false
        var forcedDecelerating = false

        override var isTracking: Bool { forcedTracking }
        override var isDragging: Bool { forcedDragging }
        override var isDecelerating: Bool { forcedDecelerating }
    }
    #endif

    func testSkipWeb() throws {
        logger.log("running testSkipWeb")
        XCTAssertEqual(1 + 2, 3, "basic test")

        if isRobolectric {
            throw XCTSkip("Bundle.module resource loading requires instrumented Android context in Robolectric CI")
        }
        
        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try XCTUnwrap(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        XCTAssertEqual("SkipWeb", testData.testModuleName)
    }

    func testWindowConfigurationDefaults() {
        let config = WebEngineConfiguration()
        XCTAssertFalse(config.javaScriptCanOpenWindowsAutomatically)
        XCTAssertNil(config.uiDelegate)
        XCTAssertEqual(config.profile, WebProfile.default)
    }

    func testPopupChildMirroredConfigurationPreservesProfile() {
        let config = WebEngineConfiguration(profile: .named("popup-profile"))
        let mirrored = config.popupChildMirroredConfiguration()
        XCTAssertEqual(mirrored.profile, .named("popup-profile"))
    }

    func testWebWindowRequestCarriesFields() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://source.example"))
        let targetURL = try XCTUnwrap(URL(string: "https://target.example"))
        let request = WebWindowRequest(
            sourceURL: sourceURL,
            targetURL: targetURL,
            isUserGesture: true,
            isDialog: false,
            isMainFrame: true
        )
        XCTAssertEqual(request.sourceURL?.absoluteString, sourceURL.absoluteString)
        XCTAssertEqual(request.targetURL?.absoluteString, targetURL.absoluteString)
        XCTAssertEqual(request.isUserGesture, true)
        XCTAssertEqual(request.isDialog, false)
        XCTAssertEqual(request.isMainFrame, true)
    }

    func testConfigurationAcceptsUIDelegate() {
        let config = WebEngineConfiguration()
        config.uiDelegate = DummyUIDelegate()
        XCTAssertNotNil(config.uiDelegate)
    }

    @MainActor
    func testWebScrollViewProxyIdentityEquality() {
        let proxy = WebScrollViewProxy()
        XCTAssertEqual(proxy, proxy)
        XCTAssertNotEqual(proxy, WebScrollViewProxy())
    }

    @MainActor
    func testNoOpScrollDelegateDefaults() {
        let delegate = NoOpScrollDelegate()
        let proxy = WebScrollViewProxy()
        delegate.scrollViewDidScroll(proxy)
        delegate.scrollViewWillBeginDragging(proxy)
        delegate.scrollViewDidEndDragging(proxy, willDecelerate: false)
        delegate.scrollViewWillBeginDecelerating(proxy)
        delegate.scrollViewDidEndDecelerating(proxy)
    }

    @MainActor
    func testWebViewInitializerAcceptsScrollDelegate() {
        let delegate = NoOpScrollDelegate()
        let view = WebView(scrollDelegate: delegate)
        let coordinator = view.makeCoordinator()
        XCTAssertNotNil(coordinator.publicScrollDelegate)
    }

    #if !SKIP
    @MainActor
    func testIOSScrollDelegateCallbacksUseProxy() {
        let delegate = RecordingScrollDelegate()
        let view = WebView(scrollDelegate: delegate)
        let coordinator = view.makeCoordinator()

        let scrollView = TestScrollView(frame: CGRect(x: 0, y: 0, width: 120, height: 200))
        scrollView.contentSize = CGSize(width: 120, height: 600)
        scrollView.contentOffset = CGPoint(x: 0, y: 40)
        scrollView.forcedTracking = true
        scrollView.forcedDragging = true

        coordinator.scrollViewWillBeginDragging(scrollView)
        coordinator.scrollViewDidScroll(scrollView)

        scrollView.forcedTracking = false
        scrollView.forcedDragging = false
        coordinator.scrollViewDidEndDragging(scrollView, willDecelerate: true)

        scrollView.forcedDecelerating = true
        coordinator.scrollViewWillBeginDecelerating(scrollView)

        scrollView.forcedDecelerating = false
        coordinator.scrollViewDidEndDecelerating(scrollView)

        XCTAssertEqual(
            delegate.events,
            ["willBeginDragging", "didScroll", "didEndDragging:true", "willBeginDecelerating", "didEndDecelerating"]
        )
        XCTAssertTrue(delegate.snapshots.allSatisfy { $0 === coordinator.scrollViewProxy })
        XCTAssertEqual(coordinator.scrollViewProxy.contentOffset.y, 40)
        XCTAssertEqual(coordinator.scrollViewProxy.visibleSize.height, 200)
        XCTAssertEqual(coordinator.scrollViewProxy.contentSize.height, 600)
        XCTAssertTrue(coordinator.state.scrollingDown)
    }

    @MainActor
    func testIOSScrollDelegateCanBeReplacedOnUpdate() {
        let initialDelegate = RecordingScrollDelegate()
        let replacementDelegate = RecordingScrollDelegate()
        let initialView = WebView(scrollDelegate: initialDelegate)
        let coordinator = initialView.makeCoordinator()
        coordinator.update(from: WebView(scrollDelegate: replacementDelegate))

        let scrollView = TestScrollView(frame: CGRect(x: 0, y: 0, width: 120, height: 200))
        scrollView.contentSize = CGSize(width: 120, height: 600)
        scrollView.contentOffset = CGPoint(x: 0, y: 40)
        scrollView.forcedTracking = true
        scrollView.forcedDragging = true

        coordinator.scrollViewDidScroll(scrollView)

        XCTAssertTrue(initialDelegate.events.isEmpty)
        XCTAssertEqual(replacementDelegate.events, ["didScroll"])
    }
    #endif

    #if SKIP
    func testAndroidScaledContentSizeUsesScale() {
        let size = AndroidScrollTracker.scaledContentSize(
            visibleSize: CGSize(width: 120, height: 200),
            contentWidth: 80.0,
            contentHeight: 300.0,
            scale: 2.0
        )
        XCTAssertEqual(size.width, 160.0)
        XCTAssertEqual(size.height, 600.0)
    }

    @MainActor
    func testAndroidScrollTrackerCallbacks() async throws {
        if !isAndroid {
            throw XCTSkip("testAndroidScrollTrackerCallbacks only runs on Android")
        }

        let delegate = RecordingScrollDelegate()
        let config = WebEngineConfiguration()
        let ctx = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        config.context = ctx

        let view = WebView(configuration: config, scrollDelegate: delegate)
        let coordinator = view.makeCoordinator()
        let platformWebView = PlatformWebView(ctx)
        coordinator.configureAndroidScrollTracking(webView: platformWebView)
        let tracker = try XCTUnwrap(coordinator.androidScrollTracker)
        platformWebView.layout(0, 0, 120, 200)

        tracker.handleTouchDown(at: CGPoint(x: 0, y: 0), webView: platformWebView)
        tracker.handleTouchMove(to: CGPoint(x: 0, y: 40), webView: platformWebView)
        XCTAssertEqual(delegate.snapshots.first?.visibleSize.height, 200)
        XCTAssertEqual(delegate.snapshots.first?.contentSize.height, 200)
        tracker.handleScrollChanged(
            scrollX: 0,
            scrollY: 100,
            oldScrollX: 0,
            oldScrollY: 20,
            visibleSize: CGSize(width: 120, height: 200),
            contentSize: CGSize(width: 120, height: 600)
        )
        tracker.handleTouchEnd(velocity: CGPoint(x: 0, y: 10))

        XCTAssertEqual(delegate.events, ["willBeginDragging", "didScroll", "didEndDragging:false"])
        XCTAssertTrue(coordinator.state.scrollingDown)

        delegate.events.removeAll()

        tracker.handleTouchDown(at: CGPoint(x: 0, y: 0), webView: platformWebView)
        tracker.handleTouchMove(to: CGPoint(x: 0, y: 50), webView: platformWebView)
        tracker.handleScrollChanged(
            scrollX: 0,
            scrollY: 180,
            oldScrollX: 0,
            oldScrollY: 120,
            visibleSize: CGSize(width: 120, height: 200),
            contentSize: CGSize(width: 120, height: 600)
        )
        tracker.handleTouchEnd(velocity: CGPoint(x: 0, y: 10_000))
        tracker.handleScrollChanged(
            scrollX: 0,
            scrollY: 260,
            oldScrollX: 0,
            oldScrollY: 180,
            visibleSize: CGSize(width: 120, height: 200),
            contentSize: CGSize(width: 120, height: 600)
        )

        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(
            delegate.events,
            ["willBeginDragging", "didScroll", "didEndDragging:true", "willBeginDecelerating", "didScroll", "didEndDecelerating"]
        )
        XCTAssertFalse(coordinator.scrollViewProxy.isDecelerating)
    }
    #endif

    func testSnapshotConfigurationDefaults() {
        let config = SkipWebSnapshotConfiguration()
        XCTAssertTrue(config.rect.isNull)
        XCTAssertNil(config.snapshotWidth)
        XCTAssertTrue(config.afterScreenUpdates)
    }

    func testSnapshotConfigurationFieldRoundTrip() {
        let rect = SkipWebSnapshotRect(x: 10, y: 20, width: 120, height: 80)
        let config = SkipWebSnapshotConfiguration(rect: rect, snapshotWidth: 64, afterScreenUpdates: false)
        XCTAssertEqual(config.rect, rect)
        XCTAssertEqual(config.snapshotWidth, 64)
        XCTAssertFalse(config.afterScreenUpdates)
    }

    @MainActor func testTakeSnapshotDefault() async throws {
        if isAndroid {
            throw XCTSkip("testTakeSnapshotDefault only runs on iOS")
        }
        #if !SKIP
        let config = WebEngineConfiguration()
        let platformWebView = PlatformWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config.webViewConfiguration)
        let engine = WebEngine(configuration: config, webView: platformWebView)
        engine.refreshMessageHandlers()
        engine.updateUserScripts()

        try await engine.awaitPageLoaded {
            engine.loadHTML("<html><body style='margin:0;background:#00AEEF;'><div style='width:320px;height:240px;'>snapshot</div></body></html>")
        }

        let snapshot: SkipWebSnapshot
        do {
            snapshot = try await takeSnapshotWithTimeout(engine)
        } catch SnapshotTestTimeoutError.timedOut {
            throw XCTSkip("WKWebView snapshot timed out on iOS simulator CI")
        } catch {
            let nsError = error as NSError
            if nsError.domain == "WKErrorDomain", nsError.code == 1 {
                throw XCTSkip("WKWebView snapshot returned WKErrorDomain Code=1 on iOS simulator CI")
            }
            throw error
        }
        XCTAssertFalse(snapshot.pngData.isEmpty)
        XCTAssertGreaterThan(snapshot.pixelWidth, 0)
        XCTAssertGreaterThan(snapshot.pixelHeight, 0)
        #endif
    }

    @MainActor func testTakeSnapshotRectAndWidth() async throws {
        if isAndroid {
            throw XCTSkip("testTakeSnapshotRectAndWidth only runs on iOS")
        }
        #if !SKIP
        let config = WebEngineConfiguration()
        let platformWebView = PlatformWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config.webViewConfiguration)
        let engine = WebEngine(configuration: config, webView: platformWebView)
        engine.refreshMessageHandlers()
        engine.updateUserScripts()

        try await engine.awaitPageLoaded {
            engine.loadHTML("<html><body style='margin:0;background:#333;'><div style='width:320px;height:240px;background:#FA2;'>snapshot</div></body></html>")
        }

        let rect = SkipWebSnapshotRect(x: 20, y: 30, width: 120, height: 80)
        let requestedWidth = 60.0
        let snapshotConfiguration = SkipWebSnapshotConfiguration(rect: rect, snapshotWidth: requestedWidth, afterScreenUpdates: true)
        let snapshot: SkipWebSnapshot
        do {
            snapshot = try await takeSnapshotWithTimeout(engine, configuration: snapshotConfiguration)
        } catch SnapshotTestTimeoutError.timedOut {
            throw XCTSkip("WKWebView snapshot (rect/width) timed out on iOS simulator CI")
        } catch {
            let nsError = error as NSError
            if nsError.domain == "WKErrorDomain", nsError.code == 1 {
                throw XCTSkip("WKWebView snapshot (rect/width) returned WKErrorDomain Code=1 on iOS simulator CI")
            }
            throw error
        }
        XCTAssertFalse(snapshot.pngData.isEmpty)
        XCTAssertGreaterThan(snapshot.pixelWidth, 0)
        XCTAssertGreaterThan(snapshot.pixelHeight, 0)
        XCTAssertGreaterThanOrEqual(snapshot.pixelWidth, Int(requestedWidth))
        XCTAssertEqual(Double(snapshot.pixelHeight) / Double(snapshot.pixelWidth), Double(rect.height / rect.width), accuracy: 0.05)
        #endif
    }

    func testTakeSnapshotDefaultAndroid() async throws {
        if !isAndroid {
            throw XCTSkip("testTakeSnapshotDefaultAndroid only runs on Android")
        }
        // Temporarily disabled: this test repeatedly stalls Android instrumentation
        // (white-screen hang) while waiting for WebView snapshot completion.
        // Coverage is deferred to manual device testing until a stable async model is in place.
        throw XCTSkip("Temporarily disabled on Android due to instrumentation stall; verify snapshot behavior manually on device.")

        /*
        if isRobolectric {
            throw XCTSkip("testTakeSnapshotDefaultAndroid requires instrumented Android environment")
        }

        #if SKIP
        var createdEngineForSnapshot: WebEngine? = nil
        let instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            let config = WebEngineConfiguration()
            let ctx = instrumentation.targetContext
            config.context = ctx
            let platformWebView = PlatformWebView(ctx)

            let width = 320
            let height = 200
            let widthSpec = android.view.View.MeasureSpec.makeMeasureSpec(width, android.view.View.MeasureSpec.EXACTLY)
            let heightSpec = android.view.View.MeasureSpec.makeMeasureSpec(height, android.view.View.MeasureSpec.EXACTLY)
            platformWebView.measure(widthSpec, heightSpec)
            platformWebView.layout(0, 0, width, height)

            let createdEngine = WebEngine(configuration: config, webView: platformWebView)
            createdEngine.loadHTML("<html><body style='margin:0;background:#118866;'><div style='width:320px;height:200px;'>snapshot</div></body></html>")
            createdEngineForSnapshot = createdEngine
        }

        let snapshotEngine = try XCTUnwrap(createdEngineForSnapshot)
        let snapshot = try await snapshotEngine.takeSnapshot(
            configuration: SkipWebSnapshotConfiguration(afterScreenUpdates: false)
        )
        XCTAssertFalse(snapshot.pngData.isEmpty)
        XCTAssertGreaterThan(snapshot.pixelWidth, 0)
        XCTAssertGreaterThan(snapshot.pixelHeight, 0)
        #endif
        */
    }

    func testOnWebView() async throws {
        if !isAndroid {
            throw XCTSkip("testOnWebView only works for Android")
        }

        let config = WebEngineConfiguration()

        #if SKIP

        func html(title: String, body: String = "") -> String {
            "<html><head><title>\(title)</title></head><body>\(body)</body></html>"
        }

        var outerEngine: WebEngine? = nil

        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
            let ctx = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
            config.context = ctx
            let platformWebView = PlatformWebView(ctx)
            let webEngine = WebEngine(configuration: config, webView: platformWebView)
            webEngine.loadHTML(html(title: "HELLO"))
            outerEngine = webEngine
        }

        let engine = try XCTUnwrap(outerEngine)

        // hangs
        //androidx.test.espresso.web.sugar.Web.onWebView()
        //    .withElement(androidx.test.espresso.web.webdriver.DriverAtoms.findElement(androidx.test.espresso.web.webdriver.Locator.TAG_NAME, "title"))
        //    .check(androidx.test.espresso.web.assertion.WebViewAssertions.webMatches(androidx.test.espresso.web.webdriver.DriverAtoms.getText(), org.hamcrest.CoreMatchers.containsString("HELLO")))

        // must be on main, or else: java.lang.RuntimeException: java.lang.Throwable: A WebView method was called on thread 'DefaultDispatcher-worker-1'. All WebView methods must be called on the same thread. (Expected Looper Looper (main, tid 2) {be3ee96} called on null, FYI main Looper is Looper (main, tid 2) {be3ee96})
        //kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
        //    XCTAssertEqual("HELLO", engine.webView.title)
        //}

        // times out after 10 seconds
        //let num = try await engine.evaluate(js: "1+2")
        //XCTAssertEqual("3", num)

        #endif
    }

    @MainActor func testWebEngine() async throws {
        if isMacOS {
            throw XCTSkip("cannot run WebEngine tests in macOS")
        }

        if isRobolectric {
            throw XCTSkip("cannot run WebEngine tests in Robolectric")
        }

        if isAndroid {
            throw XCTSkip("WebEngine page load tests hang in Android")
        }

        //assertMainThread()

        func html(title: String, body: String = "") -> String {
            "<html><head><title>\(title)</title></head><body>\(body)</body></html>"
        }
        
        let tempDirectory = URL.temporaryDirectory
        var handledMessage: String? = nil
        
        let config = WebEngineConfiguration(
            userScripts: [
                WebViewUserScript(
                    source: "webkit.messageHandlers.test.postMessage('hello')",
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            ],
            messageHandlers: [
                "test": { message in
                    handledMessage = (
                        message.body as! String
                    )
                }
            ],
            schemeHandlers: [
                "test": DirectoryURLSchemeHandler(directory: tempDirectory)
            ]
        )
        #if SKIP
        let ctx = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        config.context = ctx
        let platformWebView = PlatformWebView(ctx)
        #else
        let platformWebView = PlatformWebView(frame: CGRectZero, configuration: config.webViewConfiguration)
        #endif

        let engine = WebEngine(configuration: config, webView: platformWebView)

        #if !SKIP
        engine.refreshMessageHandlers()
        engine.updateUserScripts()
        #endif

        // needed before JS can be evaluated?
        //try await engine.loadHTML(html(title: "Initial Load"))

        //do {
        //    let abc = try await engine.evaluate(js: "'AB' + 'C'")
        //    XCTAssertEqual(abc, #""AB+C""#)
        //}

        func enquote(_ string: String) -> String {
            "\"" + string + "\""
        }

        do {
            let url = URL(string: "https://www.example.com")!
            logger.log("loading url: \(url)")
            try await engine.load(url: url)
            logger.log("done loading url: \(url)")
            let title2 = try await engine.evaluate(js: "document.title")
            XCTAssertEqual(enquote("Example Domain"), title2)
        }

        // try async load with both HTML string and file URL loading and ensure the DOM is updated

        do {
            let title = "Hello HTML String!"
            logger.log("loading title: \(title)")
            try await engine.awaitPageLoaded {
                engine.loadHTML(html(title: title))
            }

            let title1 = try await engine.evaluate(js: "document.title")
            XCTAssertEqual(enquote(title), title1)
        }

        do {
            let fileURL = tempDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("html")

            let title = "Hello HTML File!"
            logger.log("loading title: \(title)")
            try html(title: title).write(to: fileURL, atomically: false, encoding: .utf8)

            try await engine.load(url: fileURL)
            let title2 = try await engine.evaluate(js: "document.title")
            XCTAssertEqual(enquote(title), title2)
        }
        
        do {
            let fileName = UUID().uuidString
            let fileURL = URL.temporaryDirectory
                .appendingPathComponent(fileName)
                .appendingPathExtension("html")

            let title = "scheme handled"
            logger.log("loading title: \(title)")
            try html(title: title).write(to: fileURL, atomically: false, encoding: .utf8)

            try await engine.load(url: URL(string: "test:///\(fileName).html")!)
            let titleJSON = try await engine.evaluate(js: "document.title")
            XCTAssertEqual(enquote(title), titleJSON)
        }

        // FIXME: Android times out and cancels coroutine after 10 seconds
        logger.log("loading javascript")
        let three = try await engine.evaluate(js: "1+2")
        XCTAssertEqual("3", three)

        let agent = try await engine.evaluate(js: "navigator.userAgent") ?? ""
        // e.g.: Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148
        XCTAssertTrue(agent.contains("AppleWebKit"), "unexpected navigator.userAgent: \(agent)")

        #if os(iOS)
        guard #available(iOS 18, *) else {
            // 2025-05-08 16:32:53.583112+0000 xctest[20308:67559] :0: Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value
            throw XCTSkip("message handler simulator test fails on iOS in CI")
        }
        #endif

        logger.log("user script should have already posted a hello message")
        XCTAssertEqual("hello", handledMessage)
        logger.log("directly executing message handler")
        _ = try await engine.evaluate(js: "void(webkit.messageHandlers.test.postMessage('world'))")
        XCTAssertEqual("world", handledMessage)

        logger.log("executing message handler")
        _ = try await engine.evaluate(js: "void(webkit.messageHandlers.test.postMessage('hello'))")
        XCTAssertEqual("hello", handledMessage)

    }

    func testWebCookieURLMatchRules() throws {
        let secureCookie = WebCookie(
            name: "auth",
            value: "token",
            domain: "example.com",
            path: "/media",
            isSecure: true
        )

        XCTAssertTrue(secureCookie.matches(url: try XCTUnwrap(URL(string: "https://example.com/media/item.m3u8"))))
        XCTAssertFalse(secureCookie.matches(url: try XCTUnwrap(URL(string: "http://example.com/media/item.m3u8"))))
        XCTAssertFalse(secureCookie.matches(url: try XCTUnwrap(URL(string: "https://not-example.com/media/item.m3u8"))))
        XCTAssertFalse(secureCookie.matches(url: try XCTUnwrap(URL(string: "https://example.com/other/path"))))
        // Path matching must respect segment boundaries.
        XCTAssertFalse(secureCookie.matches(url: try XCTUnwrap(URL(string: "https://example.com/media2/item.m3u8"))))

        // Host-only cookies should stay on their exact host.
        let hostOnlyCookie = WebCookie(
            name: "hostonly",
            value: "1",
            domain: "example.com",
            path: "/"
        )
        XCTAssertTrue(hostOnlyCookie.matches(url: try XCTUnwrap(URL(string: "https://example.com/"))))
        XCTAssertFalse(hostOnlyCookie.matches(url: try XCTUnwrap(URL(string: "https://sub.example.com/"))))

        // Dot-prefixed domains should permit subdomain matching.
        let domainCookie = WebCookie(
            name: "domain",
            value: "1",
            domain: ".example.com",
            path: "/"
        )
        XCTAssertTrue(domainCookie.matches(url: try XCTUnwrap(URL(string: "https://sub.example.com/"))))

        let expiredCookie = WebCookie(
            name: "stale",
            value: "1",
            domain: "example.com",
            path: "/",
            expires: Date(timeIntervalSinceNow: -60)
        )
        XCTAssertFalse(expiredCookie.matches(url: try XCTUnwrap(URL(string: "https://example.com/"))))
    }

    func testSetCookieHeaderParsingIgnoresInvalidHeaders() throws {
        let responseURL = try XCTUnwrap(URL(string: "https://example.com/playlist.m3u8"))
        let cookies = WebCookie.parseSetCookieHeaders(
            [
                "session=abc123; Path=/; HttpOnly",
                "badheaderwithoutseparator",
                "pref=1; Max-Age=3600; Path=/"
            ],
            responseURL: responseURL
        )
        XCTAssertEqual(Set(cookies.map(\.name)), Set(["session", "pref"]))
        XCTAssertEqual(cookies.count, 2)
    }

    @MainActor
    func testAndroidRemovalBucketsAreDeterministicAndDeduplicated() {
        let allTypes = Set(WebSiteDataType.allCases)
        let allBuckets = WebEngine.androidRemovalBucketNames(for: allTypes)
        XCTAssertEqual(allBuckets, Set(["cookies", "cache", "storage"]))

        let cacheTypes: Set<WebSiteDataType> = [.diskCache, .memoryCache, .offlineWebApplicationCache]
        let cacheOnlyBuckets = WebEngine.androidRemovalBucketNames(for: cacheTypes)
        XCTAssertEqual(cacheOnlyBuckets, Set(["cache"]))
    }

    @MainActor
    func testWebProfileValidationRules() {
        XCTAssertNil(WebEngine.profileValidationError(for: WebProfile.default))
        XCTAssertNil(WebEngine.profileValidationError(for: WebProfile.named("profile-a")))
        XCTAssertEqual(WebEngine.profileValidationError(for: WebProfile.named(" ")), WebProfileError.invalidProfileName)
        XCTAssertEqual(WebEngine.profileValidationError(for: WebProfile.named("default")), WebProfileError.invalidProfileName)
    }

    @MainActor
    func testNavigatorLoadOrThrowPropagatesInvalidProfileError() async throws {
        if isRobolectric {
            throw XCTSkip("WebEngine-backed navigator tests require instrumented Android context")
        }
        let navigator = WebViewNavigator()
        navigator.webEngine = makeCookieTestEngine(profile: .named(" "))
        let requestURL = try XCTUnwrap(URL(string: "https://invalid-profile.example.com/path"))

        do {
            try await navigator.loadOrThrow(url: requestURL)
            XCTFail("Expected navigator loadOrThrow to fail for invalid profile")
        } catch let error as WebProfileError {
            XCTAssertEqual(error, .invalidProfileName)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    #if !SKIP
    @MainActor
    func testWebKitDataTypeMappingIncludesExpectedDataTypes() {
        let mapped = WebEngine.webKitDataTypes(for: Set(WebSiteDataType.allCases))
        let expected: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeWebSQLDatabases,
            WKWebsiteDataTypeIndexedDBDatabases
        ]
        XCTAssertEqual(mapped, expected)
    }

    @MainActor
    func testIOSNamedProfileIsolatesCookiesAcrossDifferentProfiles() async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let profileA: WebProfile = .named("ios_profile_a_\(suffix)")
        let profileB: WebProfile = .named("ios_profile_b_\(suffix)")
        let engineA = makeCookieTestEngine(profile: profileA)
        let engineB = makeCookieTestEngine(profile: profileB)
        await engineA.clearCookies()
        await engineB.clearCookies()

        let requestURL = try XCTUnwrap(URL(string: "https://ios-profiles.example.com/path"))
        let cookieName = "ios_profile_cookie_\(suffix)"
        try await engineA.setCookie(WebCookie(name: cookieName, value: "one"), requestURL: requestURL)

        let expectedPair = "\(cookieName)=one"
        let headerA = await awaitCookieHeaderContains(
            expectedPair,
            for: engineA,
            url: requestURL,
            shouldContain: true,
            timeoutNanoseconds: 5_000_000_000
        )
        let headerB = await engineB.cookieHeader(for: requestURL)
        XCTAssertTrue(
            headerA?.contains(expectedPair) == true,
            "Expected cookie in profile A header. headerA=\(String(describing: headerA)) headerB=\(String(describing: headerB))"
        )
        XCTAssertFalse(
            headerB?.contains(expectedPair) == true,
            "Cookie leaked into profile B header. headerA=\(String(describing: headerA)) headerB=\(String(describing: headerB))"
        )

        await engineA.clearCookies()
        await engineB.clearCookies()
    }

    @MainActor
    func testIOSNamedProfileSharesCookiesAcrossEnginesWithSameIdentifier() async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sharedProfile: WebProfile = .named("ios_profile_shared_\(suffix)")
        let engineA = makeCookieTestEngine(profile: sharedProfile)
        let engineB = makeCookieTestEngine(profile: sharedProfile)
        await engineA.clearCookies()
        await engineB.clearCookies()

        let requestURL = try XCTUnwrap(URL(string: "https://ios-profiles.example.com/shared"))
        let cookieName = "ios_shared_cookie_\(suffix)"
        try await engineA.setCookie(WebCookie(name: cookieName, value: "two"), requestURL: requestURL)

        let expectedPair = "\(cookieName)=two"
        let headerB = await awaitCookieHeaderContains(
            expectedPair,
            for: engineB,
            url: requestURL,
            shouldContain: true,
            timeoutNanoseconds: 5_000_000_000
        )
        XCTAssertTrue(
            headerB?.contains(expectedPair) == true,
            "Expected shared profile cookie in engine B header. headerB=\(String(describing: headerB))"
        )

        await engineA.clearCookies()
        await engineB.clearCookies()
    }
    #endif

    #if SKIP
    func testAndroidProfileSupportMatrix() {
        XCTAssertNil(WebEngine.androidProfileSupportError(for: WebProfile.default, isMultiProfileFeatureSupported: false))
        XCTAssertEqual(
            WebEngine.androidProfileSupportError(for: WebProfile.named("android-profile"), isMultiProfileFeatureSupported: false),
            WebProfileError.unsupportedOnAndroid
        )
        XCTAssertNil(
            WebEngine.androidProfileSupportError(for: WebProfile.named("android-profile"), isMultiProfileFeatureSupported: true)
        )
        XCTAssertEqual(
            WebEngine.androidProfileSupportError(for: WebProfile.named(" "), isMultiProfileFeatureSupported: true),
            WebProfileError.invalidProfileName
        )
    }

    @MainActor
    func testAndroidChildProfileInheritanceRejectsInvalidProfile() async throws {
        if isRobolectric {
            throw XCTSkip("Android profile inheritance tests require instrumented Android context")
        }
        let child = makeCookieTestEngine(profile: .default)
        let profileError = child.inheritAndroidProfile(from: WebProfile.named(" "))
        XCTAssertEqual(profileError, WebProfileError.invalidProfileName)

        let requestURL = try XCTUnwrap(URL(string: "https://android-profile.example.com/path"))
        do {
            try await child.setCookie(WebCookie(name: "session", value: "1"), requestURL: requestURL)
            XCTFail("Expected inherited invalid profile to block cookie operations")
        } catch let error as WebProfileError {
            XCTAssertEqual(error, WebProfileError.invalidProfileName)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    @MainActor
    func testAndroidChildProfileInheritanceMatchesSupportMatrix() async throws {
        if isRobolectric {
            throw XCTSkip("WebView feature probes are unavailable in Robolectric")
        }
        let child = makeCookieTestEngine(profile: .default)
        let profileError = child.inheritAndroidProfile(from: WebProfile.named("android-profile-inherited"))
        if WebEngine.isAndroidMultiProfileSupported() {
            XCTAssertNil(profileError)
        } else {
            XCTAssertEqual(profileError, WebProfileError.unsupportedOnAndroid)
        }
    }

    @MainActor
    func testAndroidNamedProfileThrowsWhenUnsupported() async throws {
        if isRobolectric {
            throw XCTSkip("WebView feature probes are unavailable in Robolectric")
        }
        if WebEngine.isAndroidMultiProfileSupported() {
            throw XCTSkip("device WebView runtime supports multi-profile")
        }
        let engine = makeCookieTestEngine(profile: .named("android-profile"))
        let requestURL = try XCTUnwrap(URL(string: "https://android-profile.example.com/path"))
        do {
            try await engine.setCookie(WebCookie(name: "session", value: "1"), requestURL: requestURL)
            XCTFail("Expected named profile operations to throw when multi-profile is unsupported")
        } catch let error as WebProfileError {
            XCTAssertEqual(error, WebProfileError.unsupportedOnAndroid)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    @MainActor
    func testAndroidNamedProfilesIsolateCookiesWhenSupported() async throws {
        if isRobolectric {
            throw XCTSkip("cookie/profile store tests are not reliable in Robolectric")
        }
        if !WebEngine.isAndroidMultiProfileSupported() {
            throw XCTSkip("device WebView runtime does not support multi-profile")
        }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let engineA = makeCookieTestEngine(profile: .named("android_profile_a_\(suffix)"))
        let engineB = makeCookieTestEngine(profile: .named("android_profile_b_\(suffix)"))
        await engineA.clearCookies()
        await engineB.clearCookies()

        let requestURL = try XCTUnwrap(URL(string: "https://android-profile.example.com/path"))
        let cookieName = "android_profile_cookie_\(suffix)"
        try await engineA.setCookie(WebCookie(name: cookieName, value: "1"), requestURL: requestURL)
        let headerA = await engineA.cookieHeader(for: requestURL)
        let headerB = await engineB.cookieHeader(for: requestURL)
        XCTAssertTrue(headerA?.contains("\(cookieName)=1") == true)
        XCTAssertFalse(headerB?.contains("\(cookieName)=1") == true)

        await engineA.clearCookies()
        await engineB.clearCookies()
    }

    @MainActor
    func testAndroidRemoveDataThrowsForNonDistantPastModifiedSince() async throws {
        if isRobolectric {
            throw XCTSkip("WebEngine-backed data removal tests require instrumented Android context")
        }
        let engine = makeCookieTestEngine()
        let types: Set<WebSiteDataType> = [.cookies]
        do {
            try await engine.removeData(ofTypes: types, modifiedSince: Date())
            XCTFail("Expected removeData to throw for non-distantPast modifiedSince on Android")
        } catch let error as WebDataRemovalError {
            XCTAssertEqual(error, .unsupportedModifiedSinceOnAndroid)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    #endif

    @MainActor
    func testRemoveDataAllowsDistantPastForEmptyTypes() async throws {
        if isRobolectric {
            throw XCTSkip("WebEngine-backed data removal tests require instrumented Android context")
        }
        let engine = makeCookieTestEngine()
        try await engine.removeData(ofTypes: [], modifiedSince: .distantPast)
    }

    @MainActor
    func testSetCookieWithRequestURLFallbackAndReadHeader() async throws {
        if isRobolectric {
            throw XCTSkip("cookie store is not reliable in Robolectric")
        }

        let engine = makeCookieTestEngine()
        await engine.clearCookies()

        let requestURL = try XCTUnwrap(URL(string: "https://cookies.example.com/path"))
        let cookieName = "skip_cookie_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let cookie = WebCookie(name: cookieName, value: "value")

        try await engine.setCookie(cookie, requestURL: requestURL)
        let header = await engine.cookieHeader(for: requestURL)
        XCTAssertTrue(header?.contains("\(cookieName)=value") == true)

        await engine.clearCookies()
    }

    @MainActor
    func testSecureCookieNotReturnedForHTTP() async throws {
        if isRobolectric {
            throw XCTSkip("cookie store is not reliable in Robolectric")
        }

        let engine = makeCookieTestEngine()
        await engine.clearCookies()

        let cookieName = "secure_cookie_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let secureCookie = WebCookie(name: cookieName, value: "1", isSecure: true)
        let httpsURL = try XCTUnwrap(URL(string: "https://secure.example.com/resource"))
        let httpURL = try XCTUnwrap(URL(string: "http://secure.example.com/resource"))

        try await engine.setCookie(secureCookie, requestURL: httpsURL)
        let secureHeader = await engine.cookieHeader(for: httpsURL)
        let insecureHeader = await engine.cookieHeader(for: httpURL)

        XCTAssertTrue(secureHeader?.contains("\(cookieName)=1") == true)
        XCTAssertFalse(insecureHeader?.contains("\(cookieName)=1") == true)

        await engine.clearCookies()
    }

    @MainActor
    func testClearCookiesRemovesStoredCookies() async throws {
        if isRobolectric {
            throw XCTSkip("cookie store is not reliable in Robolectric")
        }

        let engine = makeCookieTestEngine()
        await engine.clearCookies()

        let requestURL = try XCTUnwrap(URL(string: "https://cleanup.example.com/"))
        let cookieName = "clear_cookie_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let cookie = WebCookie(name: cookieName, value: "to-delete")

        try await engine.setCookie(cookie, requestURL: requestURL)
        let headerBeforeClear = await engine.cookieHeader(for: requestURL)
        XCTAssertTrue(headerBeforeClear?.contains("\(cookieName)=to-delete") == true)

        await engine.clearCookies()
        let headerAfterClear = await engine.cookieHeader(for: requestURL)
        XCTAssertFalse(headerAfterClear?.contains("\(cookieName)=to-delete") == true)
    }

    @MainActor
    func testApplySetCookieHeadersRoundTrip() async throws {
        if isRobolectric {
            throw XCTSkip("cookie store is not reliable in Robolectric")
        }

        let engine = makeCookieTestEngine()
        await engine.clearCookies()

        let responseURL = try XCTUnwrap(URL(string: "https://headers.example.com/media/master.m3u8"))
        let cookieName = "header_cookie_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try await engine.applySetCookieHeaders(
            [
                "\(cookieName)=ok; Path=/; HttpOnly",
                "not-a-cookie-header"
            ],
            for: responseURL
        )

        let header = await engine.cookieHeader(for: responseURL)
        XCTAssertTrue(header?.contains("\(cookieName)=ok") == true)

        await engine.clearCookies()
    }

    @MainActor
    private func makeCookieTestEngine(profile: WebProfile = WebProfile.default) -> WebEngine {
        let config = WebEngineConfiguration(profile: profile)
        #if SKIP
        let instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
        let isMainLooperThread = (android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
        if isMainLooperThread {
            let context = instrumentation.targetContext
            config.context = context
            let platformWebView = PlatformWebView(context)
            return WebEngine(configuration: config, webView: platformWebView)
        } else {
            var createdEngine: WebEngine? = nil
            instrumentation.runOnMainSync {
                let context = instrumentation.targetContext
                config.context = context
                let platformWebView = PlatformWebView(context)
                createdEngine = WebEngine(configuration: config, webView: platformWebView)
            }
            return try! XCTUnwrap(createdEngine)
        }
        #else
        let platformWebView = PlatformWebView(frame: CGRectZero, configuration: config.webViewConfiguration)
        return WebEngine(configuration: config, webView: platformWebView)
        #endif
    }

    func assertMainThread() {
        #if !SKIP
        XCTAssertTrue(Thread.isMainThread)
        #else
        XCTAssertTrue((android.os.Looper.myLooper() == android.os.Looper.getMainLooper()), "test case must be run on main thread: \(android.os.Looper.myLooper()) vs. \(android.os.Looper.getMainLooper())") // or else: java.lang.RuntimeException: WebView cannot be initialized on a thread that has no Looper.
        #endif
    }

    enum SnapshotTestTimeoutError: Error {
        case timedOut
    }

    #if !SKIP
    @MainActor
    private func awaitCookieHeaderContains(
        _ token: String,
        for engine: WebEngine,
        url: URL,
        shouldContain: Bool,
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64 = 50_000_000
    ) async -> String? {
        let start = DispatchTime.now().uptimeNanoseconds
        var lastHeader: String?
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            let header = await engine.cookieHeader(for: url)
            lastHeader = header
            if (header?.contains(token) == true) == shouldContain {
                return header
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return lastHeader
    }
    #endif

    @MainActor
    func takeSnapshotWithTimeout(_ engine: WebEngine, timeoutNanoseconds: UInt64 = UInt64(30_000_000_000)) async throws -> SkipWebSnapshot {
        try await withThrowingTaskGroup(of: SkipWebSnapshot.self) { group in
            group.addTask { @MainActor in
                try await engine.takeSnapshot()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw SnapshotTestTimeoutError.timedOut
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw SnapshotTestTimeoutError.timedOut
            }
            return first
        }
    }

    @MainActor
    func takeSnapshotWithTimeout(
        _ engine: WebEngine,
        configuration: SkipWebSnapshotConfiguration,
        timeoutNanoseconds: UInt64 = UInt64(30_000_000_000)
    ) async throws -> SkipWebSnapshot {
        try await withThrowingTaskGroup(of: SkipWebSnapshot.self) { group in
            group.addTask { @MainActor in
                try await engine.takeSnapshot(configuration: configuration)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw SnapshotTestTimeoutError.timedOut
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw SnapshotTestTimeoutError.timedOut
            }
            return first
        }
    }

    #endif
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}


#if SKIP
class WebViewActivity : androidx.activity.ComponentActivity {
    init() {
    }

    override func onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
//        setContent {
//            Text("Hello world!")
//        }
    }

}
#endif
