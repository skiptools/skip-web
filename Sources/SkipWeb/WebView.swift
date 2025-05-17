// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
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
#endif

#if SKIP || os(iOS)

/// An embedded WebKit view. It is configured using a `WebEngineConfiguration`
///  and driven with a `WebViewNavigator` which can be associated
///  with user interface controls like back/forward buttons and a URL bar.
public struct WebView : View {
    private let config: WebEngineConfiguration
    let navigator: WebViewNavigator

    @Binding var state: WebViewState

    var scriptCaller: WebViewScriptCaller? = nil
    let blockedHosts: Set<String>? = []
    let htmlInState: Bool = false
    let schemeHandlers: [(URLSchemeHandler, String)] = []
    let onNavigationCommitted: (() -> Void)?
    let onNavigationFinished: (() -> Void)?
    let onNavigationFailed: (() -> Void)?
    let persistentWebViewID: String? = nil

    private static var engineCache: [String: WebEngine] = [:]
    private static let processPool = ProcessPool()

    //let onWarm: (() async -> Void)?
    //@State fileprivate var isWarm = false

    public init(configuration: WebEngineConfiguration = WebEngineConfiguration(), navigator: WebViewNavigator = WebViewNavigator(), url initialURL: URL? = nil, html initialHTML: String? = nil, state: Binding<WebViewState> = .constant(WebViewState()), onNavigationCommitted: (() -> Void)? = nil, onNavigationFinished: (() -> Void)? = nil, onNavigationFailed: (() -> Void)? = nil) {
        self.config = configuration
        self.navigator = navigator
        if let initialURL = initialURL {
            navigator.initialURL = initialURL
        }
        if let initialHTML = initialHTML {
            navigator.initialHTML = initialHTML
        }
        self._state = state
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
    }
}

/// The current state of a web page, including the loading status and the current URL
@available(macOS 14.0, iOS 17.0, *)
@Observable public class WebViewState {
    public internal(set) var isLoading: Bool = false
    public internal(set) var isProvisionallyNavigating: Bool = false
    public internal(set) var pageURL: URL?
    public internal(set) var estimatedProgress: Double?
    public internal(set) var pageTitle: String?
    public internal(set) var pageImageURL: URL?
    public internal(set) var pageHTML: String?
    public internal(set) var error: Error?
    public internal(set) var themeColor: Color?
    public internal(set) var backgroundColor: Color?
    public internal(set) var canGoBack: Bool = false
    public internal(set) var canGoForward: Bool = false
    public internal(set) var backList: [BackForwardListItem] = []
    public internal(set) var forwardList: [BackForwardListItem] = []
    public internal(set) var scrollingDown: Bool = false

    public init() {
    }
}

/// A controller that can drive a `WebEngine` from a user interface.
public class WebViewNavigator {
    var initialURL: URL?
    var initialHTML: String?

