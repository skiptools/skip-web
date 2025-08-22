// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation
import SwiftUI
#if !SKIP
import WebKit
import UniformTypeIdentifiers
#else
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
#endif

#if SKIP || os(iOS)

/// An web engine that holds a system web view:
/// [`WebKit.WKWebView`](https://developer.apple.com/documentation/webkit/wkwebview) on iOS and
/// [`android.webkit.WebView`](https://developer.android.com/reference/android/webkit/WebView) on Android
///
/// The `WebEngine` is used both as the render for a `WebView` and `BrowserView`,
/// and can also be used in a headless context to drive web pages
/// and evaluate JavaScript.
@MainActor public class WebEngine : WebObjectBase {
    public let configuration: WebEngineConfiguration
    public let webView: PlatformWebView
    #if !SKIP
    public override var description: String {
        "WebEngine: \(webView)"
    }
    private var observers: [NSKeyValueObservation] = []
    #endif

    /// Create a WebEngine with the specified configuration.
    /// - Parameters:
    ///   - configuration: the configuration to use
    ///   - webView: when set, the given platform-specific web view will
    public init(configuration: WebEngineConfiguration = WebEngineConfiguration(), webView: PlatformWebView? = nil) {
        self.configuration = configuration

        #if !SKIP
        self.webView = webView ?? WKWebView(frame: .zero, configuration: configuration.webViewConfiguration)
        #else
        // fall back to using the global android context if the activity context is not set in the configuration
        self.webView = webView ?? PlatformWebView(configuration.context ?? ProcessInfo.processInfo.androidContext)
        #endif
    }

    public func reload() {
        webView.reload()
    }

    public func stopLoading() {
        webView.stopLoading()
    }

    public func go(to item: WebHistoryItem) {
        #if !SKIP
        webView.go(to: item.item)
        #else
        // TODO: there's no "go" equivalent in WebView, so we'll probably need to use `goBackOrForward(int steps)` based on matching the item in the back/forward list
        #endif
    }

    public func goBack() {
        webView.goBack()
    }

    public func goForward() {
        webView.goForward()
    }

    /// Evaluates the given JavaScript string and returns the resulting JSON string, which may be a top-level fragment
    public func evaluate(js: String) async throws -> String? {
        return try await evaluateJavaScriptAsync(js)
    }

    public func loadHTML(_ html: String, baseURL: URL? = nil, mimeType: String = "text/html") {
        logger.info("loadHTML webView: \(self.description)")
        let encoding: String = "UTF-8"

        #if SKIP
        // see https://developer.android.com/reference/android/webkit/WebView#loadDataWithBaseURL(java.lang.String,%20java.lang.String,%20java.lang.String,%20java.lang.String,%20java.lang.String)
        let baseUrl: String? = baseURL?.absoluteString // the URL to use as the page's base URL. If null defaults to 'about:blank'
        //var htmlContent = android.util.Base64.encodeToString(html.toByteArray(), android.util.Base64.NO_PADDING)
        var htmlContent = html
        let historyUrl: String? = nil // the URL to use as the history entry. If null defaults to 'about:blank'. If non-null, this must be a valid URL.
        webView.loadDataWithBaseURL(baseUrl, htmlContent, mimeType, encoding, historyUrl)
        #else
        refreshMessageHandlers()
        //try await awaitPageLoaded {
        webView.load(Data(html.utf8), mimeType: mimeType, characterEncodingName: encoding, baseURL: baseURL ?? URL(string: "about:blank")!)
        //}
        #endif
    }

