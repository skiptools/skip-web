// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if !SKIP_BRIDGE
import SwiftUI
import OSLog
import Combine
#if !SKIP
import WebKit
public typealias PlatformWebView = WKWebView
#else
public typealias PlatformWebView = android.webkit.WebView
//import android.webkit.WebView // not imported because it conflicts with SkipWeb.WebView

import androidx.compose.runtime.Composable
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.viewinterop.AndroidView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat.startActivity

import android.webkit.WebViewClient
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.view.ViewGroup

import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewClientCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
#endif

#if SKIP || os(iOS)

/// An embedded WebKit view. It is configured using a `WebEngineConfiguration`
///  and driven with a `WebViewNavigator` which can be associated
///  with user interface controls like back/forward buttons and a URL bar.
public struct WebView : View {
    fileprivate let config: WebEngineConfiguration
    let navigator: WebViewNavigator

    @Binding var state: WebViewState

    var scriptCaller: WebViewScriptCaller? = nil
    let htmlInState: Bool = false
    let schemeHandlers: [(URLSchemeHandler, String)] = []
    let onNavigationCommitted: (() -> Void)?
    let onNavigationFinished: (() -> Void)?
    let onNavigationFailed: (() -> Void)?
    let scrollDelegate: (any SkipWebScrollDelegate)?
    let shouldOverrideUrlLoading: ((_ url: URL) -> Bool)?
    let persistentWebViewID: String? = nil

    private static var engineCache: [String: WebEngine] = [:]

    //let onWarm: (() async -> Void)?
    //@State fileprivate var isWarm = false

    public init(
        configuration: WebEngineConfiguration = WebEngineConfiguration(),
        navigator: WebViewNavigator = WebViewNavigator(),
        url initialURL: URL? = nil,
        html initialHTML: String? = nil,
        state: Binding<WebViewState> = .constant(WebViewState()),
        scrollDelegate: (any SkipWebScrollDelegate)? = nil,
        onNavigationCommitted: (() -> Void)? = nil,
        onNavigationFinished: (() -> Void)? = nil,
        onNavigationFailed: (() -> Void)? = nil,
        shouldOverrideUrlLoading: ((_ url: URL) -> Bool)? = nil
    ) {
        self.config = configuration
        self.navigator = navigator
        if let initialURL = initialURL {
            navigator.initialURL = initialURL
        }
        if let initialHTML = initialHTML {
            navigator.initialHTML = initialHTML
        }
        self._state = state
        self.scrollDelegate = scrollDelegate
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.shouldOverrideUrlLoading = shouldOverrideUrlLoading
    }
}

/// The current state of a web page, including the loading status and the current URL
@available(macOS 14.0, iOS 17.0, *)
@Observable public class WebViewState: @unchecked Sendable {
    public internal(set) var isLoading: Bool = false
    public internal(set) var isProvisionallyNavigating: Bool = false
    /// Preferred URL accessor for parity with `WKWebView.url`.
    /// Using a typed `URL` avoids string parsing at call sites.
    public internal(set) var url: URL?
    /// Deprecated string URL accessor kept for source compatibility.
    /// Prefer `url` to mirror `WKWebView` ergonomics.
    @available(*, deprecated, renamed: "url")
    public internal(set) var pageURL: String? {
        get {
            url?.absoluteString
        }
        set {
            if let newValue {
                url = URL(string: newValue)
            } else {
                url = nil
            }
        }
    }
    public internal(set) var estimatedProgress: Double?
    public internal(set) var pageTitle: String?
    public internal(set) var pageHTML: String?
    public internal(set) var error: Error?
    // SKIP @nobridge
    public internal(set) var themeColor: Color?
    // SKIP @nobridge
    public internal(set) var backgroundColor: Color?
    public internal(set) var canGoBack: Bool = false
    public internal(set) var canGoForward: Bool = false
    public internal(set) var backList: [WebHistoryItem] = []
    public internal(set) var forwardList: [WebHistoryItem] = []
    public internal(set) var scrollingDown: Bool = false

    public init() {
    }

    func updatePageState(webView: PlatformWebView) {
        self.url = webView.currentURL
        self.isLoading = webView.isLoading
        self.estimatedProgress = webView.estimatedProgress
        self.pageTitle = webView.title
        self.canGoBack = webView.canGoBack
        self.canGoForward = webView.canGoForward
        self.backList = webView.backList
        self.forwardList = webView.forwardList
    }
}

/// A controller that can drive a `WebEngine` from a user interface.
public class WebViewNavigator: @unchecked Sendable {
    var initialURL: URL?
    var initialHTML: String?
    #if SKIP
    @MainActor var androidScrollTracker: AndroidScrollTracker?
    #endif

    @MainActor public var webEngine: WebEngine? {
        didSet {
            logger.info("assigned webEngine: \(self.webEngine?.description ?? "NULL")")

            // Allow re-use of an already-warm WebView engine (for example when
            // navigating away and back to the same WebView screen).
            guard oldValue !== self.webEngine else { return }
            guard let webEngine = self.webEngine else { return }
            let hasExistingContent = webEngine.webView.currentURL != nil
                || !webEngine.webView.backList.isEmpty
                || !webEngine.webView.forwardList.isEmpty
            guard !hasExistingContent else { return }

            if let initialURL = initialURL {
                logger.log("loading initialURL: \(initialURL)")
                load(url: initialURL)
            } else if let initialHTML = initialHTML {
                load(html: initialHTML)
            }
        }
    }

    public init(initialURL: URL? = nil, initialHTML: String? = nil) {
        self.initialURL = initialURL
        self.initialHTML = initialHTML
    }

    @MainActor public func load(html: String, baseURL: URL? = nil, mimeType: String = "text/html") {
        // TODO: handle newTab
        webEngine?.loadHTML(html, baseURL: baseURL, mimeType: mimeType)
    }

    @MainActor public func load(url: URL) {
        Task { @MainActor in
            do {
                try await loadOrThrow(url: url)
            } catch {
                logger.error("load URL failed: \(url.absoluteString), error: \(String(describing: error))")
            }
        }
    }

    /// Loads a URL and throws any profile setup/navigation preflight errors.
    @MainActor public func loadOrThrow(url: URL) async throws {
        // TODO: handle newTab
        let urlString = url.absoluteString
        logger.info("load URL=\(urlString) webView: \(self.webEngine?.description ?? "NONE")")
        guard let webEngine else { return }
        try await webEngine.load(url: url)
    }

    @MainActor public func reload() {
        logger.info("reload webView: \(self.webEngine?.description ?? "NONE")")
        webEngine?.reload()
    }

