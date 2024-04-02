// This is free software: you can redistribute and/or modify it
// under the terms of the GNU Lesser General Public License 3.0
// as published by the Free Software Foundation https://fsf.org
import Foundation
import SwiftUI
#if !SKIP
import WebKit
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

/// An web engine that holds a system web view:
/// [`WebKit.WKWebView`](https://developer.apple.com/documentation/webkit/wkwebview) on iOS and
/// [`android.webkit.WebView`](https://developer.android.com/reference/android/webkit/WebView) on Android
///
/// The `WebEngine` is used both as the render for a `WebView` and `BrowserView`,
/// and can also be used in a headless context to drive web pages
/// and evaluate JavaScript.
@MainActor public class WebEngine {
    public let configuration: WebEngineConfiguration
    public let webView: PlatformWebView

    /// Create a WebEngine with the specified configuration.
    /// - Parameters:
    ///   - configuration: the configuration to use
    ///   - webView: when set, the given platform-specific web view will
    public init(configuration: WebEngineConfiguration = WebEngineConfiguration(), webView: PlatformWebView? = nil) {
        self.configuration = configuration

        #if !SKIP
        self.webView = webView ?? PlatformWebView(frame: .zero, configuration: configuration.webViewConfiguration)
        #else
        // fall back to using the global android context if the activity context is not set in the configuration
        self.webView = webView ?? PlatformWebView(configuration.context ?? ProcessInfo.processInfo.androidContext)
        #endif
    }

    public func reload() {
        webView.reload()
    }

    public func go(to item: BackForwardListItem) {
        #if !SKIP
        webView.go(to: item)
        #endif
    }

    public func goBack() {
        webView.goBack()
    }

    public func goForward() {
        webView.goForward()
    }

    /// Evaluates the given JavaScript string
    public func evaluate(js: String) async throws -> String? {
        let result = try await evaluateJavaScriptAsync(js)
        guard let res = (result as? NSObject) else {
            return nil
        }
        return res.description
    }

    public func loadHTML(_ html: String, baseURL: URL? = nil, mimeType: String = "text/html") async throws {
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
        try await withNavigationDelegate {
            webView.load(Data(html.utf8), mimeType: mimeType, characterEncodingName: encoding, baseURL: baseURL ?? URL(string: "about:blank")!)
        }
        #endif
    }

    /// Asyncronously load the given URL, returning once the page has been loaded or an error has occurred
    public func load(url: URL) async throws {
        let urlString = url.absoluteString
        logger.info("load URL=\(urlString) webView: \(self.description)")
        #if SKIP
        // TODO: set up the equivalent of a navigation delegate
        webView.loadUrl(urlString ?? "about:blank")
        #else
        try await withNavigationDelegate {
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url)
            } else {
                webView.load(URLRequest(url: url))
            }
        }

        #endif
    }

    fileprivate func evaluateJavaScriptAsync(_ script: String) async throws -> Any {
        #if !SKIP
        try await webView.evaluateJavaScript(script)
        #else
        logger.info("WebEngine: calling eval: \(android.os.Looper.myLooper())")
    //    withContext(Dispatchers.IO) {
            logger.info("WebEngine: calling eval withContext(Dispatchers.IO): \(android.os.Looper.myLooper())")
            //suspendCoroutine
            suspendCancellableCoroutine { continuation in
                logger.info("WebEngine: calling eval suspendCoroutine: \(android.os.Looper.myLooper())")
    //            withContext(Dispatchers.Main) {
                    webView.evaluateJavascript(script) { result in
                        logger.info("WebEngine: returned webView.evaluateJavascript: \(android.os.Looper.myLooper()): \(result)")
                        continuation.resume(result)
                    }

                    continuation.invokeOnCancellation {
                        continuation.cancel()
                    }
    //            }
            }
    //    }
        #endif
    }

    #if !SKIP
    func withNavigationDelegate(_ block: () -> ()) async throws {
        let pdelegate = webView.navigationDelegate
        defer { webView.navigationDelegate = pdelegate }

        // need to retain the navigation delegate or else it will drop the continuation
        var navDelegate: WebNavDelegate? = nil

        let _: WebNavigation? = try await withCheckedThrowingContinuation { continuation in
            navDelegate = WebNavDelegate { result in
                continuation.resume(with: result)
            }

            webView.navigationDelegate = navDelegate
            block()
        }

    }
    #endif
}


extension WebEngine : CustomStringConvertible {
    public var description: String {
        "WebEngine: \(webView)"
    }
}