    /// Asyncronously load the given URL, returning once the page has been loaded or an error has occurred
    public func load(url: URL) async throws {
        let urlString = url.absoluteString
        logger.info("load URL=\(urlString) webView: \(self.description)")
        try await awaitPageLoaded {
            #if SKIP
            webView.loadUrl(urlString ?? "about:blank")
            #else
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url)
            } else {
                webView.load(URLRequest(url: url))
            }
            #endif
        }
    }

    fileprivate func evaluateJavaScriptAsync(_ script: String) async throws -> String? {
        #if !SKIP
        guard let result = try await webView.evaluateJavaScript(script) else {
            return nil
        }
        // in order to match the behavior of Android's evaluateJavascript, we need to return the result as a serialized JavaScript string that can contain fragments (e.g., top-level strings)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8)
        #else
        logger.info("WebEngine: calling eval: \(android.os.Looper.myLooper())")
        suspendCancellableCoroutine { continuation in
            logger.info("WebEngine: calling eval suspendCoroutine: \(android.os.Looper.myLooper())")
            webView.evaluateJavascript(script) { result in
                logger.info("WebEngine: returned webView.evaluateJavascript: \(android.os.Looper.myLooper()): \(result)")
                continuation.resume(result)
            }

            continuation.invokeOnCancellation { _ in
                continuation.cancel()
            }
        }
        #endif
    }

    /// Perform the given block and only return once the page has completed loading
    // SKIP @nobridge
    public func awaitPageLoaded(_ block: () -> ()) async throws {
        let pdelegate = self.engineDelegate
        defer { self.engineDelegate = pdelegate }

        // need to retain the navigation delegate or else it will drop the continuation
        var loadDelegate: PageLoadDelegate? = nil

        let _: Void? = try await withCheckedThrowingContinuation { continuation in
            loadDelegate = PageLoadDelegate(config: configuration) { result in
                continuation.resume(with: result)
            }

            self.engineDelegate = loadDelegate
            logger.log("WebEngine: awaitPageLoaded block()")
            block()
        }
    }
    
    #if !SKIP
    var registeredMessageHandlerNames = Set<String>()
    
    fileprivate static var systemMessageHandlers: [String] {
        [
            "skipConsoleLog"
        ]
    }

    @MainActor
    public func refreshMessageHandlers() {
        let userContentController = webView.configuration.userContentController
        for messageHandlerName in Self.systemMessageHandlers + configuration.messageHandlers.keys {
            if registeredMessageHandlerNames.contains(messageHandlerName) { continue }

            // Sometimes we reuse an underlying WKWebView for a new SwiftUI component.
            userContentController.removeScriptMessageHandler(forName: messageHandlerName, contentWorld: .page)
            userContentController.add(self, contentWorld: .page, name: messageHandlerName)
            registeredMessageHandlerNames.insert(messageHandlerName)
        }
        for missing in registeredMessageHandlerNames.subtracting(Self.systemMessageHandlers + configuration.messageHandlers.keys) {
            userContentController.removeScriptMessageHandler(forName: missing)
            registeredMessageHandlerNames.remove(missing)
        }
    }
    
    @MainActor
    public func updateUserScripts() {
        let userContentController = webView.configuration.userContentController
        let allScripts = WebViewUserScript.systemScripts + configuration.userScripts
        if userContentController.userScripts.sorted(by: { $0.source > $1.source }) != allScripts.map({ $0.webKitUserScript }).sorted(by: { $0.source > $1.source }) {
            userContentController.removeAllUserScripts()
            for script in allScripts {
                userContentController.addUserScript(script.webKitUserScript)
            }
        }
    }
    
    
    #endif
}


#if !SKIP
extension WebEngine: ScriptMessageHandler {
    public func userContentController(_ userContentController: UserContentController, didReceive message: ScriptMessage) {
        if message.name == "skipConsoleLog" {
            guard let body = message.body as? [String: String] else {
                logger.error("JS Console (invalid skipConsoleLog message): \(String(describing: message.body))")
                return
            }
            let level = body["level"] ?? "log"
            let content = body["content"] ?? ""
            switch level {
            case "debug":
                logger.debug("JS Console \(level): \(content)")
            case "info":
                logger.info("JS Console \(level): \(content)")
            case "log":
                logger.info("JS Console \(level): \(content)")
            case "warn":
                logger.warning("JS Console \(level): \(content)")
            case "error":
                logger.error("JS Console \(level): \(content)")
            default:
                logger.error("JS Console (unknown level \(level)): \(content)")
            }
            return
        }
        guard let messageHandler = configuration.messageHandlers[message.name] else { return }
        let msg = WebViewMessage(frameInfo: message.frameInfo, uuid: UUID(), name: message.name, body: message.body)
        Task {
            await messageHandler(msg)
        }
    }
}
#endif

