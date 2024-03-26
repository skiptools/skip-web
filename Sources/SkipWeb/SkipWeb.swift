// This is free software: you can redistribute and/or modify it
// under the terms of the GNU Lesser General Public License 3.0
// as published by the Free Software Foundation https://fsf.org
import SwiftUI
import OSLog
#if !SKIP
import WebKit
public typealias PlatformWebView = WKWebView
#else
public typealias PlatformWebView = android.webkit.WebView
//import android.webkit.WebView // not imported because it conflicts with SkipWeb.WebView

import androidx.compose.runtime.Composable
import androidx.compose.ui.viewinterop.AndroidView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat.startActivity

import android.webkit.WebViewClient
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse

import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewClientCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature

import androidx.webkit.WebSettingsCompat.DARK_STRATEGY_PREFER_WEB_THEME_OVER_USER_AGENT_DARKENING

import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlinx.coroutines.async
import kotlinx.coroutines.launch

#endif

let logger: Logger = Logger(subsystem: "SkipWeb", category: "WebView")

let homePage = "https://google.com"
let homeURL = URL(string: homePage)!


@Observable public class BrowserViewModel {
    var url = ""
    public init(url: String) {
        self.url = url
    }
}


/// A complete browser view, including a URL bar, the WebView canvas, and toolbar buttons for common actions.
@MainActor public struct BrowserView: View {
    @State var viewModel = BrowserViewModel(url: homePage)
    @State var state = WebViewState()
    @State var navigator = WebViewNavigator()
    let configuration: WebEngineConfiguration

    public init(configuration: WebEngineConfiguration) {
        self.configuration = configuration
    }