    @MainActor public func stopLoading() {
        logger.info("stopLoading webView: \(self.webEngine?.description ?? "NONE")")
        webEngine?.stopLoading()
    }

    @MainActor public func go(_ item: WebHistoryItem) {
        logger.info("go: \(item.item) webView: \(self.webEngine?.description ?? "NONE")")
        webEngine?.go(to: item)
    }

    @MainActor public func goBack() {
        logger.info("goBack webView: \(self.webEngine?.description ?? "NONE")")
        webEngine?.goBack()
    }

    @MainActor public func goForward() {
        logger.info("goForward webView: \(self.webEngine?.description ?? "NONE")")
        webEngine?.goForward()
    }

    @MainActor public func evaluateJavaScript(_ js: String) async throws -> String? {
        logger.info("evaluateJavaScript: \(js)")
        return try await webEngine?.evaluate(js: js)
    }

    @MainActor public func takeSnapshot(configuration: SkipWebSnapshotConfiguration? = nil) async throws -> SkipWebSnapshot {
        guard let webEngine else {
            throw WebSnapshotError.emptySnapshot
        }
        return try await webEngine.takeSnapshot(configuration: configuration)
    }

    @MainActor public func cookies(for url: URL) async -> [WebCookie] {
        guard let webEngine else {
            return []
        }
        return await webEngine.cookies(for: url)
    }

    @MainActor public func cookieHeader(for url: URL) async -> String? {
        guard let webEngine else {
            return nil
        }
        return await webEngine.cookieHeader(for: url)
    }

    @MainActor public func setCookie(_ cookie: WebCookie, requestURL: URL? = nil) async throws {
        guard let webEngine else {
            return
        }
        try await webEngine.setCookie(cookie, requestURL: requestURL)
    }

    @MainActor public func applySetCookieHeaders(_ headers: [String], for responseURL: URL) async throws {
        guard let webEngine else {
            return
        }
        try await webEngine.applySetCookieHeaders(headers, for: responseURL)
    }

    @MainActor public func clearCookies() async {
        guard let webEngine else {
            return
        }
        await webEngine.clearCookies()
    }

    @MainActor public func removeData(ofTypes types: Set<WebSiteDataType>, modifiedSince: Date) async throws {
        guard let webEngine else {
            return
        }
        try await webEngine.removeData(ofTypes: types, modifiedSince: modifiedSince)
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

#if SKIP

public struct MessageHandlerRouter {
    let webEngine: WebEngine
    // SKIP INSERT: @android.webkit.JavascriptInterface
    public func postMessage(_ name: String, json: String) {
        guard let messageHandler = webEngine.configuration.messageHandlers[name] else {
            logger.error("no messageHandler for \(name)")
            return
        }
        let frameInfo = FrameInfo(isMainFrame: true, request: URLRequest(url: URL(string: "about:blank")!), securityOrigin: SecurityOrigin(), webView: webEngine.webView)
        let body = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!, options: [])
        let message = WebViewMessage(frameInfo: frameInfo, uuid: UUID(), name: name, body: body)
        Task {
            await messageHandler(message)
        }
    }
}

struct WebViewClient : android.webkit.WebViewClient {
    let state: WebViewState
    let onNavigationCommitted: (() -> Void)?
    let onNavigationFinished: (() -> Void)?
    let onNavigationFailed: (() -> Void)?
    let shouldOverrideUrlLoadingHandler: ((_ url: URL) -> Bool)?

    override func onPageFinished(view: PlatformWebView, url: String) {
        state.updatePageState(webView: view)

        if let onNavigationFinished {
            onNavigationFinished()
        }
    }
    
    override func onPageStarted(view: PlatformWebView, url: String, favicon: android.graphics.Bitmap?) {
        state.updatePageState(webView: view)

        if let onNavigationCommitted {
            onNavigationCommitted()
        }
    }
    
    override func onReceivedError(view: PlatformWebView, request: android.webkit.WebResourceRequest, error: android.webkit.WebResourceError) {
        state.updatePageState(webView: view)

        if let onNavigationFailed {
            onNavigationFailed()
        }
    }
    
    override func shouldOverrideUrlLoading(view: PlatformWebView, request: android.webkit.WebResourceRequest) -> Bool {
        guard let url = URL(string: request.url.toString()) else {
            return false
        }
        let result = shouldOverrideUrlLoadingHandler?(url) ?? false
        if result {
            logger.log("Override URL loading for \(url)")
        }
        return result
    }
}

final class SkipWebChromeClient : android.webkit.WebChromeClient {
    let webView: WebView
    let webEngine: WebEngine
    private var childEnginesByWebViewHash: [Int32: WebEngine] = [:]

    init(webView: WebView, webEngine: WebEngine) {
        self.webView = webView
        self.webEngine = webEngine
    }

    private func inheritParentConfiguration(for childEngine: WebEngine) -> Bool {
        let parentConfig = webEngine.configuration
        if let profileError = childEngine.inheritAndroidProfile(from: parentConfig.profile) {
            logger.error("onCreateWindow: failed to inherit parent WebProfile \(String(describing: parentConfig.profile)): \(String(describing: profileError))")
            return false
        }
        let settings = childEngine.webView.settings

        settings.setJavaScriptEnabled(parentConfig.javaScriptEnabled)
        settings.setJavaScriptCanOpenWindowsAutomatically(parentConfig.javaScriptCanOpenWindowsAutomatically)
        settings.setSupportMultipleWindows(parentConfig.uiDelegate != nil)
        settings.setSafeBrowsingEnabled(false)
        settings.setAllowContentAccess(true)
        settings.setAllowFileAccess(true)
        settings.setDomStorageEnabled(true)
        if parentConfig.customUserAgent != nil {
            settings.setUserAgentString(parentConfig.customUserAgent)
        }

        childEngine.webView.setBackgroundColor(0x000000)
        childEngine.webView.addJavascriptInterface(MessageHandlerRouter(webEngine: childEngine), "skipWebAndroidMessageHandler")
        childEngine.setAndroidEmbeddedNavigationClient(WebViewClient(
            state: self.webView.state,
            onNavigationCommitted: self.webView.onNavigationCommitted,
            onNavigationFinished: self.webView.onNavigationFinished,
            onNavigationFailed: self.webView.onNavigationFailed,
            shouldOverrideUrlLoadingHandler: self.webView.shouldOverrideUrlLoading
        ))
        childEngine.webView.webChromeClient = self
        return true
    }