extension WebEngine {
    /// The engine delegate that handles client navigation events like the page being loaded or an error occuring
    // SKIP @nobridge
    public var engineDelegate: WebEngineDelegate? {
        get {
            #if SKIP
            webView.webViewClient as? WebEngineDelegate
            #else
            webView.navigationDelegate as? WebEngineDelegate
            #endif
        }

        set {
            #if SKIP
            webView.webViewClient = newValue ?? webView.webViewClient
            #else
            webView.navigationDelegate = newValue
            #endif

        }
    }
}


#if SKIP
// SKIP @nobridge
public class WebEngineDelegate : android.webkit.WebViewClient {
    let config: WebEngineConfiguration
    let webViewClient: android.webkit.WebViewClient
    
    override init(config: WebEngineConfiguration, webViewClient: android.webkit.WebViewClient = android.webkit.WebViewClient()) {
        super.init()
        self.config = config
        self.webViewClient = webViewClient
    }

    /// Notify the host application to update its visited links database.
    override func doUpdateVisitedHistory(view: PlatformWebView, url: String, isReload: Bool) {
        logger.log("application")
        webViewClient.doUpdateVisitedHistory(view, url, isReload)
    }

    /// As the host application if the browser should resend data as the requested page was a result of a POST.
    override func onFormResubmission(view: PlatformWebView, dontResend: android.os.Message, resend: android.os.Message) {
        logger.log("onFormResubmission")
        webViewClient.onFormResubmission(view, dontResend, resend)
    }

    /// Notify the host application that the WebView will load the resource specified by the given url.
    override func onLoadResource(view: PlatformWebView, url: String) {
        logger.log("onLoadResource: \(url)")
        webViewClient.onLoadResource(view, url)
    }

    /// Notify the host application that WebView content left over from previous page navigations will no longer be drawn.
    override func onPageCommitVisible(view: PlatformWebView, url: String) {
        logger.log("onPageCommitVisible: \(url)")
        webViewClient.onPageCommitVisible(view, url)
    }

    /// Notify the host application that a page has finished loading.
    override func onPageFinished(view: PlatformWebView, url: String) {
        logger.log("onPageFinished: \(url)")
        for userScript in config.userScripts {
            if userScript.webKitUserScript.injectionTime == .atDocumentEnd {
                let source = userScript.webKitUserScript.source
                view.evaluateJavascript(source) { _ in
                    logger.debug("Executed user script \(source)")
                }
            }
        }
        webViewClient.onPageFinished(view, url)
    }

    /// Notify the host application that a page has started loading.
    override func onPageStarted(view: PlatformWebView, url: String, favicon: android.graphics.Bitmap?) {
        logger.log("onPageStarted: \(url)")
        if (!config.messageHandlers.isEmpty) {
            // add support for webkit.messageHandlers.messageHandlerName.postMessage(body)
            // JS Proxies are pretty weird. https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Proxy
            // We're using an empty target; when JS accesses any property,
            // we'll return a JS object with a `postMessage` member function, which will call
            // skipWebAndroidMessageHandler.postMessage, passing the messageHandlerName and body as strings.
            view.evaluateJavascript("""
            if (!window.webkit) window.webkit = {};
            webkit.messageHandlers = new Proxy({}, {
                get: (target, messageHandlerName, receiver) => ({
                    postMessage: (body) => skipWebAndroidMessageHandler.postMessage(String(messageHandlerName), JSON.stringify(body))
                })
            });
        """) { _ in logger.debug("Added webkit.messageHandlers") }
        }
        for userScript in config.userScripts {
            if userScript.webKitUserScript.injectionTime == .atDocumentStart {
                let source = userScript.webKitUserScript.source
                view.evaluateJavascript(source) { _ in
                    logger.debug("Executed user script \(source)")
                }
            }
        }
        webViewClient.onPageStarted(view, url, favicon)
    }

    /// Notify the host application to handle a SSL client certificate request.
    override func onReceivedClientCertRequest(view: PlatformWebView, request: android.webkit.ClientCertRequest) {
        logger.log("onReceivedClientCertRequest: \(request)")
        webViewClient.onReceivedClientCertRequest(view, request)
    }