    public var body: some View {
        VStack {
            URLBar()
            WebView(configuration: configuration, navigator: navigator, state: $state)
                .frame(maxHeight: .infinity)
                .task {
                    navigator.load(url: homeURL)
                }
        }
        .toolbar {
            #if os(macOS)
            let toolbarPlacement = ToolbarItemPlacement.automatic
            #else
            let toolbarPlacement = ToolbarItemPlacement.bottomBar
            #endif

            ToolbarItemGroup(placement: toolbarPlacement) {
                Button(action: { backButtonTapped() }) {
                    Label("Back", systemImage: "chevron.left")
                }
//                .disabled(!state.canGoBack)
                Spacer()
                Button(action: { forwardButtonTapped() }) {
                    Label("Forward", systemImage: "chevron.right")
                }
//                .disabled(!state.canGoForward)
                Spacer()

                ShareLink(item: state.pageURL ?? homeURL)
                        .disabled(state.pageURL == nil)

                Spacer()
                Button(action: { settingsButtonTapped() }) {
                    Label("Settings", systemImage: "gearshape")
                }
                Spacer()
                Button(action: { reloadButtonTapped() }) {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }

    @ViewBuilder func URLBar() -> some View {
        HStack {
            Button(action: { homeButtonTapped() }) {
                #if SKIP
                Image(systemName: "house")
                #else
                Label("Home", systemImage: "house")
                    .labelStyle(.iconOnly)
                #endif
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.mint)

            TextField(text: $viewModel.url) {
                Text("URL or search")
            }
            .textFieldStyle(.roundedBorder)
            .font(.title2)
            .autocorrectionDisabled()
            #if !SKIP
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            #endif

            Button(action: { reloadButtonTapped() }) {
                #if SKIP
                Image(systemName: "arrow.clockwise.circle")
                #else
                Label("Reload", systemImage: "arrow.clockwise.circle")
                    .labelStyle(.iconOnly)
                #endif
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.mint)
        }
    }

    func homeButtonTapped() {
        logger.info("homeButtonTapped")
        navigator.load(url: homeURL)
    }

    func backButtonTapped() {
        logger.info("backButtonTapped")
        navigator.goBack()
    }

    func forwardButtonTapped() {
        logger.info("forwardButtonTapped")
        navigator.goForward()
    }

    func reloadButtonTapped() {
        logger.info("reloadButtonTapped")
        navigator.reload()
    }

    func settingsButtonTapped() {
        logger.info("settingsButtonTapped")
        // TODO
    }
}


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

        let _: WKNavigation? = try await withCheckedThrowingContinuation { continuation in
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
/// A temporary WKNavigationDelegate that uses a callback to integrate with checked continuations
@objc fileprivate class WebNavDelegate : NSObject, WKNavigationDelegate {
    let callback: (Result<WKNavigation?, Error>) -> ()
    var callbackInvoked = false

    init(callback: @escaping (Result<WKNavigation?, Error>) -> Void) {
        self.callback = callback
    }

    @objc func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logger.info("webView: \(webView) didFinish: \(navigation!)")
        if self.callbackInvoked { return }
        callbackInvoked = true
        self.callback(.success(navigation))
    }

    @objc func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
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
    public let backgroundColor: Color
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
                backgroundColor: Color = .clear,
                userScripts: [WebViewUserScript] = []) {
        self.javaScriptEnabled = javaScriptEnabled
        self.contentRules = contentRules
        self.allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures
        self.allowsInlineMediaPlayback = allowsInlineMediaPlayback
        self.dataDetectorsEnabled = dataDetectorsEnabled
        self.isScrollEnabled = isScrollEnabled
        self.pageZoom = pageZoom
        self.isOpaque = isOpaque
        self.backgroundColor = backgroundColor
        self.userScripts = userScripts
    }

    #if !SKIP
    /// Create a `WKWebViewConfiguration` from the properties of this configuration.
    @MainActor var webViewConfiguration: WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()

        //let preferences = WKWebpagePreferences()
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

/// The current state of a web page, including the loading status and the current URL
@Observable public class WebViewState {
    public internal(set) var isLoading: Bool
    public internal(set) var isProvisionallyNavigating: Bool
    public internal(set) var pageURL: URL?
    public internal(set) var pageTitle: String?
    public internal(set) var pageImageURL: URL?
    public internal(set) var pageHTML: String?
    public internal(set) var error: Error?
    public internal(set) var canGoBack: Bool
    public internal(set) var canGoForward: Bool
    public internal(set) var backList: [BackForwardListItem]
    public internal(set) var forwardList: [BackForwardListItem]

    public init(isLoading: Bool = false, isProvisionallyNavigating: Bool = false, pageURL: URL? = nil, pageTitle: String? = nil, pageImageURL: URL? = nil, pageHTML: String? = nil, error: Error? = nil, canGoBack: Bool = false, canGoForward: Bool = false, backList: [BackForwardListItem] = [], forwardList: [BackForwardListItem] = []) {
        self.isLoading = isLoading
        self.isProvisionallyNavigating = isProvisionallyNavigating
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.pageImageURL = pageImageURL
        self.pageHTML = pageHTML
        self.error = error
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.backList = backList
        self.forwardList = forwardList
    }
}


/// A controller that can drive a `WebEngine` from a user interface.
public class WebViewNavigator {
    @MainActor var webEngine: WebEngine? {
        didSet {
            logger.info("assigned webEngine: \(self.webEngine?.description ?? "NULL")")

//            guard let webView = webView else { return }
            // TODO: Make about:blank history initialization optional via configuration.
//            if !webView.canGoBack && !webView.canGoForward && (webView.url == nil || webView.url?.absoluteString == "about:blank") {
//                load(URLRequest(url: URL(string: "about:blank")!))
//            }
        }
    }

    public init() {
    }

    @MainActor public func load(url: URL) {
        let urlString = url.absoluteString
        logger.info("load URL=\(urlString) webView: \(self.webEngine?.description ?? "NONE")")
        guard let webView = webEngine?.webView else { return }
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

    @MainActor public func reload() {
        logger.info("reload webView: \(self.webEngine?.description ?? "NONE")")
        webEngine?.reload()
    }

    @MainActor public func go(_ item: BackForwardListItem) {
        logger.info("go: \(item) webView: \(self.webEngine?.description ?? "NONE")")
        #if !SKIP
        webEngine?.go(to: item)
        #endif
    }

    @MainActor public func goBack() {
        logger.info("goBack webView: \(self.webEngine?.description ?? "NONE")")
        webEngine?.goBack()
    }

    @MainActor public func goForward() {
        logger.info("goForward webView: \(self.webEngine?.description ?? "NONE")")
        webEngine?.goForward()
    }
}


/// An embedded WebKit view. It is configured using a `WebEngineConfiguration`
///  and driven with a `WebViewNavigator` which can be associated
///  with user interface controls like back/forward buttons and a URL bar.
public struct WebView : View {
    private let config: WebEngineConfiguration
    let navigator: WebViewNavigator

    @Binding var state: WebViewState
    @State fileprivate var needsHistoryRefresh: Bool
    @State private var lastInstalledScripts: [WebViewUserScript]

    var scriptCaller: WebViewScriptCaller? = nil
    let blockedHosts: Set<String>? = []
    let htmlInState: Bool = false
    let schemeHandlers: [(WKURLSchemeHandler, String)] = []
    var messageHandlers: [String: ((WebViewMessage) async -> Void)] = [:]
    let onNavigationCommitted: ((WebViewState) -> Void)? = nil
    let onNavigationFinished: ((WebViewState) -> Void)? = nil
    let persistentWebViewID: String? = nil

    private var messageHandlerNamesToRegister = Set<String>()
    private var userContentController = WKUserContentController()

    private static var engineCache: [String: WebEngine] = [:]
    private static let processPool = WKProcessPool()

    //let onWarm: (() async -> Void)?
    //@State fileprivate var isWarm = false

    public init(configuration: WebEngineConfiguration, navigator: WebViewNavigator, state: Binding<WebViewState>) {
        self.config = configuration
        self.navigator = navigator

        self._state = state
        self.needsHistoryRefresh = false
        self.lastInstalledScripts = []
    }
}


// MARK: SkipUI interop with legacy UIKit/AndroidView system

#if SKIP
protocol ViewRepresentable { 

}
#elseif canImport(UIKit)
typealias ViewRepresentable = UIViewRepresentable
#elseif canImport(AppKit)
typealias ViewRepresentable = NSViewRepresentable
#else
#error("Unsupported platform")
#endif

extension WebView : ViewRepresentable {
    public typealias Coordinator = WebViewCoordinator

    public func makeCoordinator() -> Coordinator {
        WebViewCoordinator(webView: self, navigator: navigator, scriptCaller: scriptCaller, config: config)
    }

    @MainActor private func setupWebView(_ webEngine: WebEngine) -> WebEngine {
        navigator.webEngine = webEngine

        // configure JavaScript
        #if SKIP
        let settings = webEngine.webView.settings
        settings.setJavaScriptEnabled(config.javaScriptEnabled)
        settings.setSafeBrowsingEnabled(false)

        //settings.setAlgorithmicDarkeningAllowed(boolean allow)
        //settings.setAllowContentAccess(boolean allow)
        //settings.setAllowFileAccess(boolean allow)
        //settings.setAllowFileAccessFromFileURLs(boolean flag) // deprecated
        //settings.setAllowUniversalAccessFromFileURLs(boolean flag) // deprecated
        //settings.setBlockNetworkImage(boolean flag)
        //settings.setBlockNetworkLoads(boolean flag)
        //settings.setBuiltInZoomControls(boolean enabled)
        //settings.setCacheMode(int mode)
        //settings.setCursiveFontFamily(String font)
        //settings.setDatabaseEnabled(boolean flag)
        //settings.setDatabasePath(String databasePath) // deprecated
        //settings.setDefaultFixedFontSize(int size)
        //settings.setDefaultFontSize(int size)
        //settings.setDefaultTextEncodingName(String encoding)
        //settings.setDefaultZoom(WebSettings.ZoomDensity zoom) // deprecated
        //settings.setDisabledActionModeMenuItems(int menuItems)
        //settings.setDisplayZoomControls(boolean enabled)
        //settings.setDomStorageEnabled(boolean flag)
        //settings.setEnableSmoothTransition(boolean enable) // deprecated
        //settings.setFantasyFontFamily(String font)
        //settings.setFixedFontFamily(String font)
        //settings.setForceDark(int forceDark) // deprecated
        //settings.setGeolocationDatabasePath(String databasePath) // deprecated
        //settings.setGeolocationEnabled(boolean flag)
        //settings.setJavaScriptCanOpenWindowsAutomatically(boolean flag)
        //settings.setLayoutAlgorithm(WebSettings.LayoutAlgorithm l)
        //settings.setLightTouchEnabled(boolean enabled) // deprecated
        //settings.setLoadWithOverviewMode(boolean overview)
        //settings.setLoadsImagesAutomatically(boolean flag)
        //settings.setMediaPlaybackRequiresUserGesture(boolean require)
        //settings.setMinimumFontSize(int size)
        //settings.setMinimumLogicalFontSize(int size)
        //settings.setMixedContentMode(int mode)
        //settings.setNeedInitialFocus(boolean flag)
        //settings.setOffscreenPreRaster(boolean enabled)
        //settings.setPluginState(WebSettings.PluginState state) // deprecated
        //settings.setRenderPriority(WebSettings.RenderPriority priority) // deprecated
        //settings.setSansSerifFontFamily(String font)
        //settings.setSaveFormData(boolean save) // deprecated
        //settings.setSavePassword(boolean save) // deprecated
        //settings.setSerifFontFamily(String font)
        //settings.setStandardFontFamily(String font)
        //settings.setSupportMultipleWindows(boolean support)
        //settings.setSupportZoom(boolean support)
        //settings.setTextSize(WebSettings.TextSize t)
        //settings.setTextZoom(int textZoom)
        //settings.setUseWideViewPort(boolean use)
        //settings.setUserAgentString(String ua)
        #else
        let configuration = webEngine.webView.configuration
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.suppressesIncrementalRendering = false
        //configuration.mediaTypesRequiringUserActionForPlayback =
        //configuration.userContentController =
        //configuration.allowsInlinePredictions =
        //configuration.applicationNameForUserAgent =
        //configuration.limitsNavigationsToAppBoundDomains =
        //configuration.upgradeKnownHostsToHTTPS =

        let preferences = configuration.defaultWebpagePreferences!
        preferences.allowsContentJavaScript = config.javaScriptEnabled
        preferences.preferredContentMode = .recommended
        // preferences.isLockdownModeEnabled = false // The 'com.apple.developer.web-browser' restricted entitlement is required to disable lockdown mode

        #endif

        return webEngine
    }

    #if SKIP
    public var body: some View {
        ComposeView { ctx in
            AndroidView(factory: { ctx in
                config.context = ctx
                let webEngine = WebEngine(config)

                webEngine.webView.webViewClient = WebViewClient()
                return setupWebView(webEngine).webView
            }, modifier: ctx.modifier, update: { webView in
                //webView.loadUrl(url.absoluteString)
            })
        }
    }
    #else
    @MainActor private func makeWebEngine(id: String?, config: WebEngineConfiguration, coordinator: WebViewCoordinator, messageHandlerNamesToRegister: Set<String>) -> WebEngine {
        var web: WebEngine?
        if let id = id {
            web = Self.engineCache[id] // it is UI thread so safe to access static
            for messageHandlerName in coordinator.messageHandlerNames {
                web?.webView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
            }
        }
        if web == nil {
            let engine = WebEngine(configuration: config)
            logger.info("created WebEngine \(id ?? "noid"): \(engine)")
            web = setupWebView(engine)
            if let id = id {
                Self.engineCache[id] = engine
            }

            #if !os(macOS) // API unavailable on macOS
            web?.webView.isOpaque = false
            web?.webView.backgroundColor = .clear
            //web?.backgroundColor = .white
            #endif
        }

        guard let web = web else {
            fatalError("couldn't instantiate WKWebView for WebView.")
        }

        for messageHandlerName in messageHandlerNamesToRegister {
            if coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
            web.webView.configuration.userContentController.add(coordinator, contentWorld: .page, name: messageHandlerName)
            coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }

        return web
    }

    public func update(webView: WKWebView) {
        logger.info("WebView.update: \(webView)")
        //webView.load(URLRequest(url: url))
    }

    @MainActor private func create(from context: Context) -> WebEngine {
        let webEngine = makeWebEngine(id: persistentWebViewID, config: config, coordinator: context.coordinator, messageHandlerNamesToRegister: messageHandlerNamesToRegister)
        let webView = webEngine.webView
        refreshMessageHandlers(userContentController: webView.configuration.userContentController, context: context)

        refreshContentRules(userContentController: webView.configuration.userContentController, coordinator: context.coordinator)

        webView.configuration.userContentController = userContentController
        webView.allowsLinkPreview = true
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures
        
        #if os(iOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .always
//        webView.scrollView.contentInsetAdjustmentBehavior = .scrollableAxes
        webView.scrollView.isScrollEnabled = config.isScrollEnabled
        webView.pageZoom = config.pageZoom
        webView.isOpaque = config.isOpaque
        if #available(iOS 14.0, *) {
            webView.backgroundColor = UIColor(config.backgroundColor)
        } else {
            webView.backgroundColor = .clear
        }
        #endif
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        context.coordinator.navigator.webEngine = webEngine
        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
            context.coordinator.scriptCaller = scriptCaller
        }
        context.coordinator.scriptCaller?.caller = {
            webView.evaluateJavaScript($0, completionHandler: $1)
        }

        context.coordinator.scriptCaller?.asyncCaller = { js, args, frame, world in
            let world = world ?? .defaultClient
            if let args = args {
                return try await webView.callAsyncJavaScript(js, arguments: args, in: frame, contentWorld: world)
            } else {
                return try await webView.callAsyncJavaScript(js, in: frame, contentWorld: world)
            }
        }

        // In case we retrieved a cached web view that is already warm but we don't know it.
        //webView.evaluateJavaScript("window.webkit.messageHandlers.swiftUIWebViewIsWarm.postMessage({})")

        //return WebViewController(webView: webView, persistentWebViewID: persistentWebViewID)

        return webEngine
    }

    #if canImport(UIKit)
    public func makeUIView(context: Context) -> WKWebView { create(from: context).webView }
    public func updateUIView(_ uiView: WKWebView, context: Context) { update(webView: uiView) }
    #elseif canImport(AppKit)
    public func makeNSView(context: Context) -> WKWebView { create(from: context).webView }
    public func updateNSView(_ nsView: WKWebView, context: Context) { update(webView: nsView) }
    #endif
    #endif
}


// TODO: translate script logic for Skip
#if !SKIP
extension WebView {
    @MainActor
    func refreshContentRules(userContentController: WKUserContentController, coordinator: Coordinator) {
        userContentController.removeAllContentRuleLists()
        guard let contentRules = config.contentRules else { return }
        if let ruleList = coordinator.compiledContentRules[contentRules] {
            userContentController.add(ruleList)
        } else {
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "ContentBlockingRules",
                encodedContentRuleList: contentRules) { (ruleList, error) in
                    guard let ruleList = ruleList else {
                        if let error = error {
                            print(error)
                        }
                        return
                    }
                    userContentController.add(ruleList)
                    coordinator.compiledContentRules[contentRules] = ruleList
                }
        }
    }

    @MainActor
    func refreshMessageHandlers(userContentController: WKUserContentController, context: Context) {
        for messageHandlerName in Self.systemMessageHandlers + messageHandlerNamesToRegister {
            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }

            #if !SKIP
            // Sometimes we reuse an underlying WKWebView for a new SwiftUI component.
            userContentController.removeScriptMessageHandler(forName: messageHandlerName, contentWorld: .page)
            userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
            #endif
            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }
        for missing in context.coordinator.registeredMessageHandlerNames.subtracting(Self.systemMessageHandlers + messageHandlerNamesToRegister) {
            userContentController.removeScriptMessageHandler(forName: missing)
        }
    }