    @MainActor public var webEngine: WebEngine? {
        didSet {
            logger.info("assigned webEngine: \(self.webEngine?.description ?? "NULL")")

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
        // TODO: handle newTab
        let urlString = url.absoluteString
        logger.info("load URL=\(urlString) webView: \(self.webEngine?.description ?? "NONE")")
        guard let webView = webEngine?.webView else { return }
        #if SKIP
        // TODO: create a WebViewAssetLoader for jar:file: URLs to handle loading the HTML and resources from the apk
        // https://github.com/skiptools/skip-web/issues/1
        webView.loadUrl(urlString ?? "about:blank")
        #else
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        #endif
    }

    @MainActor public func reload() {
        logger.info("reload webView: \(self.webEngine?.description ?? "NONE")")
        webEngine?.reload()
    }

    @MainActor public func stopLoading() {
        logger.info("stopLoading webView: \(self.webEngine?.description ?? "NONE")")
        webEngine?.webView.stopLoading()
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
    
    @MainActor public func evaluateJavaScript(_ js: String) async throws -> String? {
        logger.info("evaluateJavaScript webView: \(self.webEngine?.description ?? "NONE")")
        return try await webEngine?.evaluate(js: js)
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
    public func postMessage(_ name: String, body: String) {
        guard let messageHandler = webEngine.configuration.messageHandlers[name] else {
            logger.error("no messageHandler for \(name)")
            return
        }
        let frameInfo = FrameInfo(isMainFrame: true, request: URLRequest(url: URL(string: "about:blank")!), securityOrigin: SecurityOrigin(), webView: webEngine.webView)
        let message = WebViewMessage(frameInfo: frameInfo, uuid: UUID(), name: name, body: body)
        Task {
            await messageHandler(message)
        }
    }
}

struct WebViewClient : android.webkit.WebViewClient {
    let webView: WebView
    override func onPageFinished(view: PlatformWebView, url: String) {
        if let onNavigationFinished = webView.onNavigationFinished {
            onNavigationFinished()
        }
    }
    
    override func onPageStarted(view: PlatformWebView, url: String, favicon: android.graphics.Bitmap?) {
        if let onNavigationCommitted = webView.onNavigationCommitted {
            onNavigationCommitted()
        }
    }
    
    override func onReceivedError(view: PlatformWebView, request: android.webkit.WebResourceRequest, error: android.webkit.WebResourceError) {
        if let onNavigationFailed = webView.onNavigationFailed {
            onNavigationFailed()
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

    @MainActor private func setupWebView(_ webEngine: WebEngine) -> WebEngine {
        navigator.webEngine = webEngine

        // configure JavaScript
        #if SKIP
        let settings = webEngine.webView.settings
        settings.setJavaScriptEnabled(config.javaScriptEnabled)
        settings.setSafeBrowsingEnabled(false)
        settings.setAllowContentAccess(true)
        settings.setAllowFileAccess(true)
        if (config.customUserAgent != nil ) {
            settings.setUserAgentString(config.customUserAgent)
        }
        webEngine.webView.setBackgroundColor(0x000000) // prevents screen flashing: https://issuetracker.google.com/issues/314821744
        webEngine.webView.addJavascriptInterface(MessageHandlerRouter(webEngine: webEngine), "skipWebAndroidMessageHandler")
        webEngine.engineDelegate = WebEngineDelegate(webEngine.configuration, WebViewClient(webView: self))

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

        webEngine.refreshMessageHandlers()
        webEngine.updateUserScripts()
        
        if (config.customUserAgent != "" ) {
            webEngine.webView.customUserAgent = config.customUserAgent
        }
        #endif

        return webEngine
    }

    public func update(webView: PlatformWebView) {
        //logger.info("WebView.update: \(webView)")
    }

    #if SKIP
    public var body: some View {
        ComposeView { ctx in
            AndroidView(factory: { ctx in
                config.context = ctx
                let webEngine = WebEngine(config)

                return setupWebView(webEngine).webView
            }, modifier: ctx.modifier, update: { webView in
                self.update(webView: webView)
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

        return web
    }

    @MainActor private func create(from context: Context) -> WebEngine {
        let webEngine = makeWebEngine(id: persistentWebViewID, config: config, coordinator: context.coordinator)
        context.coordinator.navigator.webEngine = webEngine

        let webView = webEngine.webView

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
                context.coordinator.state.pageURL = url
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
    public func updateUIView(_ uiView: WKWebView, context: Context) { update(webView: uiView) }
    #elseif canImport(AppKit)
    public func makeNSView(context: Context) -> WKWebView { create(from: context).webView }
    public func updateNSView(_ nsView: WKWebView, context: Context) { update(webView: nsView) }
    #endif
    #endif
}


@available(macOS 14.0, iOS 17.0, *)
@MainActor public class WebViewCoordinator: NSObject {
    private let webView: WebView

    var navigator: WebViewNavigator
    var scriptCaller: WebViewScriptCaller?
    var config: WebEngineConfiguration
    
    var compiledContentRules = [String: ContentRuleList]()

    #if !SKIP
    var subscriptions: Set<AnyCancellable> = []
    var lastScrollOffset: CGPoint = .zero
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

        // TODO: Make about:blank history initialization optional via configuration.
//        #warning("confirm this still works")
//        if  webView.state.backList.isEmpty && webView.state.forwardList.isEmpty && webView.state.pageURL.absoluteString == "about:blank" {
//            Task { @MainActor in
//                webView.action = .load(URLRequest(url: URL(string: "about:blank")!))
//            }
//        }
    }

    @discardableResult func openURL(url: URL, newTab: Bool) -> PlatformWebView? {
        // TODO: handle newTab
        navigator.load(url: url)
        return nil // TOOD: return new PlatformWebView
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
}


#if !SKIP
@available(macOS 14.0, iOS 17.0, *)
extension WebViewCoordinator: WebUIDelegate {

    @MainActor public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        logger.log("createWebViewWith: \(configuration) \(navigationAction)")
        if let url = navigationAction.request.url {
            return openURL(url: url, newTab: true)
        }
        return nil // self.navigator.webEngine?.webView // uncaught exception 'NSInternalInconsistencyException', reason: 'Returned WKWebView was not created with the given configuration.'
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
        let state = self.webView.state
        state.isLoading = false
        state.pageURL = webView.url
        state.isProvisionallyNavigating = false

        updatePageState(webView: webView)

        if let onNavigationFinished = self.webView.onNavigationFinished {
            onNavigationFinished()
        }
    }

    private func updatePageState(webView: PlatformWebView) {
        let state = self.webView.state

        state.isLoading = webView.isLoading
        state.estimatedProgress = webView.estimatedProgress
        state.pageTitle = webView.title
        state.pageURL = webView.url
        state.canGoBack = webView.canGoBack
        state.canGoForward = webView.canGoForward
        state.backList = webView.backForwardList.backList
        state.forwardList = webView.backForwardList.forwardList

        //updatePageStateJS(webView: webView)
    }

    private func updatePageStateJS(webView: PlatformWebView) {

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
    public func webView(_ webView: PlatformWebView, didFailProvisionalNavigation navigation: WebNavigation!, withError error: Error) {
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
        scriptCaller?.removeAllMultiTargetFrames()
        self.webView.state.isLoading = false
        self.webView.state.isProvisionallyNavigating = false
        self.webView.state.error = error

        updatePageState(webView: webView)
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, didCommit navigation: WebNavigation!) {
        scriptCaller?.removeAllMultiTargetFrames()
        self.webView.state.isLoading = true
        self.webView.state.isProvisionallyNavigating = false
        updatePageState(webView: webView)
        if let onNavigationCommitted = self.webView.onNavigationCommitted {
            onNavigationCommitted()
        }
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, didStartProvisionalNavigation navigation: WebNavigation!) {
        updatePageState(webView: webView)
        self.webView.state.estimatedProgress = 0.0
        self.webView.state.isProvisionallyNavigating = true
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, decidePolicyFor navigationAction: WebNavigationAction, preferences: WebpagePreferences) async -> (NavigationActionPolicy, WebpagePreferences) {
        if let host = navigationAction.request.url?.host, let blockedHosts = self.webView.blockedHosts {
            if blockedHosts.contains(where: { host.contains($0) }) {
                self.webView.state.isProvisionallyNavigating = false
                self.webView.state.isLoading = false
                return (.cancel, preferences)
            }
        }

        return (.allow, preferences)
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, decidePolicyFor navigationResponse: NavigationResponse) async -> NavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let url = navigationResponse.response.url, self.webView.state.pageURL != url {
            scriptCaller?.removeAllMultiTargetFrames()
            let newState = self.webView.state
            newState.pageURL = url
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
        //logger.log("scrollView: isDecelerating=\(scrollView.isDecelerating) isDragging=\(scrollView.isDragging) isTracking=\(scrollView.isTracking) isZoomBouncing=\(scrollView.isZoomBouncing) contentOffset=\(scrollView.contentOffset.debugDescription)")
        // ignore scrolling while the page is loading
        if self.state.isLoading { return }
        // only change the state if we are actively dragging, not if intertial scrolling is in effect
        if !scrollView.isTracking { return }

        defer { self.lastScrollOffset = scrollView.contentOffset }
        let offsetY = scrollView.contentOffset.y
        let isScrollingDown = ((offsetY + scrollView.visibleSize.height) >= scrollView.contentSize.height) || (offsetY > 0 && offsetY > self.lastScrollOffset.y)

        if self.state.scrollingDown != isScrollingDown {
            self.state.scrollingDown = isScrollingDown
        }
    }

    public func scrollViewDidZoom(_ scrollView: UIScrollView) {
        logger.log("scrollViewDidZoom")
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        logger.log("scrollViewDidScrollToTop")
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {

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
    public func evaluateJavaScript(_ js: String, arguments: [String: Any]? = nil, frame: FrameInfo? = nil, duplicateInMultiTargetFrames: Bool = false, in world: ContentWorld? = .page, completionHandler: ((Result<Any?, any Error>) async throws -> Void)? = nil) async {
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