    /// Report web resource loading error to the host application.
    override func onReceivedError(view: PlatformWebView, request: android.webkit.WebResourceRequest, error: android.webkit.WebResourceError) {
        logger.log("onReceivedError: \(error)")
        webViewClient.onReceivedError(view, request, error)
    }

    /// Notifies the host application that the WebView received an HTTP authentication request.
    override func onReceivedHttpAuthRequest(view: PlatformWebView, handler: android.webkit.HttpAuthHandler, host: String, realm: String) {
        logger.log("onReceivedHttpAuthRequest: \(handler) \(host) \(realm)")
        webViewClient.onReceivedHttpAuthRequest(view, handler, host, realm)
    }

    /// Notify the host application that an HTTP error has been received from the server while loading a resource.
    override func onReceivedHttpError(view: PlatformWebView, request: android.webkit.WebResourceRequest, errorResponse: android.webkit.WebResourceResponse) {
        logger.log("onReceivedHttpError: \(request) \(errorResponse)")
        webViewClient.onReceivedHttpError(view, request, errorResponse)
    }

    /// Notify the host application that a request to automatically log in the user has been processed.
//    override func onReceivedLoginRequest(view: PlatformWebView, realm: String, account: String, args: String) {
//        webViewClient.onReceivedLoginRequest(view, realm, account, args)
//    }

    /// Notifies the host application that an SSL error occurred while loading a resource.
    override func onReceivedSslError(view: PlatformWebView, handler: android.webkit.SslErrorHandler, error: android.net.http.SslError) {
        logger.log("onReceivedSslError: \(error)")
        webViewClient.onReceivedSslError(view, handler, error)
    }

    /// Notify host application that the given WebView's render process has exited.
    override func onRenderProcessGone(view: PlatformWebView, detail: android.webkit.RenderProcessGoneDetail) -> Bool {
        logger.log("onRenderProcessGone: \(detail)")
        return webViewClient.onRenderProcessGone(view, detail)
    }

    /// Notify the host application that a loading URL has been flagged by Safe Browsing.
    override func onSafeBrowsingHit(view: PlatformWebView, request: android.webkit.WebResourceRequest, threatType: Int, callback: android.webkit.SafeBrowsingResponse) {
        logger.log("onSafeBrowsingHit: \(request)")
        webViewClient.onSafeBrowsingHit(view, request, threatType, callback)
    }

    /// Notify the host application that the scale applied to the WebView has changed.
    override func onScaleChanged(view: PlatformWebView, oldScale: Float, newScale: Float) {
        logger.log("onScaleChanged: \(oldScale) \(newScale)")
        webViewClient.onScaleChanged(view, oldScale, newScale)
    }

    /// Notify the host application that a key was not handled by the WebView.
    override func onUnhandledKeyEvent(view: PlatformWebView, event: android.view.KeyEvent) {
        logger.log("onUnhandledKeyEvent: \(event)")
        webViewClient.onUnhandledKeyEvent(view, event)
    }

    /// Notify the host application of a resource request and allow the application to return the data.
    public override func shouldInterceptRequest(view: PlatformWebView, request: android.webkit.WebResourceRequest) -> android.webkit.WebResourceResponse? {
        logger.log("shouldInterceptRequest: \(request.url)")
        let scheme: String = request.url?.scheme ?? ""
        if let handler = config.schemeHandlers[scheme] {
            return handler.interceptRequest(view: view, request: request)
        }
        return webViewClient.shouldInterceptRequest(view, request)
    }

    /// Give the host application a chance to handle the key event synchronously.
    override func shouldOverrideKeyEvent(view: PlatformWebView, event: android.view.KeyEvent) -> Bool {
        logger.log("shouldOverrideKeyEvent: \(event)")
        return webViewClient.shouldOverrideKeyEvent(view, event)
    }

