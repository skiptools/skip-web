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
#endif

#if SKIP || os(iOS)

/// An embedded WebKit view. It is configured using a `WebEngineConfiguration`
///  and driven with a `WebViewNavigator` which can be associated
///  with user interface controls like back/forward buttons and a URL bar.
@available(macOS 14.0, iOS 17.0, *)
public struct WebView : View {
    private let config: WebEngineConfiguration
    let navigator: WebViewNavigator

    @Binding var state: WebViewState
    @State fileprivate var needsHistoryRefresh: Bool
    @State private var lastInstalledScripts: [WebViewUserScript]

    var scriptCaller: WebViewScriptCaller? = nil
    let blockedHosts: Set<String>? = []
    let htmlInState: Bool = false
    let schemeHandlers: [(URLSchemeHandler, String)] = []
    var messageHandlers: [String: ((WebViewMessage) async -> Void)] = [:]
    let onNavigationCommitted: ((WebViewState) -> Void)? = nil
    let onNavigationFinished: ((WebViewState) -> Void)? = nil
    let persistentWebViewID: String? = nil

    private var messageHandlerNamesToRegister = Set<String>()
    private var userContentController = UserContentController()

    private static var engineCache: [String: WebEngine] = [:]
    private static let processPool = ProcessPool()

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

/// The current state of a web page, including the loading status and the current URL
@available(macOS 14.0, iOS 17.0, *)
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

    @MainActor public func load(url: URL, newTab: Bool) {
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

    public func update(webView: PlatformWebView) {
        logger.info("WebView.update: \(webView)")
        //webView.load(URLRequest(url: url))
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
                self.update(webView: webView)
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

    @MainActor private func create(from context: Context) -> WebEngine {
        let webEngine = makeWebEngine(id: persistentWebViewID, config: config, coordinator: context.coordinator, messageHandlerNamesToRegister: messageHandlerNamesToRegister)
        let webView = webEngine.webView
        refreshMessageHandlers(userContentController: webView.configuration.userContentController, context: context)

        refreshContentRules(userContentController: webView.configuration.userContentController, coordinator: context.coordinator)

        webView.configuration.userContentController = userContentController
        webView.allowsLinkPreview = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures

        #if os(iOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        //webView.scrollView.contentInsetAdjustmentBehavior = .scrollableAxes
        webView.scrollView.isScrollEnabled = config.isScrollEnabled
        webView.pageZoom = config.pageZoom
        webView.isOpaque = config.isOpaque
        webView.isInspectable = true
        
        // add a pull-to-refresh control to the page
        webView.scrollView.refreshControl = UIRefreshControl()
        webView.scrollView.refreshControl?.addTarget(context.coordinator, action: #selector(Coordinator.handleRefreshControl), for: .valueChanged)
        #endif

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
@available(macOS 14.0, iOS 17.0, *)
extension WebView {
    @MainActor
    func refreshContentRules(userContentController: UserContentController, coordinator: Coordinator) {
        userContentController.removeAllContentRuleLists()
        guard let contentRules = config.contentRules else { return }
        if let ruleList = coordinator.compiledContentRules[contentRules] {
            userContentController.add(ruleList)
        } else {
            ContentRuleListStore.default().compileContentRuleList(
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
    func refreshMessageHandlers(userContentController: UserContentController, context: Context) {
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
    func updateUserScripts(userContentController: UserContentController, coordinator: WebViewCoordinator, forDomain domain: URL?, config: WebEngineConfiguration) {
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


@available(macOS 14.0, iOS 17.0, *)
public class WebViewCoordinator: NSObject {
    private let webView: WebView

    var navigator: WebViewNavigator
    var scriptCaller: WebViewScriptCaller?
    var config: WebEngineConfiguration
    var registeredMessageHandlerNames = Set<String>()

    var compiledContentRules = [String: ContentRuleList]()

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
@available(macOS 14.0, iOS 17.0, *)
extension WebViewCoordinator: ScriptMessageHandler {
    public func userContentController(_ userContentController: UserContentController, didReceive message: ScriptMessage) {
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
#endif


#if !SKIP
@available(macOS 14.0, iOS 17.0, *)
extension WebViewCoordinator: WebUIDelegate {

    public func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }

        logger.log("webView contextMenuConfigurationFor: \(url)")

        let menu = UIMenu(title: "", children: [
            UIAction(title: NSLocalizedString("Open", bundle: .module, comment: "context menu action name for opening a url"), image: UIImage(systemName: "plus.square")) { _ in
                Task {
                    await self.navigator.load(url: url, newTab: true)
                }
            },
            UIAction(title: NSLocalizedString("Open in New Tab", bundle: .module, comment: "context menu action name for opening a url in a new tab"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                Task {
                    await self.navigator.load(url: url, newTab: true)
                }
            },
            UIAction(title: NSLocalizedString("Open in Default Browser", bundle: .module, comment: "context menu action name for opening a url in the system browser"), image: UIImage(systemName: "safari")) { _ in
                UIApplication.shared.open(url)
            },
            UIAction(title: NSLocalizedString("Copy Link", bundle: .module, comment: "context menu action name for copying a URL link"), image: UIImage(systemName: "doc.on.clipboard")) { _ in
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

    private func extractPageState(webView: PlatformWebView) {
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
        setLoading(false, isProvisionallyNavigating: false, error: error)
    }

    @MainActor
    public func webViewWebContentProcessDidTerminate(_ webView: PlatformWebView) {
        setLoading(false, isProvisionallyNavigating: false)
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, didFail navigation: WebNavigation!, withError error: Error) {
        scriptCaller?.removeAllMultiTargetFrames()
        setLoading(false, isProvisionallyNavigating: false, error: error)

        extractPageState(webView: webView)
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, didCommit navigation: WebNavigation!) {
        scriptCaller?.removeAllMultiTargetFrames()
        let newState = setLoading(true, pageURL: webView.url, isProvisionallyNavigating: false)
        if let onNavigationCommitted = self.webView.onNavigationCommitted {
            onNavigationCommitted(newState)
        }
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, didStartProvisionalNavigation navigation: WebNavigation!) {
        setLoading(
            true,
            isProvisionallyNavigating: true,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList)
    }

    @MainActor
    public func webView(_ webView: PlatformWebView, decidePolicyFor navigationAction: WebNavigationAction, preferences: WebpagePreferences) async -> (NavigationActionPolicy, WebpagePreferences) {
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
    public func webView(_ webView: PlatformWebView, decidePolicyFor navigationResponse: NavigationResponse) async -> NavigationResponsePolicy {
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

#endif