    override func onCreateWindow(view: PlatformWebView, isDialog: Bool, isUserGesture: Bool, resultMsg: android.os.Message) -> Bool {
        let createWindowHandler = webEngine.configuration.androidCreateWindowHandler
        let uiDelegate = webEngine.configuration.uiDelegate
        guard createWindowHandler != nil || uiDelegate != nil else {
            return false
        }

        let sourceURL = URL(string: view.getUrl() ?? "")
        let request = WebWindowRequest(
            sourceURL: sourceURL,
            targetURL: nil,
            isUserGesture: isUserGesture,
            isDialog: isDialog,
            isMainFrame: nil
        )
        let params = AndroidCreateWindowParams(
            isDialog: isDialog,
            isUserGesture: isUserGesture,
            resultMessage: resultMsg
        )

        let childEngine: WebEngine?
        if let createWindowHandler {
            childEngine = createWindowHandler(webView, request, params)
        } else {
            childEngine = uiDelegate?.webView(
                webView,
                createWebViewWith: request,
                platformContext: params
            )
        }
        guard let childEngine else {
            return false
        }

        guard inheritParentConfiguration(for: childEngine) else {
            return false
        }

        guard let transport = resultMsg.obj as? android.webkit.WebView.WebViewTransport else {
            logger.error("onCreateWindow: invalid WebViewTransport message payload")
            return false
        }

        transport.setWebView(childEngine.webView)
        resultMsg.sendToTarget()
        childEnginesByWebViewHash[childEngine.webView.hashCode()] = childEngine
        return true
    }

    override func onCloseWindow(window: PlatformWebView) {
        defer {
            super.onCloseWindow(window)
        }
        guard let childEngine = childEnginesByWebViewHash.removeValue(forKey: window.hashCode()) else {
            return
        }
        if let closeWindowHandler = webEngine.configuration.androidCloseWindowHandler {
            closeWindowHandler(self.webView, childEngine)
        } else {
            webEngine.configuration.uiDelegate?.webViewDidClose(self.webView, child: childEngine)
        }
    }
}

#endif

@available(macOS 14.0, iOS 17.0, *)
extension WebView : ViewRepresentable {
    public typealias Coordinator = WebViewCoordinator

    public func makeCoordinator() -> Coordinator {
        WebViewCoordinator(webView: self, navigator: navigator, scriptCaller: scriptCaller, config: config)
    }

    @MainActor private func setupWebView(_ webEngine: WebEngine, coordinator: WebViewCoordinator? = nil) -> WebEngine {
        // configure JavaScript
        #if SKIP
        let settings = webEngine.webView.settings
        settings.setJavaScriptEnabled(config.javaScriptEnabled)
        settings.setJavaScriptCanOpenWindowsAutomatically(config.javaScriptCanOpenWindowsAutomatically)
        settings.setSupportMultipleWindows(
            config.uiDelegate != nil || config.androidCreateWindowHandler != nil
        )
        settings.setSafeBrowsingEnabled(false)
        settings.setAllowContentAccess(true)
        settings.setAllowFileAccess(true)
        settings.setDomStorageEnabled(true)
        if (config.customUserAgent != nil ) {
            settings.setUserAgentString(config.customUserAgent)
        }
        webEngine.webView.setBackgroundColor(0x000000) // prevents screen flashing: https://issuetracker.google.com/issues/314821744
        webEngine.webView.addJavascriptInterface(MessageHandlerRouter(webEngine: webEngine), "skipWebAndroidMessageHandler")
        webEngine.setAndroidEmbeddedNavigationClient(WebViewClient(
            state: state,
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            shouldOverrideUrlLoadingHandler: shouldOverrideUrlLoading
        ))
        if config.uiDelegate != nil || config.androidCreateWindowHandler != nil {
            webEngine.webView.webChromeClient = SkipWebChromeClient(webView: self, webEngine: webEngine)
        } else {
            webEngine.webView.webChromeClient = android.webkit.WebChromeClient()
        }
        coordinator?.configureAndroidScrollTracking(webView: webEngine.webView)

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
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = config.javaScriptCanOpenWindowsAutomatically
        preferences.preferredContentMode = .recommended
        // preferences.isLockdownModeEnabled = false // The 'com.apple.developer.web-browser' restricted entitlement is required to disable lockdown mode

        webEngine.refreshMessageHandlers()
        webEngine.updateUserScripts()
        
        if (config.customUserAgent != "" ) {
            webEngine.webView.customUserAgent = config.customUserAgent
        }
        #endif

        if navigator.webEngine !== webEngine {
            // Rebind only when needed so we do not re-trigger initial content loading.
            navigator.webEngine = webEngine
        }

        return webEngine
    }

    public func update(webView: PlatformWebView, coordinator: WebViewCoordinator? = nil) {
        coordinator?.update(from: self)
        #if !SKIP
        webView.scrollView.isScrollEnabled = config.isScrollEnabled
        #endif
        //logger.info("WebView.update: \(webView)")
    }

    #if SKIP

    // Without `remember` recompositions recreate WebViewCoordinator, which resets scroll-tracking state and can swap scrollViewProxy identity mid-session
    @Composable
    private func rememberedCoordinator() -> WebViewCoordinator {
        // SKIP INSERT: return androidx.compose.runtime.remember { makeCoordinator() }
        return makeCoordinator()
    }

    public var body: some View {
        ComposeView { ctx in
            let coordinator = rememberedCoordinator()
            AndroidView(factory: { ctx in
                config.context = ctx
                // Re-use the navigator-owned engine so Android WebView survives
                // screen navigation with the same navigator instance.
                let webEngine = navigator.webEngine ?? WebEngine(configuration: config)
                let view = setupWebView(webEngine, coordinator: coordinator).webView
                // AndroidView does not reliably push the parent's fill constraints into the
                // embedded WebView on the first layout pass, so we request fill sizing from both
                // Compose and the native view to avoid a zero-height viewport.
                view.layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
                view.minimumHeight = 1
                return view
            }, modifier: ctx.modifier.fillMaxSize(), update: { webView in
                webView.layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
                coordinator.update(from: self)
                coordinator.configureAndroidScrollTracking(webView: webView)
                self.update(webView: webView, coordinator: coordinator)
            })
        }
    }
    #else
    @MainActor private func makeWebEngine(id: String?, config: WebEngineConfiguration, coordinator: WebViewCoordinator) -> WebEngine {
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
            web = setupWebView(engine, coordinator: coordinator)
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

        return web
    }