    /// Give the host application a chance to take control when a URL is about to be loaded in the current WebView.
    override func shouldOverrideUrlLoading(view: PlatformWebView, request: android.webkit.WebResourceRequest) -> Bool {
        logger.log("shouldOverrideUrlLoading: \(request.url)")
        return webViewClient.shouldOverrideUrlLoading(view, request)
    }
}
#else
public class WebEngineDelegate : WebObjectBase, WKNavigationDelegate {

}
#endif

/// A temporary NavigationDelegate that uses a callback to integrate with checked continuations
fileprivate class PageLoadDelegate : WebEngineDelegate {
    let callback: (Result<Void, Error>) -> ()
    var callbackInvoked = false

    init(config: WebEngineConfiguration, callback: @escaping (Result<Void, Error>) -> Void) {
        #if SKIP
        super.init(config: config)
        #endif
        self.callback = callback
    }

    #if SKIP
    override func onPageFinished(view: PlatformWebView, url: String) {
        logger.info("webView: \(view) onPageFinished: \(url!)")
        if self.callbackInvoked { return }
        callbackInvoked = true
        self.callback(Result<Void, Error>.success(()))
    }
    #else
    @objc func webView(_ webView: PlatformWebView, didFinish navigation: WebNavigation!) {
        logger.info("webView: \(webView) didFinish: \(navigation!)")
        if self.callbackInvoked { return }
        callbackInvoked = true
        self.callback(.success(()))
    }
    #endif

    #if SKIP
    override func onReceivedError(view: PlatformWebView, request: android.webkit.WebResourceRequest, error: android.webkit.WebResourceError) {
        logger.info("webView: \(view) onReceivedError: \(request!) error: \(error)")
        if self.callbackInvoked { return }
        callbackInvoked = true
        self.callback(Result<Void, Error>.failure(WebLoadError(msg: String(error.description), code: error.errorCode)))
    }
    #else
    @objc func webView(_ webView: PlatformWebView, didFail navigation: WebNavigation!, withError error: any Error) {
        logger.info("webView: \(webView) didFail: \(navigation!) error: \(error)")
        if self.callbackInvoked { return }
        callbackInvoked = true
        self.callback(.failure(error))
    }
    #endif
}

#if SKIP
// android.webkit.WebResourceError is not an Exception, so we need to wrap it
public struct WebLoadError : Error, CustomStringConvertible {
    public let msg: String
    public let code: Int32

    public init(msg: String, code: Int32) {
        self.msg = msg
        self.code = code
    }

    public var description: String {
        "SQLite error code \(code): \(msg)"
    }

    public var localizedDescription: String {
        "SQLite error code \(code): \(msg)"
    }
}
#endif


/// The configuration for a WebEngine
@Observable public class WebEngineConfiguration {
    public var javaScriptEnabled: Bool
    public var allowsBackForwardNavigationGestures: Bool
    public var allowsPullToRefresh: Bool
    public var allowsInlineMediaPlayback: Bool
    public var dataDetectorsEnabled: Bool
    public var isScrollEnabled: Bool
    public var pageZoom: CGFloat
    public var isOpaque: Bool
    public var customUserAgent: String?
    public var userScripts: [WebViewUserScript]
    public var messageHandlers: [String: ((WebViewMessage) async -> Void)]
    public var schemeHandlers: [String: URLSchemeHandler]

    #if SKIP
    /// The Android context to use for creating a web context
    public var context: android.content.Context? = nil
    #endif

    public init(javaScriptEnabled: Bool = true,
                allowsBackForwardNavigationGestures: Bool = true,
                allowsPullToRefresh: Bool = true,
                allowsInlineMediaPlayback: Bool = true,
                dataDetectorsEnabled: Bool = true,
                isScrollEnabled: Bool = true,
                pageZoom: CGFloat = 1.0,
                isOpaque: Bool = true,
                customUserAgent: String? = nil,
                userScripts: [WebViewUserScript] = [],
                messageHandlers: [String: ((WebViewMessage) async -> Void)] = [:],
                schemeHandlers: [String: URLSchemeHandler] = [:]) {
        self.javaScriptEnabled = javaScriptEnabled
        self.allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures
        self.allowsPullToRefresh = allowsPullToRefresh
        self.allowsInlineMediaPlayback = allowsInlineMediaPlayback
        self.dataDetectorsEnabled = dataDetectorsEnabled
        self.isScrollEnabled = isScrollEnabled
        self.pageZoom = pageZoom
        self.isOpaque = isOpaque
        self.customUserAgent = customUserAgent
        self.userScripts = userScripts
        self.messageHandlers = messageHandlers
        self.schemeHandlers = schemeHandlers
    }

