// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
import XCTest
import OSLog
import Foundation
import SkipWeb

let logger: Logger = Logger(subsystem: "SkipWeb", category: "Tests")

// SKIP INSERT: @androidx.test.annotation.UiThreadTest
final class SkipWebTests: XCTestCase {

    #if SKIP || os(iOS)

    final class DummyUIDelegate: SkipWebUIDelegate { }

    // SKIP INSERT: @get:org.junit.Rule val composeRule = androidx.compose.ui.test.junit4.createComposeRule()

    func testSkipWeb() throws {
        logger.log("running testSkipWeb")
        XCTAssertEqual(1 + 2, 3, "basic test")
        
        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try XCTUnwrap(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        XCTAssertEqual("SkipWeb", testData.testModuleName)
    }

    func testWindowConfigurationDefaults() {
        let config = WebEngineConfiguration()
        XCTAssertFalse(config.javaScriptCanOpenWindowsAutomatically)
        XCTAssertNil(config.uiDelegate)
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

    /*func testSnapshotConfigurationDefaults() {
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

        let snapshot = try await engine.takeSnapshot()
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
        let snapshot = try await engine.takeSnapshot(configuration: SkipWebSnapshotConfiguration(rect: rect, snapshotWidth: requestedWidth, afterScreenUpdates: true))
        XCTAssertFalse(snapshot.pngData.isEmpty)
        XCTAssertGreaterThan(snapshot.pixelWidth, 0)
        XCTAssertGreaterThan(snapshot.pixelHeight, 0)
        XCTAssertGreaterThanOrEqual(snapshot.pixelWidth, Int(requestedWidth))
        XCTAssertEqual(Double(snapshot.pixelHeight) / Double(snapshot.pixelWidth), Double(rect.height / rect.width), accuracy: 0.05)
        #endif
    }*/

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
            composeRule.setContent {
                androidx.compose.ui.viewinterop.AndroidView(factory: { ctx in
                    //let ctx = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
                    //config.context = ctx
                    let platformWebView = PlatformWebView(ctx)
                    let webEngine = WebEngine(configuration: config, webView: platformWebView)
                    webEngine.loadHTML(html(title: "HELLO"))
                    outerEngine = webEngine
                    return platformWebView
                })
            }
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

        #if SKIP
        composeRule.setContent {
            androidx.compose.ui.viewinterop.AndroidView(factory: { ctx in
                return platformWebView
            })
        }
        #else
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

    func assertMainThread() {
        #if !SKIP
        XCTAssertTrue(Thread.isMainThread)
        #else
        XCTAssertTrue((android.os.Looper.myLooper() == android.os.Looper.getMainLooper()), "test case must be run on main thread: \(android.os.Looper.myLooper()) vs. \(android.os.Looper.getMainLooper())") // or else: java.lang.RuntimeException: WebView cannot be initialized on a thread that has no Looper.
        #endif
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