    @MainActor private func create(from context: Context) -> WebEngine {
        let webEngine = makeWebEngine(id: persistentWebViewID, config: config, coordinator: context.coordinator)
        context.coordinator.navigator.webEngine = webEngine

        let webView = webEngine.webView
        Task { @MainActor in
            if let error = await webEngine.awaitContentBlockerSetup().first {
                context.coordinator.state.error = error
            }
        }

        webView.allowsLinkPreview = true
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures

        #if os(iOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        //webView.scrollView.contentInsetAdjustmentBehavior = .scrollableAxes
        webView.scrollView.isScrollEnabled = config.isScrollEnabled
        webView.pageZoom = config.pageZoom
        webView.isOpaque = config.isOpaque
        webView.isInspectable = true
        webView.isFindInteractionEnabled = true

        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true

        if config.allowsPullToRefresh == true {
            // add a pull-to-refresh control to the page

            webView.scrollView.refreshControl = UIRefreshControl()
            webView.scrollView.refreshControl?.addTarget(context.coordinator, action: #selector(Coordinator.handleRefreshControl), for: .valueChanged)
        }

        webView.publisher(for: \.title)
            .receive(on: DispatchQueue.main)
            .sink { title in
                if let title = title, !title.isEmpty {
                    context.coordinator.state.pageTitle = title
                }
            }
            .store(in: &context.coordinator.subscriptions)

        webView.publisher(for: \.url)
            .receive(on: DispatchQueue.main)
            .sink { url in
                context.coordinator.state.url = url
            }
            .store(in: &context.coordinator.subscriptions)

        webView.publisher(for: \.estimatedProgress)
            .receive(on: DispatchQueue.main)
            .sink { progress in
                withAnimation(progress == 0.0 ? .none : .interpolatingSpring) {
                    context.coordinator.state.estimatedProgress = progress
                }
            }
            .store(in: &context.coordinator.subscriptions)

        webView.publisher(for: \.themeColor)
            .receive(on: DispatchQueue.main)
            .sink { themeColor in
                context.coordinator.state.themeColor = themeColor.flatMap(Color.init(uiColor:))
            }
            .store(in: &context.coordinator.subscriptions)

        webView.publisher(for: \.underPageBackgroundColor)
            .receive(on: DispatchQueue.main)
            .sink { backgroundColor in
                context.coordinator.state.backgroundColor = backgroundColor.flatMap(Color.init(uiColor:))
            }
            .store(in: &context.coordinator.subscriptions)

        webView.publisher(for: \.canGoBack)
            .receive(on: DispatchQueue.main)
            .sink { canGoBack in
                context.coordinator.state.canGoBack = canGoBack
            }
            .store(in: &context.coordinator.subscriptions)

        webView.publisher(for: \.canGoForward)
            .receive(on: DispatchQueue.main)
            .sink { canGoForward in
                context.coordinator.state.canGoForward = canGoForward
            }
            .store(in: &context.coordinator.subscriptions)

        #endif

        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
            context.coordinator.scriptCaller = scriptCaller
        }
        context.coordinator.scriptCaller?.caller = {
            webView.evaluateJavaScript($0, completionHandler: $1)
        }

        context.coordinator.scriptCaller?.asyncCaller = { js, args, frame, world in
            // work-around for iOS<18.4 crash: https://github.com/skiptools/skip-web/issues/8
            return try await webView.evaluateJavaScript(js)

            #if false
            let world = world ?? .defaultClient
            if let args = args {
                return try await webView.callAsyncJavaScript(js, arguments: args, in: frame, contentWorld: world)
            } else {
                return try await webView.callAsyncJavaScript(js, in: frame, contentWorld: world)
            }
            #endif
        }

        // In case we retrieved a cached web view that is already warm but we don't know it.
        //webView.evaluateJavaScript("window.webkit.messageHandlers.swiftUIWebViewIsWarm.postMessage({})")

        //return WebViewController(webView: webView, persistentWebViewID: persistentWebViewID)

        return webEngine
    }

    #if canImport(UIKit)
    public func makeUIView(context: Context) -> WKWebView { create(from: context).webView }
    public func updateUIView(_ uiView: WKWebView, context: Context) { update(webView: uiView, coordinator: context.coordinator) }
    #elseif canImport(AppKit)
    public func makeNSView(context: Context) -> WKWebView { create(from: context).webView }
    public func updateNSView(_ nsView: WKWebView, context: Context) { update(webView: nsView, coordinator: context.coordinator) }
    #endif
    #endif
}

@available(macOS 14.0, iOS 17.0, *)
@MainActor public class WebViewCoordinator: WebObjectBase {
    private var webView: WebView

    var navigator: WebViewNavigator
    var scriptCaller: WebViewScriptCaller?
    var config: WebEngineConfiguration
    let scrollViewProxy: WebScrollViewProxy
    var lastScrollOffset: CGPoint = .zero
    
    var compiledContentRules = [String: ContentRuleList]()

    #if !SKIP
    var subscriptions: Set<AnyCancellable> = []
    var childEnginesByWebViewID: [ObjectIdentifier: WebEngine] = [:]
    #else
    var androidScrollTracker: AndroidScrollTracker?
    #endif

    var state: WebViewState {
        get { webView.state }
        set { webView.state = newValue }
    }

    var messageHandlerNames: [String] {
        config.messageHandlers.keys.map { $0 }
    }

    init(webView: WebView, navigator: WebViewNavigator, scriptCaller: WebViewScriptCaller? = nil, config: WebEngineConfiguration) {
        self.webView = webView
        self.navigator = navigator
        self.scriptCaller = scriptCaller
        self.config = config
        self.scrollViewProxy = WebScrollViewProxy(isScrollEnabled: config.isScrollEnabled)
        #if SKIP
        self.androidScrollTracker = nil
        #endif

        // TODO: Make about:blank history initialization optional via configuration.
//        #warning("confirm this still works")
//        if  webView.state.backList.isEmpty && webView.state.forwardList.isEmpty && webView.state.url?.absoluteString == "about:blank" {
//            Task { @MainActor in
//                webView.action = .load(URLRequest(url: URL(string: "about:blank")!))
//            }
//        }
    }

    func update(from webView: WebView) {
        self.webView = webView
        self.navigator = webView.navigator
        if let scriptCaller = webView.scriptCaller {
            self.scriptCaller = scriptCaller
        }
        self.config = webView.config
        let snapshot = proxySnapshot()
        updateScrollProxy(
            contentOffset: snapshot.contentOffset,
            contentSize: snapshot.contentSize,
            visibleSize: snapshot.visibleSize,
            isTracking: scrollViewProxy.isTracking,
            isDragging: scrollViewProxy.isDragging,
            isDecelerating: scrollViewProxy.isDecelerating
        )
    }

    @discardableResult func openURL(url: URL, newTab: Bool) -> PlatformWebView? {
        // TODO: handle newTab
        navigator.load(url: url)
        return nil // TODO: return new PlatformWebView
    }

    #if canImport(UIKit)
    @objc func handleRefreshControl(sender: UIRefreshControl) {
        sender.endRefreshing()
        logger.log("refreshing")
        DispatchQueue.main.async {
            self.webView.navigator.reload()
        }
    }
    #endif