    #if !SKIP
    /// Create a `WebViewConfiguration` from the properties of this configuration.
    @MainActor public var webViewConfiguration: WebViewConfiguration {
        let configuration = WebViewConfiguration()

        //let preferences = WebpagePreferences()
        //preferences.allowsContentJavaScript //

        #if !os(macOS) // API unavailable on macOS
        configuration.allowsInlineMediaPlayback = self.allowsInlineMediaPlayback
        configuration.dataDetectorTypes = [.all]
        //configuration.defaultWebpagePreferences = preferences
        configuration.dataDetectorTypes = [.calendarEvent, .flightNumber, .link, .lookupSuggestion, .trackingNumber]

        for (schemeName, schemeHandlerObject) in schemeHandlers {
            configuration.setURLSchemeHandler(schemeHandlerObject, forURLScheme: schemeName)
        }
        #endif

        return configuration
    }
    #endif
}

public class WebHistoryItem {
    #if !SKIP
    public typealias BackForwardListItem = WKBackForwardListItem
    #else
    public typealias BackForwardListItem = android.webkit.WebHistoryItem
    #endif

    public let item: BackForwardListItem

    init(item: BackForwardListItem) {
        self.item = item
    }

    /// The URL of the webpage represented by this item.
    public var url: String {
        #if !SKIP
        return item.url.absoluteString
        #else
        return item.getUrl()
        #endif
    }

    /// The URL of the initial request that created this item.
    public var initialURL: String {
        #if !SKIP
        return item.initialURL.absoluteString
        #else
        return item.getOriginalUrl()
        #endif
    }

    /// The title of the webpage represented by this item.
    public var title: String? {
        #if !SKIP
        return item.title
        #else
        return item.getTitle()
        #endif
    }
}

public struct WebViewMessage: Equatable {
    // SKIP @nobridge
    public let frameInfo: FrameInfo
    internal let uuid: UUID
    public let name: String
    public let body: Any

    public static func == (lhs: WebViewMessage, rhs: WebViewMessage) -> Bool {
        lhs.uuid == rhs.uuid
        && lhs.name == rhs.name && lhs.frameInfo == rhs.frameInfo
    }
}


#if !SKIP
public typealias FrameInfo = WKFrameInfo
#else
// SKIP @nobridge
public class FrameInfo {
    open var isMainFrame: Bool
    open var request: URLRequest
    open var securityOrigin: SecurityOrigin
    weak open var webView: PlatformWebView?

    init(isMainFrame: Bool, request: URLRequest, securityOrigin: SecurityOrigin, webView: PlatformWebView? = nil) {
        self.isMainFrame = isMainFrame
        self.request = request
        self.securityOrigin = securityOrigin
        self.webView = webView
    }
}
#endif

#if !SKIP
public typealias WebContentRuleListStore = WKContentRuleListStore
#else
public class WebContentRuleListStore { }
#endif

#if !SKIP
public typealias WebNavigation = WKNavigation
#else
public class WebNavigation { }
#endif

#if !SKIP
public typealias WebNavigationAction = WKNavigationAction
#else
public class WebNavigationAction { }
#endif

#if !SKIP
public typealias WebNavigationDelegate = WKNavigationDelegate
#else
public protocol WebNavigationDelegate { }
#endif

#if !SKIP
public typealias WebUIDelegate = WKUIDelegate
#else
public protocol WebUIDelegate { }
#endif

#if !SKIP
public typealias WebViewConfiguration = WKWebViewConfiguration
#else
public class WebViewConfiguration { }
#endif


#if !SKIP
public typealias SecurityOrigin = WKSecurityOrigin
#else
public class SecurityOrigin { }
#endif


#if !SKIP
public typealias UserScriptInjectionTime = WKUserScriptInjectionTime
#else
public enum UserScriptInjectionTime : Int {
    case atDocumentStart = 0
    case atDocumentEnd = 1
}
#endif