    @MainActor
    func updateUserScripts(userContentController: WKUserContentController, coordinator: WebViewCoordinator, forDomain domain: URL?, config: WebEngineConfiguration) {
        var scripts = config.userScripts
        if let domain = domain?.domainURL.host {
            scripts = scripts.filter { $0.allowedDomains.isEmpty || $0.allowedDomains.contains(domain) }
        } else {
            scripts = scripts.filter { $0.allowedDomains.isEmpty }
        }
        let allScripts = Self.systemScripts + scripts
//        guard allScripts.hashValue != coordinator.lastInstalledScriptsHash else { return }
        if userContentController.userScripts.sorted(by: { $0.source > $1.source }) != allScripts.map({ $0.webKitUserScript }).sorted(by: { $0.source > $1.source }) {
            userContentController.removeAllUserScripts()
            for script in allScripts {
                userContentController.addUserScript(script.webKitUserScript)
            }
        }
//        coordinator.lastInstalledScriptsHash = allScripts.hashValue
    }

    fileprivate static let systemScripts = [
        LocationChangeUserScript().userScript,
        ImageChangeUserScript().userScript,
    ]

    fileprivate static var systemMessageHandlers: [String] {
        [
            "swiftUIWebViewLocationChanged",
            "swiftUIWebViewImageUpdated",
        ]
    }
}
#endif