    var publicScrollDelegate: (any SkipWebScrollDelegate)? {
        webView.scrollDelegate
    }

    func proxySnapshot() -> (contentOffset: CGPoint, contentSize: CGSize, visibleSize: CGSize) {
        (
            contentOffset: CGPoint(x: scrollViewProxy.contentOffset.x, y: scrollViewProxy.contentOffset.y),
            contentSize: CGSize(width: scrollViewProxy.contentSize.width, height: scrollViewProxy.contentSize.height),
            visibleSize: CGSize(width: scrollViewProxy.visibleSize.width, height: scrollViewProxy.visibleSize.height)
        )
    }

    func updateScrollProxy(contentOffset: CGPoint,
                           contentSize: CGSize,
                           visibleSize: CGSize,
                           isTracking: Bool,
                           isDragging: Bool,
                           isDecelerating: Bool) {
        scrollViewProxy.update(
            contentOffset: WebScrollPoint(x: Double(contentOffset.x), y: Double(contentOffset.y)),
            contentSize: WebScrollSize(width: Double(contentSize.width), height: Double(contentSize.height)),
            visibleSize: WebScrollSize(width: Double(visibleSize.width), height: Double(visibleSize.height)),
            isTracking: isTracking,
            isDragging: isDragging,
            isDecelerating: isDecelerating,
            isScrollEnabled: config.isScrollEnabled
        )
    }

    func updateScrollingDown(contentOffset: CGPoint,
                             contentSize: CGSize,
                             visibleSize: CGSize,
                             isTracking: Bool) {
        // Preserve the existing toolbar-direction semantics: only user tracking
        // updates the state, and inertial scrolling is ignored.
        if state.isLoading || !isTracking {
            return
        }

        defer { lastScrollOffset = contentOffset }

        let offsetY = contentOffset.y
        let isScrollingDown = ((offsetY + visibleSize.height) >= contentSize.height)
            || (offsetY > 0 && offsetY > lastScrollOffset.y)

        if state.scrollingDown != isScrollingDown {
            state.scrollingDown = isScrollingDown
        }
    }