#if !SKIP
public typealias UserScript = WKUserScript
#else
open class UserScript : WebObjectBase {
    open var source: String
    open var injectionTime: UserScriptInjectionTime
    open var isForMainFrameOnly: Bool
    open var contentWorld: ContentWorld

    public init(source: String, injectionTime: UserScriptInjectionTime, forMainFrameOnly: Bool, in contentWorld: ContentWorld) {
        self.source = source
        self.injectionTime = injectionTime
        self.isForMainFrameOnly = forMainFrameOnly
        self.contentWorld = contentWorld
    }
}
#endif

public struct WebViewUserScript: Equatable, Hashable {
    public let source: String
    public let webKitUserScript: UserScript
    public let allowedDomains: Set<String>

    public static func == (lhs: WebViewUserScript, rhs: WebViewUserScript) -> Bool {
        lhs.source == rhs.source
        && lhs.allowedDomains == rhs.allowedDomains
    }

    public init(source: String, injectionTime: UserScriptInjectionTime, forMainFrameOnly: Bool, world: ContentWorld = .page, allowedDomains: Set<String> = Set()) {
        self.source = source
        self.webKitUserScript = UserScript(source: source, injectionTime: injectionTime, forMainFrameOnly: forMainFrameOnly, in: world)
        self.allowedDomains = allowedDomains
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(allowedDomains)
    }
    
    #if SKIP
    fileprivate static let systemScripts: [WebViewUserScript] = []
    #else
    fileprivate static let systemScripts = [
        ConsoleLogUserScript().userScript
    ]
    #endif
}

#if !SKIP
fileprivate struct ConsoleLogUserScript {
    let userScript: WebViewUserScript
    
    init() {
        let contents = """
        (function() {
        function log(level, args) {
            var content = args.map(v => typeof v === "object" ? JSON.stringify(v) : String(v)).join(" ");
            webkit.messageHandlers.skipConsoleLog.postMessage({level, content});
        }
        for (const method of ['log', 'warn', 'error', 'debug', 'info']) {
            const original = console[method];
            console[method] = function() {
                log(method, [...arguments]);
                original.apply(console, arguments);
            }
        }
        })();
        """
        userScript = WebViewUserScript(source: contents, injectionTime: .atDocumentStart, forMainFrameOnly: true, world: .page)
    }
}
#endif

#if !SKIP
public typealias ContentWorld = WKContentWorld
#else
public class ContentWorld {
    public static var page: ContentWorld = ContentWorld()
    public static var defaultClient: ContentWorld = ContentWorld()

    public static func world(name: String) -> ContentWorld {
        ContentWorld(name: name)
    }

    public var name: String?

    private init(name: String? = nil) {
        self.name = name
    }
}
#endif

#if !SKIP
public typealias UserContentController = WKUserContentController
#else
public class UserContentController { }
#endif


#if !SKIP
public typealias ProcessPool = WKProcessPool
#else
public class ProcessPool { }
#endif


#if !SKIP
public typealias NavigationActionPolicy = WKNavigationActionPolicy
#else
public class NavigationActionPolicy { }
#endif


#if !SKIP
public typealias NavigationResponse = WKNavigationResponse
#else
public class NavigationResponse { }
#endif


#if !SKIP
public typealias NavigationResponsePolicy = WKNavigationResponsePolicy
#else
public class NavigationResponsePolicy { }
#endif


#if !SKIP
public typealias WebpagePreferences = WKWebpagePreferences
#else
public class WebpagePreferences {
}
#endif

#if !SKIP
public typealias URLSchemeHandler = WKURLSchemeHandler
#else
public protocol URLSchemeHandler {
    // SKIP @nobridge
    func interceptRequest(view: PlatformWebView, request: android.webkit.WebResourceRequest) -> android.webkit.WebResourceResponse
}
#endif

#if !SKIP
public typealias ScriptMessage = WKScriptMessage
#else
public class ScriptMessage {

}
#endif

#if !SKIP
public typealias ScriptMessageHandler = WKScriptMessageHandler
#else
public protocol ScriptMessageHandler {

}
#endif