public class WebViewCoordinator: NSObject {
    private let webView: WebView

    var navigator: WebViewNavigator
    var scriptCaller: WebViewScriptCaller?
    var config: WebEngineConfiguration
    var registeredMessageHandlerNames = Set<String>()

    var compiledContentRules = [String: WKContentRuleList]()

    var messageHandlerNames: [String] {
        webView.messageHandlers.keys.map { $0 }
    }

    init(webView: WebView, navigator: WebViewNavigator, scriptCaller: WebViewScriptCaller? = nil, config: WebEngineConfiguration) {
        self.webView = webView
        self.navigator = navigator
        self.scriptCaller = scriptCaller
        self.config = config

        // TODO: Make about:blank history initialization optional via configuration.
//        #warning("confirm this sitll works")
//        if  webView.state.backList.isEmpty && webView.state.forwardList.isEmpty && webView.state.pageURL.absoluteString == "about:blank" {
//            Task { @MainActor in
//                webView.action = .load(URLRequest(url: URL(string: "about:blank")!))
//            }
//        }
    }

    @discardableResult func setLoading(_ isLoading: Bool, pageURL: URL? = nil, isProvisionallyNavigating: Bool? = nil, canGoBack: Bool? = nil, canGoForward: Bool? = nil, backList: [BackForwardListItem]? = nil, forwardList: [BackForwardListItem]? = nil, error: Error? = nil) -> WebViewState {
        let newState = webView.state
        newState.isLoading = isLoading
        if let pageURL = pageURL {
            newState.pageURL = pageURL
        }
        if let isProvisionallyNavigating = isProvisionallyNavigating {
            newState.isProvisionallyNavigating = isProvisionallyNavigating
        }
        if let canGoBack = canGoBack {
            newState.canGoBack = canGoBack
        }
        if let canGoForward = canGoForward {
            newState.canGoForward = canGoForward
        }
        if let backList = backList {
            newState.backList = backList
        }
        if let forwardList = forwardList {
            newState.forwardList = forwardList
        }
        if let error = error {
            newState.error = error
        }
        webView.state = newState
        return newState
    }
}