    #if SKIP
    func configureAndroidScrollTracking(webView: PlatformWebView) {
        if let existingTracker = navigator.androidScrollTracker {
            existingTracker.updateCoordinator(self)
            existingTracker.attach(to: webView)
            androidScrollTracker = existingTracker
            return
        }

        let tracker = AndroidScrollTracker(coordinator: self)
        tracker.attach(to: webView)
        navigator.androidScrollTracker = tracker
        androidScrollTracker = tracker
    }
    #endif
}

#if SKIP
@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class AndroidScrollTracker {
    private weak var coordinator: WebViewCoordinator?
    private weak var attachedWebView: PlatformWebView?
    private var touchOrigin: CGPoint?
    private var velocityTracker: android.view.VelocityTracker?
    private var isTrackingTouch = false
    private var isDragging = false
    private var didBeginDragging = false
    private var isDecelerating = false
    private var touchCancelGeneration: Int = 0
    private var decelerationGeneration: Int = 0
    private let touchCancelGracePeriodNanoseconds: Int = 120_000_000
    private let decelerationQuietPeriodNanoseconds: Int = 120_000_000

    private var currentContentOffset: CGPoint {
        coordinator?.proxySnapshot().contentOffset ?? .zero
    }

    private var currentContentSize: CGSize {
        coordinator?.proxySnapshot().contentSize ?? .zero
    }

    private var currentVisibleSize: CGSize {
        coordinator?.proxySnapshot().visibleSize ?? .zero
    }

    init(coordinator: WebViewCoordinator) {
        self.coordinator = coordinator
    }

    func updateCoordinator(_ coordinator: WebViewCoordinator) {
        self.coordinator = coordinator
    }

    func attach(to webView: PlatformWebView) {
        attachedWebView = webView
        webView.setOnScrollChangeListener { [weak self, weak webView] _, scrollX, scrollY, oldScrollX, oldScrollY in
            guard let self, let webView else {
                return
            }
            let snapshot = self.snapshot(from: webView)
            self.handleScrollChanged(
                scrollX: scrollX,
                scrollY: scrollY,
                oldScrollX: oldScrollX,
                oldScrollY: oldScrollY,
                visibleSize: snapshot.visibleSize,
                contentSize: snapshot.contentSize
            )
        }
        webView.setOnTouchListener { [weak self, weak webView] _, motionEvent in
            guard let self, let webView else {
                return false
            }
            guard let motionEvent else {
                return false
            }
            self.handleMotionEvent(motionEvent, on: webView)
            return false
        }
    }

    static func scaledContentSize(visibleSize: CGSize,
                                  contentWidth: Double,
                                  contentHeight: Double,
                                  scale: Double) -> CGSize {
        CGSize(
            width: max(visibleSize.width, contentWidth * scale),
            height: max(visibleSize.height, contentHeight * scale)
        )
    }

    private func snapshot(from webView: PlatformWebView) -> (contentOffset: CGPoint, contentSize: CGSize, visibleSize: CGSize) {
        let visibleSize = CGSize(width: Double(webView.getWidth()), height: Double(webView.getHeight()))
        let scale = max(Double(webView.getScale()), 1.0)
        return (
            contentOffset: CGPoint(x: Double(webView.getScrollX()), y: Double(webView.getScrollY())),
            contentSize: Self.scaledContentSize(
                visibleSize: visibleSize,
                contentWidth: visibleSize.width / scale,
                contentHeight: Double(webView.getContentHeight()),
                scale: scale
            ),
            visibleSize: visibleSize
        )
    }

    func handleMotionEvent(_ motionEvent: android.view.MotionEvent, on webView: PlatformWebView) {
        switch motionEvent.actionMasked {
        case android.view.MotionEvent.ACTION_DOWN:
            touchCancelGeneration += 1
            resetVelocityTracker()
            velocityTracker = android.view.VelocityTracker.obtain()
            velocityTracker?.addMovement(motionEvent)
            handleTouchDown(at: CGPoint(x: Double(motionEvent.x), y: Double(motionEvent.y)), webView: webView)
        case android.view.MotionEvent.ACTION_MOVE:
            touchCancelGeneration += 1
            velocityTracker?.addMovement(motionEvent)
            handleTouchMove(to: CGPoint(x: Double(motionEvent.x), y: Double(motionEvent.y)), webView: webView)
        case android.view.MotionEvent.ACTION_UP:
            touchCancelGeneration += 1
            velocityTracker?.addMovement(motionEvent)
            velocityTracker?.computeCurrentVelocity(1000)
            let velocity = CGPoint(
                x: Double(velocityTracker?.xVelocity ?? 0.0),
                y: Double(velocityTracker?.yVelocity ?? 0.0)
            )
            handleTouchEnd(velocity: velocity)
            resetVelocityTracker()
        case android.view.MotionEvent.ACTION_CANCEL:
            scheduleTouchCancelFinalization()
        default:
            break
        }
    }

    func handleTouchDown(at point: CGPoint, webView: PlatformWebView) {
        isTrackingTouch = true
        if isDecelerating {
            finishDeceleration()
        }
        touchOrigin = point
        isDragging = false
        didBeginDragging = false
        // Keep the touch stream owned by WebView so ACTION_UP/CANCEL remains reliable.
        webView.getParent()?.requestDisallowInterceptTouchEvent(true)
        guard let coordinator else {
            return
        }
        let snapshot = snapshot(from: webView)
        coordinator.updateScrollProxy(
            contentOffset: snapshot.contentOffset,
            contentSize: snapshot.contentSize,
            visibleSize: snapshot.visibleSize,
            isTracking: true,
            isDragging: false,
            isDecelerating: isDecelerating
        )
    }

    func handleTouchMove(to point: CGPoint, webView: PlatformWebView) {
        guard let coordinator else {
            return
        }
        guard let touchOrigin else {
            return
        }
        guard !isDragging else {
            return
        }
        let touchSlop = Double(android.view.ViewConfiguration.get(webView.getContext()).scaledTouchSlop)
        let deltaX = abs(point.x - touchOrigin.x)
        let deltaY = abs(point.y - touchOrigin.y)
        guard max(deltaX, deltaY) > touchSlop else {
            return
        }
        isDragging = true
        didBeginDragging = true
        webView.getParent()?.requestDisallowInterceptTouchEvent(true)
        let snapshot = snapshot(from: webView)
        coordinator.updateScrollProxy(
            contentOffset: snapshot.contentOffset,
            contentSize: snapshot.contentSize,
            visibleSize: snapshot.visibleSize,
            isTracking: isTrackingTouch,
            isDragging: true,
            isDecelerating: false
        )
        coordinator.publicScrollDelegate?.scrollViewWillBeginDragging(coordinator.scrollViewProxy)
    }

    func handleTouchEnd(velocity: CGPoint) {
        touchCancelGeneration += 1
        guard let coordinator else {
            isTrackingTouch = false
            touchOrigin = nil
            isDragging = false
            didBeginDragging = false
            return
        }
        let snapshot = attachedWebView.map(snapshot(from:)) ?? (
            contentOffset: currentContentOffset,
            contentSize: currentContentSize,
            visibleSize: currentVisibleSize
        )
        let wasDragging = didBeginDragging
        defer {
            attachedWebView?.getParent()?.requestDisallowInterceptTouchEvent(false)
            isTrackingTouch = false
            touchOrigin = nil
            isDragging = false
            didBeginDragging = false
        }
        guard wasDragging else {
            coordinator.updateScrollProxy(
                contentOffset: snapshot.contentOffset,
                contentSize: snapshot.contentSize,
                visibleSize: snapshot.visibleSize,
                isTracking: false,
                isDragging: false,
                isDecelerating: isDecelerating
            )
            return
        }

        let minimumFlingVelocity = Double(
            android.view.ViewConfiguration.get(
                attachedWebView?.getContext() ?? coordinator.config.context ?? ProcessInfo.processInfo.androidContext
            ).scaledMinimumFlingVelocity
        )
        let speed = max(abs(velocity.x), abs(velocity.y))
        let willDecelerate = speed >= minimumFlingVelocity

        coordinator.updateScrollProxy(
            contentOffset: snapshot.contentOffset,
            contentSize: snapshot.contentSize,
            visibleSize: snapshot.visibleSize,
            isTracking: false,
            isDragging: false,
            isDecelerating: willDecelerate
        )
        coordinator.publicScrollDelegate?.scrollViewDidEndDragging(coordinator.scrollViewProxy, willDecelerate: willDecelerate)

        if willDecelerate {
            isDecelerating = true
            coordinator.updateScrollProxy(
                contentOffset: snapshot.contentOffset,
                contentSize: snapshot.contentSize,
                visibleSize: snapshot.visibleSize,
                isTracking: false,
                isDragging: false,
                isDecelerating: true
            )
            coordinator.publicScrollDelegate?.scrollViewWillBeginDecelerating(coordinator.scrollViewProxy)
            scheduleDecelerationIdleCheck()
        } else {
            isDecelerating = false
            decelerationGeneration += 1
        }
    }

    private func scheduleTouchCancelFinalization() {
        guard isTrackingTouch || isDragging || didBeginDragging else {
            return
        }
        touchCancelGeneration += 1
        let generation = touchCancelGeneration
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(self.touchCancelGracePeriodNanoseconds))
            guard self.touchCancelGeneration == generation else {
                return
            }
            self.handleTouchEnd(velocity: .zero)
            self.resetVelocityTracker()
        }
    }

    func handleScrollChanged(scrollX: Int,
                             scrollY: Int,
                             oldScrollX: Int,
                             oldScrollY: Int,
                             visibleSize: CGSize,
                             contentSize: CGSize) {
        guard let coordinator else {
            return
        }
        let didMove = (scrollX != oldScrollX) || (scrollY != oldScrollY)

        // Some Android WebView builds do not deliver reliable ACTION_MOVE while
        // dragging. When touch is active and scroll delta appears, synthesize
        // drag-begin directly from scroll movement.
        if isTrackingTouch, !isDragging, didMove {
            isDragging = true
            didBeginDragging = true
            let contentOffset = CGPoint(x: Double(scrollX), y: Double(scrollY))
            coordinator.updateScrollProxy(
                contentOffset: contentOffset,
                contentSize: contentSize,
                visibleSize: visibleSize,
                isTracking: true,
                isDragging: true,
                isDecelerating: false
            )
            coordinator.publicScrollDelegate?.scrollViewWillBeginDragging(coordinator.scrollViewProxy)
        }

        let contentOffset = CGPoint(x: Double(scrollX), y: Double(scrollY))
        coordinator.updateScrollProxy(
            contentOffset: contentOffset,
            contentSize: contentSize,
            visibleSize: visibleSize,
            isTracking: isTrackingTouch,
            isDragging: isDragging,
            isDecelerating: isDecelerating
        )
        coordinator.publicScrollDelegate?.scrollViewDidScroll(coordinator.scrollViewProxy)
        coordinator.updateScrollingDown(
            contentOffset: contentOffset,
            contentSize: contentSize,
            visibleSize: visibleSize,
            isTracking: isTrackingTouch
        )

        if isDecelerating, didMove {
            scheduleDecelerationIdleCheck()
        }
    }

    private func scheduleDecelerationIdleCheck() {
        decelerationGeneration += 1
        let generation = decelerationGeneration
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(self.decelerationQuietPeriodNanoseconds))
            guard self.isDecelerating, self.decelerationGeneration == generation else {
                return
            }
            self.finishDeceleration()
        }
    }

    private func finishDeceleration() {
        guard let coordinator else {
            return
        }
        guard isDecelerating else {
            return
        }
        isDecelerating = false
        decelerationGeneration += 1
        let snapshot = attachedWebView.map(snapshot(from:)) ?? (
            contentOffset: currentContentOffset,
            contentSize: currentContentSize,
            visibleSize: currentVisibleSize
        )
        coordinator.updateScrollProxy(
            contentOffset: snapshot.contentOffset,
            contentSize: snapshot.contentSize,
            visibleSize: snapshot.visibleSize,
            isTracking: false,
            isDragging: false,
            isDecelerating: false
        )
        coordinator.publicScrollDelegate?.scrollViewDidEndDecelerating(coordinator.scrollViewProxy)
    }

    private func resetVelocityTracker() {
        velocityTracker?.recycle()
        velocityTracker = nil
    }
}
#endif