#if !SKIP
public typealias ContentRuleList = WKContentRuleList
#else
public class ContentRuleList {
    public var identifier: String

    init(identifier: String) {
        self.identifier = identifier
    }
}
#endif


#if !SKIP
public typealias ContentRuleListStore = WKContentRuleListStore
#else
public class ContentRuleListStore {
}

#endif

// SKIP @nobridge
open class AbstractURLSchemeHandler : WebObjectBase, URLSchemeHandler {
    open func loadData(from fileName: String) -> Data? {
        fatalError("Implementations must override loadData")
    }
    
    #if SKIP

    public override func interceptRequest(view: PlatformWebView, request: android.webkit.WebResourceRequest) -> android.webkit.WebResourceResponse {
        let responseHeaders: kotlin.collections.Map<String, String> = kotlin.collections.HashMap()
        guard let url = URL(string: request.url.toString()) else {
            return android.webkit.WebResourceResponse(
                "text/plain",
                "utf-8",
                500,
                "Internal Server Error",
                responseHeaders,
                "Invalid URL \(request.url)".byteInputStream()
            )
        }
        
        var resourcePath = url.path
        if resourcePath.starts(with: "/") {
            resourcePath = String(resourcePath.dropFirst())
        }
        guard let data = loadData(from: resourcePath) else {
            logger.debug("404 error for URL: \(url)")
            return android.webkit.WebResourceResponse(
                "text/plain",
                "utf-8",
                404,
                "Not Found",
                responseHeaders,
                "Not Found URL \(request.url)".byteInputStream()
            )
        }
        
        let fileExtension = android.webkit.MimeTypeMap.getFileExtensionFromUrl(url.absoluteString)
        let mimeType = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(fileExtension) ?? "application/octet-stream"
        
        let response = android.webkit.WebResourceResponse(
            mimeType,
            "utf-8",
            java.io.ByteArrayInputStream(data.platformData)
        )
        
        logger.debug("Handled URL \(url)")
        return response
    }
    #else
    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        logger.debug("Requested URL: \(urlSchemeTask.request.url?.absoluteString ?? "<unknown>")");
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var resourcePath = url.path
        if resourcePath.starts(with: "/") {
            resourcePath = String(resourcePath.dropFirst())
        }
        guard let data = loadData(from: resourcePath) else {
            let error = NSError(
                domain: "SchemeHandlerError",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Resource not found: \(resourcePath)"]
            )
            logger.debug("404 error for URL: \(url)")
            urlSchemeTask.didFailWithError(error)
            return
        }
        
        let fileExtension = resourcePath.split(separator: ".").last ?? ""
        let mimeType = UTType(filenameExtension: String(fileExtension))?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": "\(data.count)"
            ]
        )
        
        if let response = response {
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            logger.debug("Handled URL \(url)");
        } else {
            let error = NSError(
                domain: "BundleResourceSchemeHandlerError",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Could not create HTTPURLResponse"]
            )
            logger.debug("500 error for URL: \(url)")
            urlSchemeTask.didFailWithError(error)
        }
        
    }
    
    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // no stopping
    }
    #endif
}

// SKIP @nobridge
public class BundleURLSchemeHandler: AbstractURLSchemeHandler {
    let bundle: Bundle
    let subdirectory: String?
    
    public init(bundle: Bundle = Bundle.main, subdirectory: String? = nil) {
        self.bundle = bundle
        self.subdirectory = subdirectory
    }
    
    public override func loadData(from fileName: String) -> Data? {
        guard let fileURL = bundle.url(forResource: fileName, withExtension: nil, subdirectory: self.subdirectory) else {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }
}

// SKIP @nobridge
public class DirectoryURLSchemeHandler: AbstractURLSchemeHandler {
    let directory: URL
    
    public init(directory: URL) {
        self.directory = directory
    }
    
    public override func loadData(from fileName: String) -> Data? {
        let file = directory.appendingPathComponent(fileName)
        logger.info("Reading \(fileName) from \(file)")
        return try? Data(contentsOf: file)
    }
}
#endif
#endif