#if !SKIP
extension WebViewCoordinator: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "swiftUIWebViewLocationChanged" {
            webView.needsHistoryRefresh = true
            return
        } else if message.name == "swiftUIWebViewImageUpdated" {
            guard let body = message.body as? [String: Any] else { return }
            if let imageURLRaw = body["imageURL"] as? String, let urlRaw = body["url"] as? String, let url = URL(string: urlRaw), let imageURL = URL(string: imageURLRaw), url == webView.state.pageURL {
                let newState = webView.state
                newState.pageImageURL = imageURL
                let targetState = newState
                Task { @MainActor in
                // DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [webView] in
                    webView.state = targetState
                }
            }
        }
        /* else if message.name == "swiftUIWebViewIsWarm" {
            if !webView.isWarm, let onWarm = webView.onWarm {
                Task { @MainActor in
                    webView.isWarm = true
                    await onWarm()
                }
            }
            return
        }*/

        guard let messageHandler = webView.messageHandlers[message.name] else { return }
        let msg = WebViewMessage(frameInfo: message.frameInfo, uuid: UUID(), name: message.name, body: message.body)
        Task {
            await messageHandler(msg)
        }
    }
}
#endif

public struct WebViewMessage: Equatable {
    public let frameInfo: WKFrameInfo
    fileprivate let uuid: UUID
    public let name: String
    public let body: Any