// Adaptations from android.webkit.WebView to WKWebView
extension PlatformWebView {
    var currentURL: URL? {
        #if !SKIP
        return url
        #else
        guard let raw = getUrl() else {
            return nil
        }
        return URL(string: raw)
        #endif
    }

    var backList: [WebHistoryItem] {
        #if !SKIP
        return backForwardList.backList.map { WebHistoryItem(item: $0) }
        #else
        let bfl = copyBackForwardList()
        if bfl.currentIndex == 0 { return [] }
        return (0..<bfl.currentIndex).map { WebHistoryItem(item: bfl.getItemAtIndex($0)) }
        #endif
    }

    var forwardList: [WebHistoryItem] {
        #if !SKIP
        return backForwardList.forwardList.map { WebHistoryItem(item: $0) }
        #else
        let bfl = copyBackForwardList()
        if bfl.currentIndex >= (bfl.size - 1) { return [] }
        return (bfl.currentIndex+1..<bfl.size).map { WebHistoryItem(item: bfl.getItemAtIndex($0)) }
        #endif
    }

    #if SKIP
    var canGoBack: Bool {
        canGoBack()
    }

    var canGoForward: Bool {
        canGoForward()
    }

    var isLoading: Bool {
        getProgress() < 100
    }

    var estimatedProgress: Double {
        // getProgress(): the progress for the current page between 0 and 100
        Double(getProgress()) / 100.0
    }
    #endif
}

#if !SKIP
@available(macOS 14.0, iOS 17.0, *)
extension WebViewCoordinator: WebUIDelegate {

    @MainActor public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        logger.log("createWebViewWith: \(configuration) \(navigationAction)")
        let request = WebWindowRequest(
            sourceURL: self.navigator.webEngine?.webView.url,
            targetURL: navigationAction.request.url,
            isUserGesture: nil,
            isDialog: nil,
            isMainFrame: navigationAction.targetFrame?.isMainFrame
        )
        let params = WebKitCreateWindowParams(
            configuration: configuration,
            navigationAction: navigationAction,
            windowFeatures: windowFeatures,
            parentConfigurationSnapshot: config.popupChildMirroredConfiguration(),
            parentIsInspectable: webView.isInspectable
        )
        guard let childEngine = config.uiDelegate?.webView(
            self.webView,
            createWebViewWith: request,
            platformContext: params
        ) else {
            return nil
        }

        // WebKit requires the returned child WKWebView to be initialized with the
        // exact `configuration` received in this callback. If that contract is
        // violated, WebKit can raise NSInternalInconsistencyException:
        // "Returned WKWebView was not created with the given configuration."
        switch PopupConfigRegistry.verifyAndConsume(
            childWebViewID: ObjectIdentifier(childEngine.webView),
            expectedConfigID: ObjectIdentifier(configuration)
        ) {
        case .matched:
            break
        case .mismatch:
            logger.error("SkipWeb popup contract violation: child WKWebView was not initialized with the WKWebViewConfiguration provided by WKUIDelegate createWebViewWith. This can trigger NSInternalInconsistencyException: 'Returned WKWebView was not created with the given configuration.' Popup creation will continue.")
        case .missingRegistration:
            if PopupConfigRegistry.shouldLogMissingRegistrationWarning() {
                logger.warning("SkipWeb popup contract could not be verified because no popup construction record was found. Return a child created by platformContext.makeChildWebEngine(...) from your createWebViewWith delegate. Violating this WebKit contract can trigger NSInternalInconsistencyException: 'Returned WKWebView was not created with the given configuration.'")
            }
        }

