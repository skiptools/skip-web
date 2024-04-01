// This is free software: you can redistribute and/or modify it
// under the terms of the GNU Lesser General Public License 3.0
// as published by the Free Software Foundation https://fsf.org
import Foundation
#if SKIP
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

        let _: Navigation? = try await withCheckedThrowingContinuation { continuation in
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
@objc fileprivate class WebNavDelegate : NSObject, NavigationDelegate {
    let callback: (Result<Navigation?, Error>) -> ()
    var callbackInvoked = false

    init(callback: @escaping (Result<Navigation?, Error>) -> Void) {
        self.callback = callback
    }

    @objc func webView(_ webView: PlatformWebView, didFinish navigation: Navigation!) {
        logger.info("webView: \(webView) didFinish: \(navigation!)")
        if self.callbackInvoked { return }
        callbackInvoked = true
        self.callback(.success(navigation))
    }

    @objc func webView(_ webView: PlatformWebView, didFail navigation: Navigation!, withError error: any Error) {
        logger.info("webView: \(webView) didFail: \(navigation!) error: \(error)")
        if self.callbackInvoked { return }
        callbackInvoked = true
        self.callback(.failure(error))
    }
}
#endif


/// The configuration for a WebEngine
public struct WebEngineConfiguration {
    public let javaScriptEnabled: Bool
    public let contentRules: String?
    public let allowsBackForwardNavigationGestures: Bool
    public let allowsInlineMediaPlayback: Bool
    public let dataDetectorsEnabled: Bool
    public let isScrollEnabled: Bool
    public let pageZoom: CGFloat
    public let isOpaque: Bool
    public let userScripts: [WebViewUserScript]

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
                userScripts: [WebViewUserScript] = []) {
        self.javaScriptEnabled = javaScriptEnabled
        self.contentRules = contentRules
        self.allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures
        self.allowsInlineMediaPlayback = allowsInlineMediaPlayback
        self.dataDetectorsEnabled = dataDetectorsEnabled
        self.isScrollEnabled = isScrollEnabled
        self.pageZoom = pageZoom
        self.isOpaque = isOpaque
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