    public static func == (lhs: WebViewMessage, rhs: WebViewMessage) -> Bool {
        lhs.uuid == rhs.uuid
        && lhs.name == rhs.name && lhs.frameInfo == rhs.frameInfo
    }
}

public struct WebViewUserScript: Equatable, Hashable {
    public let source: String
    public let webKitUserScript: WKUserScript
    public let allowedDomains: Set<String>

    public static func == (lhs: WebViewUserScript, rhs: WebViewUserScript) -> Bool {
        lhs.source == rhs.source
        && lhs.allowedDomains == rhs.allowedDomains
    }

    public init(source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool, world: WKContentWorld = .defaultClient, allowedDomains: Set<String> = Set()) {
        self.source = source
        self.webKitUserScript = WKUserScript(source: source, injectionTime: injectionTime, forMainFrameOnly: forMainFrameOnly, in: world)
        self.allowedDomains = allowedDomains
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(allowedDomains)
    }
}


#if !SKIP
extension WebViewCoordinator: WKNavigationDelegate {
    @MainActor
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let newState = setLoading(
            false,
            pageURL: webView.url,
            isProvisionallyNavigating: false,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList)
        // TODO: Move to an init postMessage callback
        /*
        if let url = webView.url, let scheme = url.scheme, scheme == "pdf" || scheme == "pdf-url", url.absoluteString.hasPrefix("\(url.scheme ?? "")://"), url.pathExtension.lowercased() == "pdf", let loaderURL = URL(string: "\(scheme)://\(url.absoluteString.dropFirst("\(url.scheme ?? "")://".count))") {
            // TODO: Escaping? Use async eval for passing object data.
            let jsString = "pdfjsLib.getDocument('\(loaderURL.absoluteString)').promise.then(doc => { PDFViewerApplication.load(doc); });"
            webView.evaluateJavaScript(jsString, completionHandler: nil)
        }
         */

        if let onNavigationFinished = self.webView.onNavigationFinished {
            onNavigationFinished(newState)
        }