        childEnginesByWebViewID[ObjectIdentifier(childEngine.webView)] = childEngine
        return childEngine.webView
    }

    @MainActor public func webViewDidClose(_ webView: WKWebView) {
        guard let childEngine = childEnginesByWebViewID.removeValue(forKey: ObjectIdentifier(webView)) else {
            return
        }
        config.uiDelegate?.webViewDidClose(self.webView, child: childEngine)
    }

    @MainActor public func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }

        logger.log("webView contextMenuConfigurationFor: \(url)")

        let menu = UIMenu(title: "", children: [
            UIAction(title: NSLocalizedString("Open", bundle: .module, comment: "context menu action name for opening a url"), image: UIImage(systemName: "plus.square")) { _ in
                self.navigator.load(url: url)
                self.openURL(url: url, newTab: false)
            },
            UIAction(title: NSLocalizedString("Open in New Tab", bundle: .module, comment: "context menu action name for opening a url in a new tab"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                self.openURL(url: url, newTab: true)
            },
            UIAction(title: NSLocalizedString("Open in Default Browser", bundle: .module, comment: "context menu action name for opening a url in the system browser"), image: UIImage(systemName: "safari")) { _ in
                UIApplication.shared.open(url)
            },
            UIAction(title: NSLocalizedString("Copy Link", bundle: .module, comment: "context menu action name for copying a URL link"), image: UIImage(systemName: "paperclip.badge.ellipsis")) { _ in
                UIPasteboard.general.url = url
            },
            // randomly doesn't show up … probably need a handle to the actual UIViewController
//            UIAction(title: NSLocalizedString("Share…", bundle: .module, comment: "context menu action name for sharing a URL"), image: UIImage(systemName: "square.and.arrow.up")) { _ in
//                let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
//                let controller = webView.findViewController()
//                logger.info("opening share sheet for \(url) in: \(controller)")
//                controller?.present(activity, animated: true)
//            },
        ])
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            return menu
        }

        completionHandler(configuration)
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension WebViewCoordinator: WebNavigationDelegate {
    @MainActor
    public func webView(_ webView: PlatformWebView, didFinish navigation: WebNavigation!) {
        logger.log("webView \(webView) didFinish navigation \(webView.url?.absoluteString ?? "nil")")
        
        let state = self.webView.state
        state.isLoading = false
        state.url = webView.url
        state.isProvisionallyNavigating = false

        state.updatePageState(webView: webView)

        if let onNavigationFinished = self.webView.onNavigationFinished {
            onNavigationFinished()
        }
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, didFailProvisionalNavigation navigation: WebNavigation!, withError error: Error) {
        logger.log("webView(\(webView)) didFailProvisionalNavigation: \(navigation), withError: \(error)")
        scriptCaller?.removeAllMultiTargetFrames()
        self.webView.state.isLoading = false
        self.webView.state.isProvisionallyNavigating = false
        self.webView.state.error = error
        if let onNavigationFailed = self.webView.onNavigationFailed {
            onNavigationFailed()
        }
    }

    @MainActor
    public func webViewWebContentProcessDidTerminate(_ webView: PlatformWebView) {
        logger.log("webViewWebContentProcessDidTerminate: \(webView)")
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, didFail navigation: WebNavigation!, withError error: Error) {
        logger.log("webView(\(webView)) didFail navigation: \(navigation), withError: \(error)")
        scriptCaller?.removeAllMultiTargetFrames()
        self.webView.state.isLoading = false
        self.webView.state.isProvisionallyNavigating = false
        self.webView.state.error = error

        state.updatePageState(webView: webView)
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, didCommit navigation: WebNavigation!) {
        scriptCaller?.removeAllMultiTargetFrames()
        self.webView.state.isLoading = true
        self.webView.state.isProvisionallyNavigating = false
        state.updatePageState(webView: webView)
        if let onNavigationCommitted = self.webView.onNavigationCommitted {
            onNavigationCommitted()
        }
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, didStartProvisionalNavigation navigation: WebNavigation!) {
        state.updatePageState(webView: webView)
        self.webView.state.estimatedProgress = 0.0
        self.webView.state.isProvisionallyNavigating = true
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, decidePolicyFor navigationAction: WebNavigationAction, preferences: WebpagePreferences) async -> (NavigationActionPolicy, WebpagePreferences) {
        guard let url = navigationAction.request.url else {
            return (.allow, preferences)
        }
        
        if (self.webView.shouldOverrideUrlLoading?(url) ?? false) {
            logger.log("Override URL loading for \(url)")
            self.webView.state.isProvisionallyNavigating = false
            self.webView.state.isLoading = false
            return (.cancel, preferences)
        }

        return (.allow, preferences)
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, decidePolicyFor navigationResponse: NavigationResponse) async -> NavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let url = navigationResponse.response.url, self.webView.state.url != url {
            scriptCaller?.removeAllMultiTargetFrames()
            let newState = self.webView.state
            newState.url = url
            newState.pageHTML = nil
            newState.error = nil
            self.webView.state = newState
        }

        return .allow
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        // TODO: handle download delegate
        //download.delegate = downloadDelegate // track progress, cancellation, and file destination
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension WebViewCoordinator: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollProxy(
            contentOffset: scrollView.contentOffset,
            contentSize: scrollView.contentSize,
            visibleSize: scrollView.bounds.size,
            isTracking: scrollView.isTracking,
            isDragging: scrollView.isDragging,
            isDecelerating: scrollView.isDecelerating
        )
        publicScrollDelegate?.scrollViewDidScroll(scrollViewProxy)
        updateScrollingDown(
            contentOffset: scrollView.contentOffset,
            contentSize: scrollView.contentSize,
            visibleSize: scrollView.bounds.size,
            isTracking: scrollView.isTracking
        )
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        updateScrollProxy(
            contentOffset: scrollView.contentOffset,
            contentSize: scrollView.contentSize,
            visibleSize: scrollView.bounds.size,
            isTracking: scrollView.isTracking,
            isDragging: true,
            isDecelerating: scrollView.isDecelerating
        )
        publicScrollDelegate?.scrollViewWillBeginDragging(scrollViewProxy)
    }

    public func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        updateScrollProxy(
            contentOffset: scrollView.contentOffset,
            contentSize: scrollView.contentSize,
            visibleSize: scrollView.bounds.size,
            isTracking: scrollView.isTracking,
            isDragging: scrollView.isDragging,
            isDecelerating: true
        )
        publicScrollDelegate?.scrollViewWillBeginDecelerating(scrollViewProxy)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        updateScrollProxy(
            contentOffset: scrollView.contentOffset,
            contentSize: scrollView.contentSize,
            visibleSize: scrollView.bounds.size,
            isTracking: false,
            isDragging: false,
            isDecelerating: decelerate
        )
        publicScrollDelegate?.scrollViewDidEndDragging(scrollViewProxy, willDecelerate: decelerate)
    }

    public func scrollViewDidZoom(_ scrollView: UIScrollView) {
        logger.log("scrollViewDidZoom")
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        logger.log("scrollViewDidScrollToTop")
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateScrollProxy(
            contentOffset: scrollView.contentOffset,
            contentSize: scrollView.contentSize,
            visibleSize: scrollView.bounds.size,
            isTracking: false,
            isDragging: false,
            isDecelerating: false
        )
        publicScrollDelegate?.scrollViewDidEndDecelerating(scrollViewProxy)
    }
    
    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {

    }
}

extension UIView {
    func findViewController() -> UIViewController? {
        if let nextResponder = self.next as? UIViewController {
            return nextResponder
        } else if let nextResponder = self.next as? UIView {
            return nextResponder.findViewController()
        } else {
            return nil
        }
    }
}

#endif

// SKIP @nobridge
public class WebViewScriptCaller: Equatable, ObservableObject {
    let uuid = UUID().uuidString
    var caller: ((String, ((Any?, Error?) -> Void)?) -> Void)? = nil
    var asyncCaller: ((String, [String: Any]?, FrameInfo?, ContentWorld?) async throws -> Any?)? = nil

    private var multiTargetFrames = [String: FrameInfo]()

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
    public func evaluateJavaScript(_ js: String, arguments: [String: Any]? = nil, frame: FrameInfo? = nil, duplicateInMultiTargetFrames: Bool = false, in world: ContentWorld? = ContentWorld.page, completionHandler: ((Result<Any?, any Error>) async throws -> Void)? = nil) async {
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
    public func addMultiTargetFrame(_ frame: FrameInfo, uuid: String) -> Bool {
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


#endif
#endif