#if !SKIP
/// A temporary NavigationDelegate that uses a callback to integrate with checked continuations
@objc fileprivate class WebNavDelegate : NSObject, WebNavigationDelegate {
    let callback: (Result<WebNavigation?, Error>) -> ()
    var callbackInvoked = false

    init(callback: @escaping (Result<WebNavigation?, Error>) -> Void) {
        self.callback = callback
    }

    @objc func webView(_ webView: PlatformWebView, didFinish navigation: WebNavigation!) {
        logger.info("webView: \(webView) didFinish: \(navigation!)")
        if self.callbackInvoked { return }
        callbackInvoked = true
        self.callback(.success(navigation))
    }

    @objc func webView(_ webView: PlatformWebView, didFail navigation: WebNavigation!, withError error: any Error) {
        logger.info("webView: \(webView) didFail: \(navigation!) error: \(error)")
        if self.callbackInvoked { return }
        callbackInvoked = true
        self.callback(.failure(error))
    }
}
#endif


/// The configuration for a WebEngine
public class WebEngineConfiguration : ObservableObject {
    @Published public var javaScriptEnabled: Bool
    @Published public var contentRules: String?
    @Published public var allowsBackForwardNavigationGestures: Bool
    @Published public var allowsInlineMediaPlayback: Bool
    @Published public var dataDetectorsEnabled: Bool
    @Published public var isScrollEnabled: Bool
    @Published public var pageZoom: CGFloat
    @Published public var isOpaque: Bool
    @Published public var searchEngines: [SearchEngine]
    @Published public var userScripts: [WebViewUserScript]

    #if SKIP
    /// The Android context to use for creating a web context
    public var context: android.content.Context? = nil
    #endif

    public init(javaScriptEnabled: Bool = true,
                contentRules: String? = nil,
                allowsBackForwardNavigationGestures: Bool = true,
                allowsInlineMediaPlayback: Bool = true,
                dataDetectorsEnabled: Bool = true,
                isScrollEnabled: Bool = true,
                pageZoom: CGFloat = 1.0,
                isOpaque: Bool = true,
                searchEngines: [SearchEngine] = [],
                userScripts: [WebViewUserScript] = []) {
        self.javaScriptEnabled = javaScriptEnabled
        self.contentRules = contentRules
        self.allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures
        self.allowsInlineMediaPlayback = allowsInlineMediaPlayback
        self.dataDetectorsEnabled = dataDetectorsEnabled
        self.isScrollEnabled = isScrollEnabled
        self.pageZoom = pageZoom
        self.isOpaque = isOpaque
        self.searchEngines = searchEngines
        self.userScripts = userScripts
    }

    #if !SKIP
    /// Create a `WebViewConfiguration` from the properties of this configuration.
    @MainActor var webViewConfiguration: WebViewConfiguration {
        let configuration = WebViewConfiguration()

        //let preferences = WebpagePreferences()
        //preferences.allowsContentJavaScript //

        #if !os(macOS) // API unavailable on macOS
        configuration.allowsInlineMediaPlayback = self.allowsInlineMediaPlayback
        configuration.dataDetectorTypes = [.all]
        //configuration.defaultWebpagePreferences = preferences
        configuration.dataDetectorTypes = [.calendarEvent, .flightNumber, .link, .lookupSuggestion, .trackingNumber]

//        for (urlSchemeHandler, urlScheme) in schemeHandlers {
//            configuration.setURLSchemeHandler(urlSchemeHandler, forURLScheme: urlScheme)
//        }
        #endif

        return configuration
    }
    #endif
}



#if !SKIP
public typealias BackForwardListItem = WKBackForwardListItem
#else
// TODO: wrap https://developer.android.com/reference/android/webkit/WebHistoryItem
open struct BackForwardListItem {
    public var url: URL
    public var title: String?
    public var initialURL: URL
}
#endif

public struct WebViewMessage: Equatable {
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
open class UserScript : NSObject {
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

    public init(source: String, injectionTime: UserScriptInjectionTime, forMainFrameOnly: Bool, world: ContentWorld = .defaultClient, allowedDomains: Set<String> = Set()) {
        self.source = source
        self.webKitUserScript = UserScript(source: source, injectionTime: injectionTime, forMainFrameOnly: forMainFrameOnly, in: world)
        self.allowedDomains = allowedDomains
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(allowedDomains)
    }
}

#if !SKIP
public typealias ContentWorld = WKContentWorld
#else
public class ContentWorld {
    static var page: ContentWorld = ContentWorld()
    static var defaultClient: ContentWorld = ContentWorld()

    static func world(name: String) -> ContentWorld {
        fatalError("TODO")
    }

    public var name: String?
}
#endif