        extractPageState(webView: webView)
    }

    private func extractPageState(webView: WKWebView) {
        webView.evaluateJavaScript("document.title") { (response, error) in
            if let title = response as? String {
                let newState = self.webView.state
                newState.pageTitle = title
                self.webView.state = newState
            }
        }

        webView.evaluateJavaScript("document.URL.toString()") { (response, error) in
            if let url = response as? String, let newURL = URL(string: url), self.webView.state.pageURL != newURL {
                let newState = self.webView.state
                newState.pageURL = newURL
                self.webView.state = newState
            }
        }

        if self.webView.htmlInState {
            webView.evaluateJavaScript("document.documentElement.outerHTML.toString()") { (response, error) in
                if let html = response as? String {
                    let newState = self.webView.state
                    newState.pageHTML = html
                    self.webView.state = newState
                }
            }
        }
    }

    @MainActor
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        scriptCaller?.removeAllMultiTargetFrames()
        setLoading(false, isProvisionallyNavigating: false, error: error)

    }

    @MainActor
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setLoading(false, isProvisionallyNavigating: false)
    }

    @MainActor
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        scriptCaller?.removeAllMultiTargetFrames()
        setLoading(false, isProvisionallyNavigating: false, error: error)

        extractPageState(webView: webView)
    }

    @MainActor
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        scriptCaller?.removeAllMultiTargetFrames()
        let newState = setLoading(true, pageURL: webView.url, isProvisionallyNavigating: false)
        if let onNavigationCommitted = self.webView.onNavigationCommitted {
            onNavigationCommitted(newState)
        }
    }

    @MainActor
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setLoading(
            true,
            isProvisionallyNavigating: true,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList)
    }

    @MainActor
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if let host = navigationAction.request.url?.host, let blockedHosts = self.webView.blockedHosts {
            if blockedHosts.contains(where: { host.contains($0) }) {
                setLoading(false, isProvisionallyNavigating: false)
                return (.cancel, preferences)
            }
        }

        if navigationAction.targetFrame?.isMainFrame ?? false {
            self.webView.refreshContentRules(userContentController: webView.configuration.userContentController, coordinator: self)
        }

        return (.allow, preferences)
    }

    @MainActor
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let url = navigationResponse.response.url, self.webView.state.pageURL != url {
            scriptCaller?.removeAllMultiTargetFrames()
            let newState = self.webView.state
            newState.pageURL = url
            newState.pageTitle = nil
            newState.pageHTML = nil
            newState.error = nil
            self.webView.state = newState
        }

        if navigationResponse.isForMainFrame,
            let mainDocumentURL = navigationResponse.response.url {
            self.webView.updateUserScripts(userContentController: webView.configuration.userContentController, coordinator: self, forDomain: mainDocumentURL, config: config)
        }

        return .allow
    }
}
#endif

public class WebViewScriptCaller: Equatable, ObservableObject {
    let uuid = UUID().uuidString
    var caller: ((String, ((Any?, Error?) -> Void)?) -> Void)? = nil
    var asyncCaller: ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?) async throws -> Any?)? = nil

    private var multiTargetFrames = [String: WKFrameInfo]()

    public init() {
    }

    public static func == (lhs: WebViewScriptCaller, rhs: WebViewScriptCaller) -> Bool {
        return lhs.uuid == rhs.uuid
    }

    @MainActor
    public func evaluateJavaScript(_ js: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        guard let caller = caller else {
            print("No caller set for WebViewScriptCaller \(uuid)") // TODO: Error
            return
        }
        caller(js, completionHandler)
    }

    @MainActor
    public func evaluateJavaScript(_ js: String, arguments: [String: Any]? = nil, frame: WKFrameInfo? = nil, duplicateInMultiTargetFrames: Bool = false, in world: WKContentWorld? = .page, completionHandler: ((Result<Any?, any Error>) async throws -> Void)? = nil) async {
        guard let asyncCaller = asyncCaller else {
            logger.error("evaluateJavaScript: no asyncCaller set for WebViewScriptCaller \(self.uuid)") // TODO: Error
            return
        }
        
        do {
            let result = try await asyncCaller(js, arguments, frame, world)
            // SKIP NOWARN
            try await completionHandler?(Result.success(result))
            if duplicateInMultiTargetFrames {
                for (uuid, targetFrame) in multiTargetFrames {
                    if targetFrame == frame { continue }
                    do {
                        _ = try await asyncCaller(js, arguments, targetFrame, world)
                    } catch {
                        logger.error("evaluateJavaScript error: \(error)")
                        #if !SKIP
                        if let error = error as? WKError, error.code == .javaScriptInvalidFrameTarget {
                            multiTargetFrames.removeValue(forKey: uuid)
                        } else {
                            logger.error("evaluateJavaScript: error: \(error)")
                        }
                        #endif
                    }
                }
            }
        } catch {
            // SKIP NOWARN
            try? await completionHandler?(Result.failure(error))
        }
    }

    /// Returns whether the frame was already added.
    @MainActor
    public func addMultiTargetFrame(_ frame: WKFrameInfo, uuid: String) -> Bool {
        var inserted = true
        if multiTargetFrames.keys.contains(uuid) && multiTargetFrames[uuid]?.request.url == frame.request.url {
            inserted = false
        }
        multiTargetFrames[uuid] = frame
        return inserted
    }

    @MainActor
    public func removeAllMultiTargetFrames() {
        multiTargetFrames.removeAll()
    }
}

fileprivate struct LocationChangeUserScript {
    let userScript: WebViewUserScript

    init() {
        let contents = """
(function() {
    var pushState = history.pushState;
    var replaceState = history.replaceState;
    history.pushState = function () {
        pushState.apply(history, arguments);
        window.dispatchEvent(new Event('swiftUIWebViewLocationChanged'));
    };
    history.replaceState = function () {
        replaceState.apply(history, arguments);
        window.dispatchEvent(new Event('swiftUIWebViewLocationChanged'));
    };
    window.addEventListener('popstate', function () {
        window.dispatchEvent(new Event('swiftUIWebViewLocationChanged'))
    });
})();
window.addEventListener('swiftUIWebViewLocationChanged', function () {
    if (window.webkit) {
        window.webkit.messageHandlers.swiftUIWebViewLocationChanged.postMessage(window.location.href);
    }
});
"""
        userScript = WebViewUserScript(source: contents, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}

fileprivate struct ImageChangeUserScript {
    let userScript: WebViewUserScript
    init() {
        let contents = """
var lastURL;
new MutationObserver(function(mutations) {
    let node = document.querySelector('head meta[property="og:image"]')
    if (node && window.webkit) {
        let url = node.getAttribute('content')
        if (lastURL === url) { return }
        window.webkit.messageHandlers.swiftUIWebViewImageUpdated.postMessage({
            imageURL: url, url: window.location.href})
        lastURL = url
    }
}).observe(document, {childList: true, subtree: true, attributes: true, attributeOldValue: false, attributeFilter: ['property', 'content']})
"""
        userScript = WebViewUserScript(source: contents, injectionTime: .atDocumentStart, forMainFrameOnly: true, world: .defaultClient)
    }
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

#if SKIP
public typealias WKWebView = PlatformWebView

public class WKUserContentController {

}

public class WKProcessPool {

}

public class WKNavigation {

}

public class WKNavigationAction {

}

public class WKNavigationActionPolicy {

}

public class WKNavigationResponse {

}

public class WKNavigationResponsePolicy {

}

public class WKSecurityOrigin {

}

public class WKFrameInfo {
    open var isMainFrame: Bool
    open var request: URLRequest
    open var securityOrigin: WKSecurityOrigin
    weak open var webView: WKWebView?

    init(isMainFrame: Bool, request: URLRequest, securityOrigin: WKSecurityOrigin, webView: WKWebView? = nil) {
        self.isMainFrame = isMainFrame
        self.request = request
        self.securityOrigin = securityOrigin
        self.webView = webView
    }
}

public class WKContentWorld {
    static var page: WKContentWorld = WKContentWorld()
    static var defaultClient: WKContentWorld = WKContentWorld()

    static func world(name: String) -> WKContentWorld {
        fatalError("TODO")
    }

    public var name: String?
}

public enum WKUserScriptInjectionTime : Int {
    case atDocumentStart = 0
    case atDocumentEnd = 1
}

open class WKUserScript : NSObject {
    open var source: String
    open var injectionTime: WKUserScriptInjectionTime
    open var isForMainFrameOnly: Bool
    open var contentWorld: WKContentWorld

    public init(source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool, in contentWorld: WKContentWorld) {
        self.source = source
        self.injectionTime = injectionTime
        self.isForMainFrameOnly = forMainFrameOnly
        self.contentWorld = contentWorld
    }
}

public protocol WKURLSchemeHandler {

}

public class WKScriptMessage {

}

public protocol WKScriptMessageHandler {

}

public class WKContentRuleList {
    public var identifier: String

    init(identifier: String) {
        self.identifier = identifier
    }
}

public class WKContentRuleListStore {
}

#endif


#if !SKIP
extension URL {
    public func normalizedHost(stripWWWSubdomainOnly: Bool = false) -> String? {
        // Use components.host instead of self.host since the former correctly preserves
        // brackets for IPv6 hosts, whereas the latter strips them.
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false), var host = components.host, host != "" else {
            return nil
        }

        let textToReplace = stripWWWSubdomainOnly ? "^(www)\\." : "^(www|mobile|m)\\."

        #if !SKIP
        if let range = host.range(of: textToReplace, options: .regularExpression) {
            host.replaceSubrange(range, with: "")
        }
        #endif

        return host
    }

    /// Returns the base domain from a given hostname. The base domain name is defined as the public domain suffix with the base private domain attached to the front. For example, for the URL www.bbc.co.uk, the base domain would be bbc.co.uk. The base domain includes the public suffix (co.uk) + one level down (bbc).
    public var baseDomain: String? {
        //guard !isIPv6, let host = host else { return nil }
        guard let host = host else { return nil }

        // If this is just a hostname and not a FQDN, use the entire hostname.
        if !host.contains(".") {
            return host
        }
        return nil

    }

    public var domainURL: URL {
        if let normalized = self.normalizedHost() {
            // Use URLComponents instead of URL since the former correctly preserves
            // brackets for IPv6 hosts, whereas the latter escapes them.
            var components = URLComponents()
            components.scheme = self.scheme
            #if !SKIP // TODO: This API is not yet available in Skip
            components.port = self.port
            #endif
            components.host = normalized
            return components.url ?? self
        }

        return self
    }
}
#endif

