// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if !SKIP_BRIDGE
import Foundation
import SwiftUI
#if !SKIP
import WebKit
import UniformTypeIdentifiers
import CryptoKit
#else
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.webkit.WebResourceRequestCompat
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlin.coroutines.suspendCoroutine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
#endif

public enum WebProfile: Equatable, Hashable, Sendable {
    /// Uses the platform default persistent website data store.
    case `default`
    /// Uses a persistent website data store isolated by the supplied identifier.
    case named(String)
    /// Uses an in-memory website data store when the platform supports one.
    ///
    /// On iOS this maps to `WKWebsiteDataStore.nonPersistent()`. On Android this maps to
    /// a generated named WebView profile when `MULTI_PROFILE` is supported.
    case ephemeral

    fileprivate var normalizedNamedIdentifier: String? {
        guard case .named(let rawIdentifier) = self else {
            return nil
        }
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            return nil
        }
        if identifier.lowercased() == "default" {
            return nil
        }
        return identifier
    }
}

public enum WebProfileError: Error, Equatable {
    case unsupportedOnAndroid
    case invalidProfileName
    case profileSetupFailed
}

enum WebProfilePolicy {
    static func validationError(for profile: WebProfile) -> WebProfileError? {
        switch profile {
        case .default, .ephemeral:
            return nil
        case .named:
            return profile.normalizedNamedIdentifier == nil ? .invalidProfileName : nil
        }
    }

    static func androidSupportError(
        for profile: WebProfile,
        isMultiProfileFeatureSupported: Bool
    ) -> WebProfileError? {
        if let validationError = validationError(for: profile) {
            return validationError
        }
        switch profile {
        case .default:
            return nil
        case .ephemeral:
            return isMultiProfileFeatureSupported ? nil : .unsupportedOnAndroid
        case .named:
            return isMultiProfileFeatureSupported ? nil : .unsupportedOnAndroid
        }
    }
}

#if SKIP || os(iOS)

/// A bridge-safe message sent from JavaScript to the host app.
///
/// `bodyJSON` is the canonical payload. JavaScript values posted through
/// `window.webkit.messageHandlers.<name>.postMessage(...)` are encoded with
/// `JSON.stringify` before crossing the platform bridge.
public struct WebViewScriptMessage: Equatable, Sendable {
    /// The configured message handler name.
    public let name: String
    /// The JSON-encoded JavaScript message body.
    public let bodyJSON: String
    /// The URL of the frame that sent the message, when available.
    public let sourceURL: String?
    /// Whether the sending frame is the main frame, when available.
    public let isMainFrame: Bool?

    /// Creates a script message envelope.
    public init(name: String, bodyJSON: String, sourceURL: String? = nil, isMainFrame: Bool? = nil) {
        self.name = name
        self.bodyJSON = bodyJSON
        self.sourceURL = sourceURL
        self.isMainFrame = isMainFrame
    }
}

/// Delegate for bridge-safe JavaScript messages sent from a web view.
@MainActor
public protocol WebViewScriptMessageDelegate: AnyObject {
    /// Called when JavaScript posts a message to a configured handler name.
    func webEngine(_ webEngine: WebEngine, didReceiveScriptMessage message: WebViewScriptMessage)
}

#if !SKIP
private func webViewScriptMessageBodyJSON(from body: Any) -> String {
    if body is NSNull {
        return "null"
    }

    if JSONSerialization.isValidJSONObject(body),
       let data = try? JSONSerialization.data(withJSONObject: body, options: []),
       let json = String(data: data, encoding: .utf8) {
        return json
    }

    let wrappedBody: [Any] = [body]
    if JSONSerialization.isValidJSONObject(wrappedBody),
       let data = try? JSONSerialization.data(withJSONObject: wrappedBody, options: []),
       let wrappedJSON = String(data: data, encoding: .utf8),
       wrappedJSON.hasPrefix("["),
       wrappedJSON.hasSuffix("]") {
        let start = wrappedJSON.index(after: wrappedJSON.startIndex)
        let end = wrappedJSON.index(before: wrappedJSON.endIndex)
        return String(wrappedJSON[start..<end])
    }

    if let data = try? JSONEncoder().encode(String(describing: body)),
       let json = String(data: data, encoding: .utf8) {
        return json
    }

    return "null"
}
#endif

public struct SkipWebSnapshotRect: Equatable, Sendable {
    public static let null = SkipWebSnapshotRect(x: 0.0, y: 0.0, width: -1.0, height: -1.0)

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isNull: Bool {
        width < 0.0 || height < 0.0
    }

    fileprivate var asCGRect: CGRect {
        isNull ? .null : CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Snapshot configuration for `WebEngine.takeSnapshot(configuration:)`.
///
/// This mirrors the key behavior of `WKSnapshotConfiguration`:
/// - `rect`: view-coordinate capture region (`.null` means full visible bounds)
/// - `snapshotWidth`: optional output width while preserving aspect ratio
/// - `afterScreenUpdates`: capture after pending updates when possible
public struct SkipWebSnapshotConfiguration {
    public var rect: SkipWebSnapshotRect
    public var snapshotWidth: Double?
    public var afterScreenUpdates: Bool

    public init(rect: SkipWebSnapshotRect = .null, snapshotWidth: Double? = nil, afterScreenUpdates: Bool = true) {
        self.rect = rect
        self.snapshotWidth = snapshotWidth
        self.afterScreenUpdates = afterScreenUpdates
    }
}

/// A captured web-view snapshot stored as PNG bytes plus pixel dimensions.
public struct SkipWebSnapshot {
    public let pngData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum WebSnapshotError: Error {
    case viewNotLaidOut
    case afterScreenUpdatesUnavailable
    case invalidRect
    case emptySnapshot
    case pngEncodingFailed
}

/// Portable cookie representation shared by iOS and Android implementations.
public struct WebCookie: Equatable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var domain: String?
    public var path: String?
    public var expires: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool

    public init(
        name: String,
        value: String,
        domain: String? = nil,
        path: String? = nil,
        expires: Date? = nil,
        isSecure: Bool = false,
        isHTTPOnly: Bool = false
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }
}

public enum WebCookieError: Error {
    case invalidCookieName
    case missingCookieDomain
    case invalidCookie
}

/// Cross-platform content-blocker configuration for a `WebEngine`.
///
/// Think of it as the single place where apps describe:
/// - iOS rule-list files to compile and install
/// - domains that should bypass blocking entirely
/// - popup source domains that should bypass popup blocking only
/// - Android request and cosmetic blocking behavior
public struct WebContentBlockerConfiguration {
    /// Paths to iOS WebKit content-blocker JSON files.
    ///
    /// SkipWeb compiles these files into `WKContentRuleList` values and installs them
    /// into the web view configuration on Apple platforms.
    public var iOSRuleListPaths: [String]
    /// Domain allowlist entries that bypass SkipWeb-managed blocking on matching pages.
    ///
    /// Entries use WebKit-style host matching such as `example.com` and `*.example.com`.
    public var whitelistedDomains: [String]
    /// Popup source-site allowlist entries that bypass popup blocking only.
    ///
    /// Bare domains such as `example.com` cover both the exact host and common
    /// subdomains. Wildcard entries such as `*.example.com` cover subdomains only.
    public var popupWhitelistedSourceDomains: [String]
    /// Primary Android content-blocking entry point.
    ///
    /// Use `.custom(...)` to supply request and cosmetic blocking behavior from one provider.
    public var androidMode: AndroidContentBlockingMode

    /// Creates a content-blocker configuration.
    ///
    /// - Parameters:
    ///   - iOSRuleListPaths: iOS WebKit content-blocker JSON files to compile.
    ///   - whitelistedDomains: Host patterns that should bypass blocking.
    ///   - popupWhitelistedSourceDomains: Popup source-site host patterns that should bypass popup blocking only.
    ///   - androidMode: Primary Android blocking configuration.
    public init(
        iOSRuleListPaths: [String] = [],
        whitelistedDomains: [String] = [],
        popupWhitelistedSourceDomains: [String] = [],
        androidMode: AndroidContentBlockingMode = .disabled
    ) {
        self.iOSRuleListPaths = iOSRuleListPaths
        self.whitelistedDomains = whitelistedDomains
        self.popupWhitelistedSourceDomains = popupWhitelistedSourceDomains
        self.androidMode = androidMode
    }
}

/// Android request and cosmetic blocking provider used by `AndroidContentBlockingMode.custom`.
public protocol AndroidContentBlockingProvider {
    /// Long-lived cosmetic rules that SkipWeb can reuse across navigations.
    ///
    /// Put CSS here when it acts like a baseline for the whole browsing session rather than
    /// a rule that depends on the current page URL.
    var persistentCosmeticRules: [AndroidCosmeticRule] { get }
    /// Returns the request-blocking decision for an Android resource load.
    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision
    /// Returns page-specific cosmetic rules for the current main-frame navigation.
    ///
    /// Think of this as the per-page delta that sits on top of `persistentCosmeticRules`.
    func navigationCosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule]
}

public extension AndroidContentBlockingProvider {
    /// Default request-blocking implementation that allows every request.
    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision {
        .allow
    }
}

/// Android content-blocking mode used by `WebContentBlockerConfiguration`.
public enum AndroidContentBlockingMode {
    /// Disable SkipWeb-managed Android content blocking.
    case disabled
    /// Use a custom provider for Android request and cosmetic blocking.
    case custom(any AndroidContentBlockingProvider)
}

/// Request-blocking decision returned by Android blocker providers.
public enum AndroidRequestBlockDecision: Equatable, Sendable {
    /// Allow the request to continue.
    case allow
    /// Block the request and return an empty response.
    case block
}

/// Best-effort Android resource classification exposed to request blockers.
public enum AndroidResourceTypeHint: String, CaseIterable, Hashable, Sendable {
    case document
    case subdocument
    case stylesheet
    case script
    case image
    case font
    case media
    case xhr
    case fetch
    case websocket
    case other
}

/// Android request details passed to request blockers.
public struct AndroidBlockableRequest: Equatable, Sendable {
    /// The URL being requested.
    public var url: URL
    /// The current main document URL when known.
    public var mainDocumentURL: URL?
    /// The HTTP method used for the request.
    public var method: String
    /// HTTP headers captured from the Android request when available.
    public var headers: [String: String]
    /// Whether Android marked this as a main-frame navigation.
    public var isForMainFrame: Bool
    /// Whether the request was triggered by a user gesture.
    public var hasGesture: Bool
    /// Whether Android marked this request as a redirect, when known.
    public var isRedirect: Bool?
    /// Best-effort Android resource classification for the request.
    public var resourceTypeHint: AndroidResourceTypeHint?

    /// Creates an Android request description for blocker evaluation.
    public init(
        url: URL,
        mainDocumentURL: URL? = nil,
        method: String,
        headers: [String: String] = [:],
        isForMainFrame: Bool,
        hasGesture: Bool,
        isRedirect: Bool? = nil,
        resourceTypeHint: AndroidResourceTypeHint? = nil
    ) {
        self.url = url
        self.mainDocumentURL = mainDocumentURL
        self.method = method
        self.headers = headers
        self.isForMainFrame = isForMainFrame
        self.hasGesture = hasGesture
        self.isRedirect = isRedirect
        self.resourceTypeHint = resourceTypeHint
    }
}

/// Page details passed to Android cosmetic blockers.
public struct AndroidPageContext: Equatable, Sendable {
    /// The current page URL.
    public var url: URL
    /// The page host, defaulting to `url.host`.
    public var host: String?

    /// Creates a page context for Android cosmetic rule evaluation.
    public init(url: URL, host: String? = nil) {
        self.url = url
        self.host = host ?? url.host
    }
}

/// Frame scope for an Android cosmetic rule.
public enum AndroidCosmeticFrameScope: String, CaseIterable, Hashable, Sendable {
    /// Apply only in the top-level document.
    case mainFrameOnly
    /// Apply only in subframes.
    case subframesOnly
    /// Apply in both the top-level document and subframes.
    case allFrames
}

/// Preferred injection timing for an Android cosmetic rule.
public enum AndroidCosmeticInjectionTiming: String, CaseIterable, Hashable, Sendable {
    /// Install at document start when supported.
    case documentStart
    /// Inject later during the page lifecycle.
    case pageLifecycle
}

/// Android cosmetic rule describing CSS to hide or scope.
public struct AndroidCosmeticRule: Equatable, Sendable {
    /// Selector or selector-list entries to hide with `display: none !important`.
    public var hiddenSelectors: [String]
    /// Optional regex-style URL filter that must match the current frame URL before the rule applies.
    ///
    /// Think of it as a runtime frame guard: SkipWeb checks it inside the injected script
    /// so a rule can stay registered while only applying to matching subframes or redirected pages.
    public var urlFilterPattern: String?
    /// Allowed origins used when registering Android document-start scripts.
    ///
    /// This is a platform registration scope, not just an in-script filter.
    /// `WebViewCompat.addDocumentStartJavaScript(...)` requires these origin rules up front,
    /// so SkipWeb needs them to decide where the script is injected at all.
    public var allowedOriginRules: [String]
    /// Host patterns that must match the current frame host before the rule applies.
    public var ifDomainList: [String]
    /// Host patterns that must not match the current frame host before the rule applies.
    public var unlessDomainList: [String]
    /// Frame scope for the injected CSS.
    public var frameScope: AndroidCosmeticFrameScope
    /// Preferred injection timing for the CSS.
    public var preferredTiming: AndroidCosmeticInjectionTiming

    /// Creates an Android cosmetic rule.
    ///
    /// `hiddenSelectors` is the public API shape; SkipWeb turns each selector into
    /// `display: none !important` CSS internally.
    public init(
        hiddenSelectors: [String] = [],
        urlFilterPattern: String? = nil,
        allowedOriginRules: [String] = ["*"],
        ifDomainList: [String] = [],
        unlessDomainList: [String] = [],
        frameScope: AndroidCosmeticFrameScope = .mainFrameOnly,
        preferredTiming: AndroidCosmeticInjectionTiming = .documentStart
    ) {
        self.hiddenSelectors = Self.normalizedHiddenSelectors(hiddenSelectors)
        self.urlFilterPattern = urlFilterPattern
        self.allowedOriginRules = allowedOriginRules
        self.ifDomainList = ifDomainList
        self.unlessDomainList = unlessDomainList
        self.frameScope = frameScope
        self.preferredTiming = preferredTiming
    }

    fileprivate static func normalizedHiddenSelectors(_ selectors: [String]) -> [String] {
        selectors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    fileprivate static func hideCSS(for selectors: [String]) -> [String] {
        normalizedHiddenSelectors(selectors)
            .map { "\($0) { display: none !important; }" }
    }
}

public protocol SkipWebNavigationDelegate {
    func webEngine(_ engine: WebEngine, shouldOverrideURLLoading url: URL) -> Bool
    func webEngineDidCommitNavigation(_ engine: WebEngine)
    func webEngineDidFinishNavigation(_ engine: WebEngine)
    func webEngine(_ engine: WebEngine, didFailNavigation error: Error)
}

public extension SkipWebNavigationDelegate {
    func webEngine(_ engine: WebEngine, shouldOverrideURLLoading url: URL) -> Bool {
        false
    }

    func webEngineDidCommitNavigation(_ engine: WebEngine) {
    }

    func webEngineDidFinishNavigation(_ engine: WebEngine) {
    }

    func webEngine(_ engine: WebEngine, didFailNavigation error: Error) {
    }
}

struct AndroidCosmeticInjectionPlan {
    var documentStartRules: [AndroidCosmeticRule] = []
    var lifecycleCSS: [String] = []
}

struct AndroidDocumentStartRuleBatchKey: Hashable {
    let frameScope: AndroidCosmeticFrameScope
    let preferredTiming: AndroidCosmeticInjectionTiming
    let urlFilterPattern: String?
    let allowedOriginRules: [String]
    let ifDomainList: [String]
    let unlessDomainList: [String]
}

fileprivate struct WhitelistedAndroidContentBlockingProvider: AndroidContentBlockingProvider {
    let provider: any AndroidContentBlockingProvider
    let whitelistedDomains: [String]

    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision {
        if isWhitelisted(request: request) {
            return .allow
        }
        return provider.requestDecision(for: request)
    }

    var persistentCosmeticRules: [AndroidCosmeticRule] {
        provider.persistentCosmeticRules
    }

    func navigationCosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule] {
        provider.navigationCosmeticRules(for: page)
    }

    private func isWhitelisted(request: AndroidBlockableRequest) -> Bool {
        if WebContentBlockerConfiguration.matchesWhitelistedURL(request.mainDocumentURL, in: whitelistedDomains) {
            return true
        }
        if request.isForMainFrame {
            return WebContentBlockerConfiguration.matchesWhitelistedURL(request.url, in: whitelistedDomains)
        }
        return false
    }
}

extension WebContentBlockerConfiguration {
    var normalizedWhitelistedDomains: [String] {
        Self.normalizedWhitelistedDomains(from: whitelistedDomains)
    }

    var normalizedPopupWhitelistedSourceDomains: [String] {
        Self.normalizedWhitelistedDomains(from: popupWhitelistedSourceDomains)
    }

    var effectiveAndroidMode: AndroidContentBlockingMode {
        switch androidMode {
        case .disabled:
            return .disabled
        case .custom(let provider):
            guard !normalizedWhitelistedDomains.isEmpty else {
                return .custom(provider)
            }
            return .custom(
                WhitelistedAndroidContentBlockingProvider(
                    provider: provider,
                    whitelistedDomains: normalizedWhitelistedDomains
                )
            )
        }
    }

    var effectiveAndroidProvider: (any AndroidContentBlockingProvider)? {
        switch effectiveAndroidMode {
        case .disabled:
            return nil
        case .custom(let provider):
            return provider
        }
    }

    static func normalizedWhitelistedDomains(from domains: [String]) -> [String] {
        Array(
            Set(
                domains.compactMap { domain in
                    let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return trimmed.isEmpty ? nil : trimmed
                }
            )
        ).sorted()
    }

    static func matchesWhitelistedURL(_ url: URL?, in domains: [String]) -> Bool {
        matchesWhitelistedDomain(url?.host, in: domains)
    }

    static func matchesWhitelistedDomain(_ host: String?, in domains: [String]) -> Bool {
        guard let normalizedHost = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedHost.isEmpty else {
            return false
        }

        for domain in domains {
            if domain.hasPrefix("*.") {
                let suffix = String(domain.dropFirst(2))
                guard !suffix.isEmpty else {
                    continue
                }
                if normalizedHost.count > suffix.count && normalizedHost.hasSuffix(".\(suffix)") {
                    return true
                }
            } else if normalizedHost == domain {
                return true
            }
        }

        return false
    }

    #if !SKIP
    func augmentedIOSRuleListContent(_ content: String) -> String {
        Self.augmentedIOSRuleListContent(
            content,
            whitelistedDomains: normalizedWhitelistedDomains,
            popupWhitelistedSourceDomains: normalizedPopupWhitelistedSourceDomains
        )
    }

    static func augmentedIOSRuleListContent(
        _ content: String,
        whitelistedDomains: [String],
        popupWhitelistedSourceDomains: [String] = []
    ) -> String {
        guard !whitelistedDomains.isEmpty || !popupWhitelistedSourceDomains.isEmpty,
              let data = content.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              var rules = jsonObject as? [[String: Any]] else {
            return content
        }

        if !whitelistedDomains.isEmpty {
            rules.append([
                "comment": "user-injected domain exemptions (whitelisted domains)",
                "trigger": [
                    "url-filter": ".*",
                    "if-domain": whitelistedDomains
                ],
                "action": [
                    "type": "ignore-previous-rules"
                ]
            ])
        }

        let popupTopURLs = popupWhitelistTopURLs(from: popupWhitelistedSourceDomains)
        if !popupTopURLs.isEmpty {
            rules.append([
                "comment": "user-injected popup exemptions (allowed source domains)",
                "trigger": [
                    "url-filter": ".*",
                    "resource-type": ["popup"],
                    "if-top-url": popupTopURLs
                ],
                "action": [
                    "type": "ignore-previous-rules"
                ]
            ])
        }

        guard JSONSerialization.isValidJSONObject(rules),
              let augmentedData = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let augmentedContent = String(data: augmentedData, encoding: .utf8) else {
            return content
        }

        return augmentedContent
    }

    static func popupWhitelistTopURLs(from domains: [String]) -> [String] {
        Array(
            Set(
                domains.flatMap { domain in
                    if domain.hasPrefix("*.") {
                        return ["http://\(domain)/*", "https://\(domain)/*"]
                    } else {
                        return [
                            "http://\(domain)/*",
                            "http://*.\(domain)/*",
                            "https://\(domain)/*",
                            "https://*.\(domain)/*",
                        ]
                    }
                }
            )
        ).sorted()
    }
    #endif
}

/// Errors surfaced while preparing, caching, or installing content blockers.
public enum WebContentBlockerError: Error, Equatable, LocalizedError {
    /// SkipWeb could not create or access the persistent content-blocker store.
    case storeUnavailable(String)
    /// SkipWeb could not read a configured content-blocker file.
    case fileReadFailed(path: String, description: String)
    /// A configured content-blocker file was not valid UTF-8 text.
    case fileEncodingFailed(path: String)
    /// SkipWeb could not look up a previously compiled rule list in the cache.
    case cacheLookupFailed(identifier: String, description: String)
    /// WebKit failed to compile a rule-list file.
    case compilationFailed(path: String, description: String)
    /// SkipWeb could not read the persistent metadata it uses to track compiled rule lists.
    case metadataReadFailed(String)
    /// SkipWeb could not write the persistent metadata it uses to track compiled rule lists.
    case metadataWriteFailed(String)
    /// SkipWeb could not prune a stale compiled rule list from the cache.
    case staleRuleRemovalFailed(identifier: String, description: String)
    /// A content-blocker store operation did not finish before the timeout.
    case operationTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable(let description):
            return "Content blocker store unavailable: \(description)"
        case .fileReadFailed(let path, let description):
            return "Failed to read content blocker file at \(path): \(description)"
        case .fileEncodingFailed(let path):
            return "Content blocker file is not valid UTF-8: \(path)"
        case .cacheLookupFailed(let identifier, let description):
            return "Failed to look up compiled content blocker \(identifier): \(description)"
        case .compilationFailed(let path, let description):
            return "Failed to compile content blocker file at \(path): \(description)"
        case .metadataReadFailed(let description):
            return "Failed to read content blocker metadata: \(description)"
        case .metadataWriteFailed(let description):
            return "Failed to write content blocker metadata: \(description)"
        case .staleRuleRemovalFailed(let identifier, let description):
            return "Failed to remove stale compiled content blocker \(identifier): \(description)"
        case .operationTimedOut(let description):
            return "Timed out while preparing content blockers: \(description)"
        }
    }
}

public enum WebSiteDataType: String, CaseIterable, Hashable, Sendable {
    case cookies
    case diskCache
    case memoryCache
    case offlineWebApplicationCache
    case localStorage
    case sessionStorage
    case webSQLDatabases
    case indexedDBDatabases
}

public enum WebDataRemovalError: Error, Equatable {
    case unsupportedModifiedSinceOnAndroid
}

enum WebDataRemovalBucket: Hashable {
    case cookies
    case cache
    case storage
}

extension WebSiteDataType {
    var androidRemovalBucket: WebDataRemovalBucket {
        switch self {
        case .cookies:
            return .cookies
        case .diskCache, .memoryCache, .offlineWebApplicationCache:
            return .cache
        case .localStorage, .sessionStorage, .webSQLDatabases, .indexedDBDatabases:
            return .storage
        }
    }

    #if !SKIP
    var webKitDataType: String {
        switch self {
        case .cookies:
            return WKWebsiteDataTypeCookies
        case .diskCache:
            return WKWebsiteDataTypeDiskCache
        case .memoryCache:
            return WKWebsiteDataTypeMemoryCache
        case .offlineWebApplicationCache:
            return WKWebsiteDataTypeOfflineWebApplicationCache
        case .localStorage:
            return WKWebsiteDataTypeLocalStorage
        case .sessionStorage:
            return WKWebsiteDataTypeSessionStorage
        case .webSQLDatabases:
            return WKWebsiteDataTypeWebSQLDatabases
        case .indexedDBDatabases:
            return WKWebsiteDataTypeIndexedDBDatabases
        }
    }
    #endif
}

extension WebCookie {
    func matches(url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if isSecure && (url.scheme?.lowercased() != "https") {
            return false
        }
        if let expires, expires <= now {
            return false
        }

        if let domain = normalizedDomain, !domain.isEmpty {
            // Treat no-dot domains as host-only so they don't leak to subdomains.
            if isHostOnlyDomain {
                if host != domain {
                    return false
                }
            } else if host != domain && !host.hasSuffix("." + domain) {
                return false
            }
        }

        let requestPath = normalizedRequestPath(url.path)
        let cookiePath = normalizedCookiePath
        // Enforce RFC-style path boundary matching ("/a" does not match "/ab").
        return requestPathMatchesCookiePath(requestPath, cookiePath: cookiePath)
    }

    static func parseRequestCookieHeader(_ header: String) -> [WebCookie] {
        let rawComponents = header.split(separator: ";")
        var cookies: [WebCookie] = []
        for rawComponent in rawComponents {
            let component = String(rawComponent).trimmingCharacters(in: .whitespacesAndNewlines)
            if component.isEmpty {
                continue
            }
            guard let equalIndex = component.firstIndex(of: "=") else {
                continue
            }
            let name = String(component[..<equalIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueIndex = component.index(after: equalIndex)
            let value = String(component[valueIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                continue
            }
            cookies.append(WebCookie(name: name, value: value))
        }
        return cookies
    }

    static func parseSetCookieHeaders(_ headers: [String], responseURL: URL) -> [WebCookie] {
        #if !SKIP
        var parsedCookies: [WebCookie] = []
        for header in headers {
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            let nativeCookies = HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": trimmed],
                for: responseURL
            )
            for nativeCookie in nativeCookies {
                parsedCookies.append(WebCookie(nativeCookie: nativeCookie))
            }
        }
        return parsedCookies
        #else
        var parsedCookies: [WebCookie] = []
        for header in headers {
            if let cookie = parseSingleSetCookieHeader(header, responseURL: responseURL) {
                parsedCookies.append(cookie)
            }
        }
        return parsedCookies
        #endif
    }

    fileprivate static func parseSingleSetCookieHeader(_ header: String, responseURL: URL) -> WebCookie? {
        let segments = header.split(separator: ";")
        guard let firstSegment = segments.first else {
            return nil
        }
        let first = String(firstSegment).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstEqualIndex = first.firstIndex(of: "=") else {
            return nil
        }

        let name = String(first[..<firstEqualIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let valueStartIndex = first.index(after: firstEqualIndex)
        let value = String(first[valueStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return nil
        }

        var domain: String? = responseURL.host
        var path: String? = "/"
        var expires: Date?
        var isSecure = false
        var isHTTPOnly = false

        if segments.count > 1 {
            for segmentIndex in 1..<segments.count {
                let rawAttribute = String(segments[segmentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                if rawAttribute.isEmpty {
                    continue
                }

                let lowercasedAttribute = rawAttribute.lowercased()
                if lowercasedAttribute == "secure" {
                    isSecure = true
                    continue
                }
                if lowercasedAttribute == "httponly" {
                    isHTTPOnly = true
                    continue
                }

                guard let equalIndex = rawAttribute.firstIndex(of: "=") else {
                    continue
                }
                let key = String(rawAttribute[..<equalIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let valueIndex = rawAttribute.index(after: equalIndex)
                let attributeValue = String(rawAttribute[valueIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if attributeValue.isEmpty {
                    continue
                }

                if key == "domain" {
                    // Preserve "Domain=" semantics as subdomain-capable for matching.
                    domain = attributeValue.hasPrefix(".") ? attributeValue : "." + attributeValue
                } else if key == "path" {
                    path = attributeValue
                } else if key == "max-age", let maxAgeSeconds = Int(attributeValue) {
                    expires = Date(timeIntervalSinceNow: TimeInterval(maxAgeSeconds))
                }
            }
        }

        return WebCookie(
            name: name,
            value: value,
            domain: domain,
            path: path,
            expires: expires,
            isSecure: isSecure,
            isHTTPOnly: isHTTPOnly
        )
    }

    fileprivate var normalizedDomain: String? {
        guard let domain else {
            return nil
        }
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return nil
        }
        if trimmed.hasPrefix(".") {
            let start = trimmed.index(after: trimmed.startIndex)
            let stripped = String(trimmed[start...])
            return stripped.isEmpty ? nil : stripped
        }
        return trimmed
    }

    fileprivate var isHostOnlyDomain: Bool {
        // A leading dot indicates explicit subdomain matching semantics.
        guard let domain else {
            return false
        }
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        return !trimmed.hasPrefix(".")
    }

    fileprivate var normalizedCookiePath: String {
        guard let rawPath = path?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            return "/"
        }
        if rawPath.hasPrefix("/") {
            return rawPath
        }
        return "/" + rawPath
    }

    fileprivate func normalizedRequestPath(_ requestPath: String) -> String {
        if requestPath.isEmpty {
            return "/"
        }
        if requestPath.hasPrefix("/") {
            return requestPath
        }
        return "/" + requestPath
    }

    fileprivate func requestPathMatchesCookiePath(_ requestPath: String, cookiePath: String) -> Bool {
        // Follow cookie path-match rules so sibling prefixes are not accepted.
        if requestPath == cookiePath {
            return true
        }
        if !requestPath.hasPrefix(cookiePath) {
            return false
        }
        if cookiePath.hasSuffix("/") {
            return true
        }
        let boundaryIndex = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return boundaryIndex < requestPath.endIndex && requestPath[boundaryIndex] == "/"
    }

    fileprivate func androidTargetURL(requestURL: URL?) -> URL? {
        if let requestURL {
            return requestURL
        }
        guard let domain = normalizedDomain, !domain.isEmpty else {
            return nil
        }
        let normalizedPath = normalizedCookiePath
        return URL(string: "https://\(domain)\(normalizedPath)")
    }

    fileprivate func asAndroidSetCookieString(requestURL: URL?) throws -> String {
        if name.isEmpty {
            throw WebCookieError.invalidCookieName
        }

        var cookieParts: [String] = ["\(name)=\(value)"]
        if let domain = normalizedDomain, !domain.isEmpty {
            cookieParts.append("Domain=\(domain)")
        } else if let fallbackDomain = requestURL?.host?.lowercased(), !fallbackDomain.isEmpty {
            cookieParts.append("Domain=\(fallbackDomain)")
        } else {
            throw WebCookieError.missingCookieDomain
        }

        cookieParts.append("Path=\(normalizedCookiePath)")

        if let expires {
            let maxAge = max(0, Int(expires.timeIntervalSinceNow.rounded()))
            cookieParts.append("Max-Age=\(maxAge)")
        }
        if isSecure {
            cookieParts.append("Secure")
        }
        if isHTTPOnly {
            cookieParts.append("HttpOnly")
        }
        return cookieParts.joined(separator: "; ")
    }
}

#if !SKIP
extension WebCookie {
    fileprivate init(nativeCookie: HTTPCookie) {
        self.init(
            name: nativeCookie.name,
            value: nativeCookie.value,
            domain: nativeCookie.domain,
            path: nativeCookie.path,
            expires: nativeCookie.expiresDate,
            isSecure: nativeCookie.isSecure,
            isHTTPOnly: nativeCookie.isHTTPOnly
        )
    }

    fileprivate func asNativeCookie(requestURL: URL?) throws -> HTTPCookie {
        if name.isEmpty {
            throw WebCookieError.invalidCookieName
        }
        // Preserve an explicit leading-dot domain so domain cookies keep subdomain scope.
        let explicitDomain = domain?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fallbackDomain = requestURL?.host?.lowercased()
        guard let effectiveDomain = (explicitDomain?.isEmpty == false ? explicitDomain : nil) ?? fallbackDomain, !effectiveDomain.isEmpty else {
            throw WebCookieError.missingCookieDomain
        }

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: effectiveDomain,
            .path: normalizedCookiePath
        ]
        if let expires {
            properties[.expires] = expires
        }
        if isSecure {
            properties[.secure] = "TRUE"
        }
        if isHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }

        guard let nativeCookie = HTTPCookie(properties: properties) else {
            throw WebCookieError.invalidCookie
        }
        return nativeCookie
    }
}
#endif

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
    /// The latest content-blocker setup errors observed by this engine.
    ///
    /// On iOS this is populated after asynchronous content-blocker preparation completes.
    public private(set) var contentBlockerSetupErrors: [WebContentBlockerError] = []
    #if !SKIP
    public override var description: String {
        "WebEngine: \(webView)"
    }
    private var observers: [NSKeyValueObservation] = []
    private var profileSetupError: WebProfileError?
    private var iosContentBlockerSetupTask: Task<[WebContentBlockerError], Never>?
    #else
    private var profileSetupError: WebProfileError?
    private var androidProfileCookieManager: android.webkit.CookieManager?
    private var androidProfileWebStorage: android.webkit.WebStorage?
    fileprivate lazy var androidContentBlockerController = AndroidContentBlockerController(config: configuration)
    private lazy var androidInternalWebViewClient = AndroidEngineWebViewClient(engine: self)
    private var androidEmbeddedNavigationClient: android.webkit.WebViewClient?
    private var androidLegacyNavigationDelegate: WebEngineDelegate?
    private var androidPendingPageLoadCallbacks: [UUID: (Result<Void, Error>) -> Void] = [:]
    private var androidScriptMessageFacadeHandler: ScriptHandler?
    private var androidUserScriptHandlers: [ScriptHandler] = []
    #endif

    /// Create a WebEngine with the specified configuration.
    /// - Parameters:
    ///   - configuration: the configuration to use
    ///   - webView: when set, the given platform-specific web view will
    public init(configuration: WebEngineConfiguration = WebEngineConfiguration(), webView: PlatformWebView? = nil) {
        self.configuration = configuration

        #if !SKIP
        if let webView {
            self.webView = webView
        } else {
            self.webView = WKWebView(frame: .zero, configuration: configuration.makeBaseWebViewConfiguration())
        }
        if case .named = configuration.profile, configuration.profile.normalizedNamedIdentifier == nil {
            self.profileSetupError = .invalidProfileName
        }
        #else
        let suppliedAndroidWebViewClient = webView?.webViewClient
        // fall back to using the global android context if the activity context is not set in the configuration
        self.webView = webView ?? PlatformWebView(configuration.context ?? ProcessInfo.processInfo.androidContext)
        switch Self.configureAndroidProfile(configuration.profile, for: self.webView) {
        case .success(let androidProfileResources):
            self.androidProfileCookieManager = androidProfileResources.cookieManager
            self.androidProfileWebStorage = androidProfileResources.webStorage
            self.configuration.androidResolvedProfile = androidProfileResources.resolvedProfile
            self.profileSetupError = nil
        case .failure(let error):
            self.configuration.androidResolvedProfile = nil
            self.profileSetupError = error
        }
        if let suppliedAndroidWebViewClient,
           !(suppliedAndroidWebViewClient is AndroidEngineWebViewClient) {
            setAndroidEmbeddedNavigationClient(suppliedAndroidWebViewClient)
        }
        self.webView.webViewClient = androidInternalWebViewClient
        #endif

        super.init()

        #if !SKIP
        scheduleIOSContentBlockerSetupIfNeeded()
        #endif
    }

    public func reload() {
        if profileSetupError != nil {
            return
        }
        #if !SKIP
        runAfterIOSContentBlockerSetupIfNeeded { [webView] in
            webView.reload()
        }
        #else
        #if SKIP
        prepareAndroidContentBlockersForPendingMainFrameNavigation(targetURL: url)
        #endif
        webView.reload()
        #endif
    }

    public func stopLoading() {
        if profileSetupError != nil {
            return
        }
        webView.stopLoading()
    }

    public func go(to item: WebHistoryItem) {
        if profileSetupError != nil {
            return
        }
        #if !SKIP
        webView.go(to: item.item)
        #else
        // TODO: there's no "go" equivalent in WebView, so we'll probably need to use `goBackOrForward(int steps)` based on matching the item in the back/forward list
        #endif
    }

    public func goBack() {
        if profileSetupError != nil {
            return
        }
        #if !SKIP
        runAfterIOSContentBlockerSetupIfNeeded { [webView] in
            webView.goBack()
        }
        #else
        #if SKIP
        prepareAndroidContentBlockersForPendingMainFrameNavigation(targetURL: pendingHistoryNavigationURL(offset: -1))
        #endif
        webView.goBack()
        #endif
    }

    public func goForward() {
        if profileSetupError != nil {
            return
        }
        #if !SKIP
        runAfterIOSContentBlockerSetupIfNeeded { [webView] in
            webView.goForward()
        }
        #else
        #if SKIP
        prepareAndroidContentBlockersForPendingMainFrameNavigation(targetURL: pendingHistoryNavigationURL(offset: 1))
        #endif
        webView.goForward()
        #endif
    }

    /// Preferred URL accessor for parity with `WKWebView.url`.
    /// A typed `URL` keeps call sites aligned with Apple WebKit ergonomics.
    public var url: URL? {
        #if SKIP
        guard let raw = webView.getUrl() else {
            return nil
        }
        return URL(string: raw)
        #else
        webView.url
        #endif
    }

    #if SKIP
    private func prepareAndroidContentBlockersForPendingMainFrameNavigation(targetURL: URL?) {
        guard let targetURL else {
            return
        }
        androidContentBlockerController.prepare(for: targetURL, in: webView)
    }

    private func pendingHistoryNavigationURL(offset: Int) -> URL? {
        let historyList = webView.copyBackForwardList()
        guard let targetIndex = Self.androidHistoryNavigationIndex(
            currentIndex: historyList.currentIndex,
            size: historyList.size,
            offset: offset
        ) else {
            return nil
        }

        let targetItem = historyList.getItemAtIndex(targetIndex)
        return URL(string: targetItem.getUrl()) ?? URL(string: targetItem.getOriginalUrl())
    }

    static func androidHistoryNavigationIndex(currentIndex: Int, size: Int, offset: Int) -> Int? {
        let targetIndex = currentIndex + offset
        guard targetIndex >= 0, targetIndex < size else {
            return nil
        }
        return targetIndex
    }

    func setAndroidEmbeddedNavigationClient(_ client: android.webkit.WebViewClient?) {
        androidEmbeddedNavigationClient = client
        androidInternalWebViewClient.embeddedNavigationClient = client
    }

    func setAndroidLegacyNavigationDelegate(_ delegate: WebEngineDelegate?) {
        androidLegacyNavigationDelegate = delegate
        androidInternalWebViewClient.legacyNavigationDelegate = delegate
    }

    func completeAndroidPageLoad(_ result: Result<Void, Error>) {
        let callbacks = androidPendingPageLoadCallbacks.values
        androidPendingPageLoadCallbacks.removeAll()
        for callback in callbacks {
            callback(result)
        }
    }

    var androidNavigationDelegate: (any SkipWebNavigationDelegate)? {
        configuration.navigationDelegate
    }
    #endif

    /// Evaluates the given JavaScript string and returns the resulting JSON string, which may be a top-level fragment
    public func evaluate(js: String) async throws -> String? {
        try throwProfileSetupErrorIfNeeded()
        return try await evaluateJavaScriptAsync(js)
    }

    static func androidRemovalBuckets(for types: Set<WebSiteDataType>) -> Set<WebDataRemovalBucket> {
        var buckets = Set<WebDataRemovalBucket>()
        for type in types {
            buckets.insert(type.androidRemovalBucket)
        }
        return buckets
    }

    static func profileValidationError(for profile: WebProfile) -> WebProfileError? {
        WebProfilePolicy.validationError(for: profile)
    }

    private func throwProfileSetupErrorIfNeeded() throws {
        if let profileSetupError {
            throw profileSetupError
        }
    }

    /// Waits for any pending content-blocker setup work and returns the resulting errors.
    ///
    /// This matters mainly on iOS, where rule-list compilation and installation can happen
    /// asynchronously after engine creation.
    public func awaitContentBlockerSetup() async -> [WebContentBlockerError] {
        #if !SKIP
        if let iosContentBlockerSetupTask {
            let errors = await iosContentBlockerSetupTask.value
            contentBlockerSetupErrors = errors
            return errors
        }
        #endif
        return contentBlockerSetupErrors
    }

    #if SKIP
    struct AndroidProfileResources {
        let cookieManager: android.webkit.CookieManager?
        let webStorage: android.webkit.WebStorage?
        let resolvedProfile: WebProfile?
    }

    public static func isAndroidMultiProfileSupported() -> Bool {
        WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
    }

    public static func isAndroidDocumentStartScriptSupported() -> Bool {
        WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
    }

    func installAndroidScriptMessageFacadeIfNeeded() {
        guard androidScriptMessageFacadeHandler == nil,
              !configuration.allRegisteredMessageHandlerNames.isEmpty,
              Self.isAndroidDocumentStartScriptSupported() else {
            return
        }

        let allowedOriginRules: kotlin.collections.MutableSet<String> = kotlin.collections.HashSet()
        allowedOriginRules.add("*")
        let script = Self.androidScriptMessageFacadeScript()
        // SKIP INSERT: try {
        // SKIP INSERT:     androidScriptMessageFacadeHandler = androidx.webkit.WebViewCompat.addDocumentStartJavaScript(webView, script, allowedOriginRules)
        // SKIP INSERT: } catch (t: Throwable) {
        // SKIP INSERT:     logger.warning("Skipping Android script message document-start registration: ${t.message ?: t}")
        // SKIP INSERT: }
        androidScriptMessageFacadeHandler = WebViewCompat.addDocumentStartJavaScript(webView, script, allowedOriginRules)
    }

    func installAndroidDocumentStartUserScriptsIfNeeded() {
        guard androidUserScriptHandlers.isEmpty,
              !configuration.userScripts.isEmpty,
              Self.isAndroidDocumentStartScriptSupported() else {
            return
        }

        for userScript in configuration.userScripts {
            let allowedOriginRules: kotlin.collections.MutableSet<String> = kotlin.collections.HashSet()
            allowedOriginRules.add("*")
            let script = Self.androidDocumentStartUserScriptSource(for: userScript)
            // SKIP INSERT: try {
            // SKIP INSERT:     androidUserScriptHandlers.append(androidx.webkit.WebViewCompat.addDocumentStartJavaScript(webView, script, allowedOriginRules))
            // SKIP INSERT: } catch (t: Throwable) {
            // SKIP INSERT:     logger.warning("Skipping Android user-script document-start registration: ${t.message ?: t}")
            // SKIP INSERT: }
            androidUserScriptHandlers.append(WebViewCompat.addDocumentStartJavaScript(webView, script, allowedOriginRules))
        }
    }

    static func androidDocumentStartUserScriptSource(for userScript: WebViewUserScript) -> String {
        var source = userScript.webKitUserScript.source
        if userScript.webKitUserScript.injectionTime == .atDocumentEnd {
            source = """
            (function () {
              var skipWebRunUserScript = function () {
                \(source)
              };
              if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", skipWebRunUserScript, { once: true });
              } else {
                skipWebRunUserScript();
              }
            })();
            """
        }

        if userScript.webKitUserScript.isForMainFrameOnly {
            source = """
            (function () {
              if (window.top !== window.self) { return; }
              \(source)
            })();
            """
        }
        return source
    }

    static func androidScriptMessageFacadeScript() -> String {
        """
        (function () {
          if (!window.webkit) window.webkit = {};
          window.webkit.messageHandlers = new Proxy(window.webkit.messageHandlers || {}, {
            get: function (target, messageHandlerName) {
              if (target && target[messageHandlerName]) { return target[messageHandlerName]; }
              return {
                postMessage: function (body) {
                  var bodyJSON = JSON.stringify(body);
                  if (bodyJSON === undefined) { bodyJSON = "null"; }
                  var sourceURL = "";
                  var isMainFrame = false;
                  try { sourceURL = window.location.href || ""; } catch (e) {}
                  try { isMainFrame = window.top === window.self; } catch (e) {}
                  skipWebAndroidMessageHandler.postMessage(String(messageHandlerName), bodyJSON, sourceURL, isMainFrame);
                }
              };
            }
          });
        })();
        """
    }

    private static func configureAndroidProfile(_ profile: WebProfile, for webView: PlatformWebView) -> Result<AndroidProfileResources, WebProfileError> {
        if let supportError = androidProfileSupportError(for: profile, isMultiProfileFeatureSupported: isAndroidMultiProfileSupported()) {
            return .failure(supportError)
        }

        switch profile {
        case .default:
            return .success(AndroidProfileResources(cookieManager: nil, webStorage: nil, resolvedProfile: .default))
        case .ephemeral:
            let identifier = androidEphemeralProfileIdentifier()
            guard applyAndroidProfile(identifier, to: webView) else {
                return .failure(.profileSetupFailed)
            }
            let profile = WebViewCompat.getProfile(webView)
            return .success(
                AndroidProfileResources(
                    cookieManager: profile.getCookieManager(),
                    webStorage: profile.getWebStorage(),
                    resolvedProfile: .named(identifier)
                )
            )
        case .named:
            guard let identifier = profile.normalizedNamedIdentifier else {
                return .failure(.invalidProfileName)
            }
            guard applyAndroidProfile(identifier, to: webView) else {
                return .failure(.profileSetupFailed)
            }
            let profile = WebViewCompat.getProfile(webView)
            return .success(
                AndroidProfileResources(
                    cookieManager: profile.getCookieManager(),
                    webStorage: profile.getWebStorage(),
                    resolvedProfile: .named(identifier)
                )
            )
        }
    }

    static func androidProfileSupportError(for profile: WebProfile, isMultiProfileFeatureSupported: Bool) -> WebProfileError? {
        WebProfilePolicy.androidSupportError(
            for: profile,
            isMultiProfileFeatureSupported: isMultiProfileFeatureSupported
        )
    }

    @discardableResult
    func inheritAndroidProfile(from parentConfiguration: WebEngineConfiguration) -> WebProfileError? {
        inheritAndroidProfile(from: parentConfiguration.androidResolvedProfile ?? parentConfiguration.profile)
    }

    @discardableResult
    func inheritAndroidProfile(from parentProfile: WebProfile) -> WebProfileError? {
        if configuration.profile == parentProfile, profileSetupError == nil {
            return nil
        }
        configuration.profile = parentProfile
        switch Self.configureAndroidProfile(parentProfile, for: webView) {
        case .success(let androidProfileResources):
            self.androidProfileCookieManager = androidProfileResources.cookieManager
            self.androidProfileWebStorage = androidProfileResources.webStorage
            self.configuration.androidResolvedProfile = androidProfileResources.resolvedProfile
            self.profileSetupError = nil
            return nil
        case .failure(let error):
            self.configuration.androidResolvedProfile = nil
            self.profileSetupError = error
            return error
        }
    }

    private static func androidEphemeralProfileIdentifier() -> String {
        "skipweb-ephemeral-\(UUID().uuidString)"
    }

    private static func applyAndroidProfile(_ identifier: String, to webView: PlatformWebView) -> Bool {
        // SKIP INSERT: try { androidx.webkit.WebViewCompat.setProfile(webView, identifier); return true } catch (t: Throwable) { return false }
        WebViewCompat.setProfile(webView, identifier)
        return true
    }

    private func androidCookieManager() -> android.webkit.CookieManager {
        androidProfileCookieManager ?? android.webkit.CookieManager.getInstance()
    }

    private func androidWebStorage() -> android.webkit.WebStorage {
        androidProfileWebStorage ?? android.webkit.WebStorage.getInstance()
    }
    #else
    private func scheduleIOSContentBlockerSetupIfNeeded() {
        guard iosContentBlockerSetupTask == nil else {
            return
        }
        guard configuration.contentBlockers?.iOSRuleListPaths.isEmpty == false else {
            return
        }

        let userContentController = webView.configuration.userContentController
        iosContentBlockerSetupTask = Task { @MainActor [configuration, weak self] in
            let errors = await configuration.installPreparedContentBlockers(into: userContentController)
            self?.contentBlockerSetupErrors = errors
            return errors
        }
    }

    private func runAfterIOSContentBlockerSetupIfNeeded(_ operation: @escaping @MainActor () -> Void) {
        if let iosContentBlockerSetupTask {
            Task { @MainActor in
                _ = await iosContentBlockerSetupTask.value
                operation()
            }
        } else {
            operation()
        }
    }
    #endif

    static func androidRemovalBucketNames(for types: Set<WebSiteDataType>) -> Set<String> {
        var names = Set<String>()
        for bucket in androidRemovalBuckets(for: types) {
            switch bucket {
            case .cookies:
                names.insert("cookies")
            case .cache:
                names.insert("cache")
            case .storage:
                names.insert("storage")
            }
        }
        return names
    }

    #if !SKIP
    static func webKitDataTypes(for types: Set<WebSiteDataType>) -> Set<String> {
        var mapped = Set<String>()
        for type in types {
            mapped.insert(type.webKitDataType)
        }
        return mapped
    }
    #endif

    public func cookies(for url: URL) async -> [WebCookie] {
        if profileSetupError != nil {
            return []
        }
        #if !SKIP
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let allCookies = await getAllCookies(from: store)
        var filtered: [WebCookie] = []
        for nativeCookie in allCookies {
            let webCookie = WebCookie(nativeCookie: nativeCookie)
            if webCookie.matches(url: url) {
                filtered.append(webCookie)
            }
        }
        return filtered
        #else
        let cookieHeader = androidCookieManager().getCookie(url.absoluteString) ?? ""
        if cookieHeader.isEmpty {
            return []
        }
        return WebCookie.parseRequestCookieHeader(cookieHeader)
        #endif
    }

    public func cookieHeader(for url: URL) async -> String? {
        if profileSetupError != nil {
            return nil
        }
        #if !SKIP
        let matchingCookies = await cookies(for: url)
        if matchingCookies.isEmpty {
            return nil
        }
        var cookiePairs: [String] = []
        for cookie in matchingCookies {
            cookiePairs.append("\(cookie.name)=\(cookie.value)")
        }
        return cookiePairs.joined(separator: "; ")
        #else
        let cookieHeader = androidCookieManager().getCookie(url.absoluteString) ?? ""
        return cookieHeader.isEmpty ? nil : cookieHeader
        #endif
    }

    public func setCookie(_ cookie: WebCookie, requestURL: URL? = nil) async throws {
        try throwProfileSetupErrorIfNeeded()
        #if !SKIP
        let nativeCookie = try cookie.asNativeCookie(requestURL: requestURL)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        await setCookie(nativeCookie, in: store)
        #else
        let targetURL = cookie.androidTargetURL(requestURL: requestURL)
        guard let targetURL else {
            throw WebCookieError.missingCookieDomain
        }
        let cookieString = try cookie.asAndroidSetCookieString(requestURL: requestURL)
        let cookieManager = androidCookieManager()
        await setAndroidCookie(cookieManager, forURLString: targetURL.absoluteString, cookieString: cookieString)
        #endif
    }

    public func applySetCookieHeaders(_ headers: [String], for responseURL: URL) async throws {
        try throwProfileSetupErrorIfNeeded()
        #if !SKIP
        let parsedCookies = WebCookie.parseSetCookieHeaders(headers, responseURL: responseURL)
        for cookie in parsedCookies {
            try await setCookie(cookie, requestURL: responseURL)
        }
        #else
        let cookieManager = androidCookieManager()
        let targetURLString = responseURL.absoluteString
        for header in headers {
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            await setAndroidCookie(cookieManager, forURLString: targetURLString, cookieString: trimmed)
        }
        #endif
    }

    public func clearCookies() async {
        if profileSetupError != nil {
            return
        }
        #if !SKIP
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let allCookies = await getAllCookies(from: store)
        for cookie in allCookies {
            await deleteCookie(cookie, from: store)
        }
        #else
        let cookieManager = androidCookieManager()
        await removeAllAndroidCookies(cookieManager)
        #endif
    }

    @MainActor
    public func removeData(ofTypes types: Set<WebSiteDataType>, modifiedSince: Date) async throws {
        try throwProfileSetupErrorIfNeeded()
        if types.isEmpty {
            return
        }

        #if !SKIP
        let webKitTypes = Self.webKitDataTypes(for: types)
        if webKitTypes.isEmpty {
            return
        }
        await removeData(
            from: webView.configuration.websiteDataStore,
            ofTypes: webKitTypes,
            modifiedSince: modifiedSince
        )
        #else
        if modifiedSince != .distantPast {
            throw WebDataRemovalError.unsupportedModifiedSinceOnAndroid
        }

        let buckets = Self.androidRemovalBuckets(for: types)
        if buckets.contains(.cookies) {
            await removeAllAndroidCookies(androidCookieManager())
        }
        if buckets.contains(.cache) {
            webView.clearCache(true)
        }
        if buckets.contains(.storage) {
            androidWebStorage().deleteAllData()
        }
        #endif
    }

    @MainActor public func takeSnapshot(configuration: SkipWebSnapshotConfiguration? = nil) async throws -> SkipWebSnapshot {
        try throwProfileSetupErrorIfNeeded()
        let config = configuration ?? SkipWebSnapshotConfiguration()

        #if !SKIP
        let platformConfig = WKSnapshotConfiguration()
        platformConfig.rect = config.rect.asCGRect
        if let snapshotWidth = config.snapshotWidth {
            platformConfig.snapshotWidth = NSNumber(value: snapshotWidth)
        }
        platformConfig.afterScreenUpdates = config.afterScreenUpdates

        let snapshotImage = try await webView.takeSnapshot(configuration: platformConfig)
        guard let pngData = snapshotImage.pngData() else {
            throw WebSnapshotError.pngEncodingFailed
        }

        let pixelWidth = Int(snapshotImage.size.width * snapshotImage.scale)
        let pixelHeight = Int(snapshotImage.size.height * snapshotImage.scale)
        return SkipWebSnapshot(
            pngData: pngData,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        #else
        let sourceWidth = Int(webView.getWidth())
        let sourceHeight = Int(webView.getHeight())
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw WebSnapshotError.viewNotLaidOut
        }

        if config.afterScreenUpdates {
            let didScheduleUIUpdateWait: Bool = suspendCancellableCoroutine { continuation in
                let scheduled = webView.post {
                    continuation.resume(true)
                }
                guard scheduled else {
                    continuation.resume(false)
                    return
                }
                continuation.invokeOnCancellation { _ in
                    continuation.cancel()
                }
            }
            guard didScheduleUIUpdateWait else {
                throw WebSnapshotError.afterScreenUpdatesUnavailable
            }
        }

        let fullRect = CGRect(x: 0.0, y: 0.0, width: CGFloat(sourceWidth), height: CGFloat(sourceHeight))
        let requestedRect = config.rect.isNull ? fullRect : config.rect.asCGRect
        let clampedRect = requestedRect.intersection(fullRect)
        let minX = max(0, Int(floor(clampedRect.minX)))
        let minY = max(0, Int(floor(clampedRect.minY)))
        let maxX = min(sourceWidth, Int(ceil(clampedRect.maxX)))
        let maxY = min(sourceHeight, Int(ceil(clampedRect.maxY)))
        let captureWidth = maxX - minX
        let captureHeight = maxY - minY
        guard captureWidth > 0, captureHeight > 0 else {
            throw WebSnapshotError.invalidRect
        }

        let targetWidth: Int
        if let snapshotWidth = config.snapshotWidth {
            guard snapshotWidth > 0 else {
                throw WebSnapshotError.invalidRect
            }
            targetWidth = max(1, Int(snapshotWidth.rounded()))
        } else {
            targetWidth = captureWidth
        }
        let targetHeight = max(1, Int((Double(captureHeight) * (Double(targetWidth) / Double(captureWidth))).rounded()))

        let bitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
        let canvas = Canvas(bitmap)
        let scaleX = Float(Double(targetWidth) / Double(captureWidth))
        let scaleY = Float(Double(targetHeight) / Double(captureHeight))
        let scrollX = Int(webView.getScrollX())
        let scrollY = Int(webView.getScrollY())
        canvas.scale(scaleX, scaleY)
        // Android WebView drawing is offset by the current scroll position,
        // so we must compensate or the snapshot is padded by blank space.
        canvas.translate(-Float(minX + scrollX), -Float(minY + scrollY))
        webView.draw(canvas)

        let outputStream = java.io.ByteArrayOutputStream()
        let encoded = bitmap.compress(Bitmap.CompressFormat.PNG, 100, outputStream)
        bitmap.recycle()
        guard encoded else {
            throw WebSnapshotError.pngEncodingFailed
        }

        let base64 = android.util.Base64.encodeToString(outputStream.toByteArray(), android.util.Base64.NO_WRAP)
        guard let pngData: Data = Data(base64Encoded: base64, options: []) else {
            throw WebSnapshotError.pngEncodingFailed
        }
        return SkipWebSnapshot(
            pngData: pngData,
            pixelWidth: targetWidth,
            pixelHeight: targetHeight
        )
        #endif
    }

    public func loadHTML(_ html: String, baseURL: URL? = nil, mimeType: String = "text/html") {
        if profileSetupError != nil {
            return
        }
        logger.info("loadHTML webView: \(self.description)")
        let encoding: String = "UTF-8"
        #if SKIP
        let cosmeticPageURL = baseURL ?? URL(string: "about:blank")!
        androidContentBlockerController.prepare(for: cosmeticPageURL, in: webView)
        #endif

        #if SKIP
        // see https://developer.android.com/reference/android/webkit/WebView#loadDataWithBaseURL(java.lang.String,%20java.lang.String,%20java.lang.String,%20java.lang.String,%20java.lang.String)
        let baseUrl: String? = baseURL?.absoluteString // the URL to use as the page's base URL. If null defaults to 'about:blank'
        //var htmlContent = android.util.Base64.encodeToString(html.toByteArray(), android.util.Base64.NO_PADDING)
        var htmlContent = html
        let historyUrl: String? = nil // the URL to use as the history entry. If null defaults to 'about:blank'. If non-null, this must be a valid URL.
        webView.loadDataWithBaseURL(baseUrl, htmlContent, mimeType, encoding, historyUrl)
        #else
        runAfterIOSContentBlockerSetupIfNeeded { [weak self] in
            guard let self else {
                return
            }
            self.refreshMessageHandlers()
            self.webView.load(Data(html.utf8), mimeType: mimeType, characterEncodingName: encoding, baseURL: baseURL ?? URL(string: "about:blank")!)
        }
        #endif
    }

    /// Asyncronously load the given URL, returning once the page has been loaded or an error has occurred
    public func load(url: URL) async throws {
        try throwProfileSetupErrorIfNeeded()
        let urlString = url.absoluteString
        logger.info("load URL=\(urlString) webView: \(self.description)")
        #if SKIP
        androidContentBlockerController.prepare(for: url, in: webView)
        #else
        _ = await awaitContentBlockerSetup()
        #endif
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
        let evaluated: Any? = try await webView.evaluateJavaScript(script) // cast needed for older iOS, or else: "error: initializer for conditional binding must have Optional type, not 'Any'"
        guard let result = evaluated else {
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

    #if !SKIP
    private func getAllCookies(from cookieStore: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func setCookie(_ cookie: HTTPCookie, in cookieStore: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            cookieStore.setCookie(cookie) {
                continuation.resume(returning: ())
            }
        }
    }

    private func deleteCookie(_ cookie: HTTPCookie, from cookieStore: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            cookieStore.delete(cookie) {
                continuation.resume(returning: ())
            }
        }
    }

    private func removeData(from dataStore: WKWebsiteDataStore, ofTypes types: Set<String>, modifiedSince: Date) async {
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: types, modifiedSince: modifiedSince) {
                continuation.resume(returning: ())
            }
        }
    }
    #else
    nonisolated private func setAndroidCookie(
        _ cookieManager: android.webkit.CookieManager,
        forURLString urlString: String,
        cookieString: String
    ) async {
        cookieManager.setCookie(urlString, cookieString, nil)
        cookieManager.flush()
        // Android cookie writes are asynchronous; a short delay avoids racing immediate reads.
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    nonisolated private func removeAllAndroidCookies(_ cookieManager: android.webkit.CookieManager) async {
        cookieManager.removeAllCookies(nil)
        cookieManager.flush()
        // Mirror setCookie behavior: allow async cookie-store mutation to settle before reads.
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    #endif

    #if SKIP
    fileprivate static func androidRequestHeaders(from request: android.webkit.WebResourceRequest) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in request.requestHeaders {
            headers[String(describing: key)] = String(describing: value)
        }
        return headers
    }

    fileprivate static func androidMainDocumentURL(
        for request: android.webkit.WebResourceRequest,
        requestURL: URL,
        headers: [String: String]
    ) -> URL? {
        if request.isForMainFrame {
            return requestURL
        }

        // `shouldInterceptRequest` runs off the UI thread on Android, so avoid touching
        // the backing WebView for its current URL here.
        let lowercaseHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        if let referer = lowercaseHeaders["referer"], let refererURL = URL(string: referer) {
            return refererURL
        }
        if let origin = lowercaseHeaders["origin"], let originURL = URL(string: origin) {
            return originURL
        }
        return nil
    }

    fileprivate static func androidResourceTypeHint(
        for request: android.webkit.WebResourceRequest,
        requestURL: URL,
        headers: [String: String]
    ) -> AndroidResourceTypeHint {
        if request.isForMainFrame {
            return .document
        }

        let lowercaseHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value.lowercased()) })
        if let secFetchDest = lowercaseHeaders["sec-fetch-dest"] {
            switch secFetchDest {
            case "document":
                return .document
            case "iframe", "frame":
                return .subdocument
            case "style":
                return .stylesheet
            case "script":
                return .script
            case "image":
                return .image
            case "font":
                return .font
            case "audio", "video":
                return .media
            case "empty":
                if let requestedWith = lowercaseHeaders["x-requested-with"], requestedWith == "xmlhttprequest" {
                    return .xhr
                }
                return .fetch
            default:
                break
            }
        }

        if let accept = lowercaseHeaders["accept"] {
            if accept.contains("text/css") {
                return .stylesheet
            }
            if accept.contains("javascript") || accept.contains("ecmascript") {
                return .script
            }
            if accept.contains("image/") {
                return .image
            }
            if accept.contains("font/") {
                return .font
            }
            if accept.contains("video/") || accept.contains("audio/") {
                return .media
            }
            if accept.contains("text/html") {
                return .subdocument
            }
        }

        switch requestURL.pathExtension.lowercased() {
        case "css":
            return .stylesheet
        case "js", "mjs", "cjs":
            return .script
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "avif":
            return .image
        case "woff", "woff2", "ttf", "otf":
            return .font
        case "mp4", "webm", "mov", "m4v", "mp3", "wav", "ogg", "m4a":
            return .media
        case "html", "htm":
            return .subdocument
        default:
            break
        }

        return .other
    }

    fileprivate static func blockedAndroidResponse() -> android.webkit.WebResourceResponse {
        let responseHeaders: kotlin.collections.Map<String, String> = kotlin.collections.HashMap()
        return android.webkit.WebResourceResponse(
            "text/plain",
            "utf-8",
            204,
            "No Content",
            responseHeaders,
            "".byteInputStream()
        )
    }

    static func androidRedirectFlag(
        isRedirectFeatureSupported: Bool = WebViewFeature.isFeatureSupported(WebViewFeature.WEB_RESOURCE_REQUEST_IS_REDIRECT),
        resolveRedirect: () -> Bool
    ) -> Bool? {
        guard isRedirectFeatureSupported else {
            return nil
        }
        return resolveRedirect()
    }

    fileprivate static func androidRequestIsRedirect(_ request: android.webkit.WebResourceRequest) -> Bool? {
        androidRedirectFlag {
            WebResourceRequestCompat.isRedirect(request)
        }
    }

    fileprivate static func normalizedAndroidCosmeticSelectors(_ hiddenSelectors: [String]) -> [String] {
        AndroidCosmeticRule.normalizedHiddenSelectors(hiddenSelectors)
    }

    fileprivate static func normalizedAndroidCosmeticCSS(_ cssRules: [String]) -> [String] {
        cssRules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    fileprivate static func androidDisplayNoneCSSRules(forSelectors hiddenSelectors: [String]) -> [String] {
        AndroidCosmeticRule.hideCSS(for: hiddenSelectors)
    }

    fileprivate static func normalizedAndroidAllowedOriginRules(_ allowedOriginRules: [String]) -> [String] {
        let normalized = allowedOriginRules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return normalized.isEmpty ? ["*"] : normalized
    }

    fileprivate static func androidDefaultPort(for scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    fileprivate static func androidParsedOriginRule(_ rule: String) -> (scheme: String, host: String?, port: Int?)? {
        let normalizedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separatorRange = normalizedRule.range(of: "://") else {
            return nil
        }

        let scheme = String(normalizedRule[..<separatorRange.lowerBound]).lowercased()
        guard !scheme.isEmpty else {
            return nil
        }
        var authority = String(normalizedRule[separatorRange.upperBound...])
        if let pathStart = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = String(authority[..<pathStart])
        }

        guard !authority.isEmpty else {
            return (scheme, nil, nil)
        }

        if authority.hasPrefix("[") {
            guard let bracketEnd = authority.firstIndex(of: "]") else {
                return nil
            }
            let host = String(authority[authority.index(after: authority.startIndex)..<bracketEnd]).lowercased()
            let remainder = authority[authority.index(after: bracketEnd)...]
            guard !remainder.isEmpty else {
                return (scheme, host, nil)
            }
            guard remainder.first == ":" else {
                return nil
            }
            return (scheme, host, Int(String(remainder.dropFirst())))
        }

        if let colonIndex = authority.lastIndex(of: ":"),
           androidDigitsOnly(String(authority[authority.index(after: colonIndex)...])) {
            let host = String(authority[..<colonIndex]).lowercased()
            return (scheme, host, Int(String(authority[authority.index(after: colonIndex)...])))
        }

        return (scheme, authority.lowercased(), nil)
    }

    fileprivate static func androidDigitsOnly(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        for character in value {
            guard character >= "0" && character <= "9" else {
                return false
            }
        }
        return true
    }

    fileprivate static func androidOriginRule(_ rule: String, matches pageURL: URL) -> Bool {
        let normalizedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRule.isEmpty else {
            return false
        }
        if normalizedRule == "*" {
            return true
        }

        guard
            let parsedRule = androidParsedOriginRule(normalizedRule),
            let pageScheme = pageURL.scheme?.lowercased(),
            parsedRule.scheme == pageScheme
        else {
            return false
        }

        let defaultPort = androidDefaultPort(for: parsedRule.scheme)
        if parsedRule.scheme != "http" && parsedRule.scheme != "https" {
            return parsedRule.host == nil && parsedRule.port == nil
        }

        guard
            let ruleHost = parsedRule.host,
            let pageHost = pageURL.host?.lowercased()
        else {
            return false
        }

        let pagePort = pageURL.port ?? defaultPort
        let rulePort = parsedRule.port ?? defaultPort
        guard pagePort == rulePort else {
            return false
        }

        if ruleHost.hasPrefix("*.") {
            let suffix = String(ruleHost.dropFirst(2))
            return pageHost.hasSuffix(".\(suffix)")
        }

        return pageHost == ruleHost
    }

    fileprivate static func androidAllowedOriginRulesMatchPage(_ allowedOriginRules: [String], pageURL: URL) -> Bool {
        let normalizedRules = normalizedAndroidAllowedOriginRules(allowedOriginRules)
        return normalizedRules.contains { androidOriginRule($0, matches: pageURL) }
    }

    fileprivate static func androidDomainRule(_ rule: String, matchesHost host: String) -> Bool {
        let normalizedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedRule.isEmpty else {
            return false
        }
        if normalizedRule.hasPrefix("*.") {
            let suffix = String(normalizedRule.dropFirst(2))
            guard !suffix.isEmpty else {
                return false
            }
            return host.count > suffix.count && host.hasSuffix(".\(suffix)")
        }
        return host == normalizedRule
    }

    fileprivate static func androidDomainListsMatchPage(
        ifDomainList: [String],
        unlessDomainList: [String],
        pageURL: URL
    ) -> Bool {
        let host = pageURL.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !ifDomainList.isEmpty {
            guard let host else {
                return false
            }
            guard ifDomainList.contains(where: { androidDomainRule($0, matchesHost: host) }) else {
                return false
            }
        }

        if let host,
           unlessDomainList.contains(where: { androidDomainRule($0, matchesHost: host) }) {
            return false
        }

        return true
    }

    fileprivate static func androidURLFilterPatternMatchesPage(_ urlFilterPattern: String?, pageURL: URL) -> Bool {
        guard let urlFilterPattern, !urlFilterPattern.isEmpty else {
            return true
        }

        let pageURLString = pageURL.absoluteString
        #if SKIP
        // SKIP INSERT: try { return kotlin.text.Regex(urlFilterPattern).containsMatchIn(pageURLString) } catch (t: Throwable) { return false }
        return false
        #else
        let range = NSRange(location: 0, length: pageURLString.utf16.count)
        guard let expression = try? NSRegularExpression(pattern: urlFilterPattern) else {
            return false
        }
        return expression.firstMatch(in: pageURLString, range: range) != nil
        #endif
    }

    fileprivate static func appendAndroidDocumentStartRule(
        _ rule: AndroidCosmeticRule,
        to batchedRules: inout [AndroidCosmeticRule],
        indexByKey: inout [AndroidDocumentStartRuleBatchKey: Int]
    ) {
        let key = AndroidDocumentStartRuleBatchKey(
            frameScope: rule.frameScope,
            preferredTiming: rule.preferredTiming,
            urlFilterPattern: rule.urlFilterPattern,
            allowedOriginRules: rule.allowedOriginRules,
            ifDomainList: rule.ifDomainList,
            unlessDomainList: rule.unlessDomainList
        )

        if let matchingIndex = indexByKey[key] {
            batchedRules[matchingIndex].hiddenSelectors.append(contentsOf: rule.hiddenSelectors)
        } else {
            indexByKey[key] = batchedRules.count
            batchedRules.append(rule)
        }
    }

    fileprivate static func androidDocumentStartCosmeticRules(
        rules: [AndroidCosmeticRule],
        isDocumentStartSupported: Bool
    ) -> [AndroidCosmeticRule] {
        guard isDocumentStartSupported else {
            return []
        }

        var batchedRules: [AndroidCosmeticRule] = []
        batchedRules.reserveCapacity(rules.count)
        var indexByKey: [AndroidDocumentStartRuleBatchKey: Int] = [:]

        for rule in rules {
            guard rule.preferredTiming == .documentStart else {
                continue
            }

            let normalizedSelectors = normalizedAndroidCosmeticSelectors(rule.hiddenSelectors)
            guard !normalizedSelectors.isEmpty else {
                continue
            }

            var normalizedRule = rule
            normalizedRule.hiddenSelectors = normalizedSelectors
            normalizedRule.allowedOriginRules = normalizedAndroidAllowedOriginRules(rule.allowedOriginRules)
            appendAndroidDocumentStartRule(
                normalizedRule,
                to: &batchedRules,
                indexByKey: &indexByKey
            )
        }

        return batchedRules
    }

    fileprivate static func androidLifecycleCosmeticCSS(
        rules: [AndroidCosmeticRule],
        pageURL: URL,
        isDocumentStartSupported: Bool,
        log: ((String) -> Void)? = nil
    ) -> [String] {
        var lifecycleCSS: [String] = []

        for rule in rules {
            let normalizedSelectors = normalizedAndroidCosmeticSelectors(rule.hiddenSelectors)
            guard !normalizedSelectors.isEmpty else {
                continue
            }
            let normalizedCSS = androidDisplayNoneCSSRules(forSelectors: normalizedSelectors)

            switch rule.preferredTiming {
            case .documentStart:
                guard !isDocumentStartSupported else {
                    continue
                }

                if rule.frameScope == .mainFrameOnly,
                   androidAllowedOriginRulesMatchPage(rule.allowedOriginRules, pageURL: pageURL),
                   androidDomainListsMatchPage(
                    ifDomainList: rule.ifDomainList,
                    unlessDomainList: rule.unlessDomainList,
                    pageURL: pageURL
                   ),
                   androidURLFilterPatternMatchesPage(rule.urlFilterPattern, pageURL: pageURL) {
                    lifecycleCSS.append(contentsOf: normalizedCSS)
                } else if rule.frameScope == .mainFrameOnly {
                    if !androidAllowedOriginRulesMatchPage(rule.allowedOriginRules, pageURL: pageURL) {
                        log?("Skipping Android cosmetic rule because page origin does not match allowedOriginRules")
                    } else if !androidDomainListsMatchPage(
                        ifDomainList: rule.ifDomainList,
                        unlessDomainList: rule.unlessDomainList,
                        pageURL: pageURL
                    ) {
                        log?("Skipping Android cosmetic rule because page host does not match domain lists")
                    } else {
                        log?("Skipping Android cosmetic rule because page URL does not match urlFilterPattern")
                    }
                } else {
                    log?("Skipping Android cosmetic rule with frameScope=\(rule.frameScope.rawValue) because document-start frame injection is unavailable")
                }
            case .pageLifecycle:
                if rule.frameScope == .mainFrameOnly,
                   androidAllowedOriginRulesMatchPage(rule.allowedOriginRules, pageURL: pageURL),
                   androidDomainListsMatchPage(
                    ifDomainList: rule.ifDomainList,
                    unlessDomainList: rule.unlessDomainList,
                    pageURL: pageURL
                   ),
                   androidURLFilterPatternMatchesPage(rule.urlFilterPattern, pageURL: pageURL) {
                    lifecycleCSS.append(contentsOf: normalizedCSS)
                } else if rule.frameScope == .mainFrameOnly {
                    if !androidAllowedOriginRulesMatchPage(rule.allowedOriginRules, pageURL: pageURL) {
                        log?("Skipping Android cosmetic rule because page origin does not match allowedOriginRules")
                    } else if !androidDomainListsMatchPage(
                        ifDomainList: rule.ifDomainList,
                        unlessDomainList: rule.unlessDomainList,
                        pageURL: pageURL
                    ) {
                        log?("Skipping Android cosmetic rule because page host does not match domain lists")
                    } else {
                        log?("Skipping Android cosmetic rule because page URL does not match urlFilterPattern")
                    }
                } else {
                    log?("Skipping Android cosmetic rule with frameScope=\(rule.frameScope.rawValue) because page-lifecycle injection only supports the main frame")
                }
            }
        }

        return lifecycleCSS
    }

    static func androidCosmeticInjectionPlan(
        rules: [AndroidCosmeticRule],
        pageURL: URL,
        isDocumentStartSupported: Bool,
        log: ((String) -> Void)? = nil
    ) -> AndroidCosmeticInjectionPlan {
        AndroidCosmeticInjectionPlan(
            documentStartRules: androidDocumentStartCosmeticRules(
                rules: rules,
                isDocumentStartSupported: isDocumentStartSupported
            ),
            lifecycleCSS: androidLifecycleCosmeticCSS(
                rules: rules,
                pageURL: pageURL,
                isDocumentStartSupported: isDocumentStartSupported,
                log: log
            )
        )
    }

    static func androidRedirectFallbackCosmeticPlan(
        rules: [AndroidCosmeticRule],
        pageURL: URL,
        log: ((String) -> Void)? = nil
    ) -> AndroidCosmeticInjectionPlan {
        androidCosmeticInjectionPlan(
            rules: rules,
            pageURL: pageURL,
            isDocumentStartSupported: false,
            log: log
        )
    }

    static func androidContentBlockerStyleRemovalScript(styleID: String) -> String {
        let styleIDLiteral = styleID.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (function() {
            var style = document.getElementById("\(styleIDLiteral)");
            if (style) {
                style.remove();
            }
        })();
        """
    }

    static func androidContentBlockerStyleInjectionScript(
        cssRules: [String],
        styleID: String,
        frameScope: AndroidCosmeticFrameScope,
        urlFilterPattern: String? = nil,
        ifDomainList: [String] = [],
        unlessDomainList: [String] = []
    ) -> String? {
        let css = normalizedAndroidCosmeticCSS(cssRules).joined(separator: "\n")
        guard !css.isEmpty else {
            return nil
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: [css], options: []),
            let encoded = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let cssLiteral = String(encoded.dropFirst().dropLast())
        let styleIDLiteral = styleID.replacingOccurrences(of: "\"", with: "\\\"")
        let urlFilterGuard: String
        if let urlFilterPattern, !urlFilterPattern.isEmpty {
            guard
                let patternData = try? JSONSerialization.data(withJSONObject: [urlFilterPattern], options: []),
                let patternEncoded = String(data: patternData, encoding: .utf8)
            else {
                return nil
            }
            let patternLiteral = String(patternEncoded.dropFirst().dropLast())
            urlFilterGuard = """
            try {
                if (!(new RegExp(\(patternLiteral))).test(window.location.href)) { return; }
            } catch (error) {
                return;
            }
            """
        } else {
            urlFilterGuard = ""
        }
        let domainGuard: String
        if !ifDomainList.isEmpty || !unlessDomainList.isEmpty {
            guard
                let ifDomainData = try? JSONSerialization.data(withJSONObject: ifDomainList, options: []),
                let ifDomainEncoded = String(data: ifDomainData, encoding: .utf8),
                let unlessDomainData = try? JSONSerialization.data(withJSONObject: unlessDomainList, options: []),
                let unlessDomainEncoded = String(data: unlessDomainData, encoding: .utf8)
            else {
                return nil
            }
            domainGuard = """
            var currentHost = (window.location.hostname || "").toLowerCase();
            var ifDomainList = \(ifDomainEncoded);
            var unlessDomainList = \(unlessDomainEncoded);
            var domainMatches = function(ruleDomain) {
                if (typeof ruleDomain !== "string") { return false; }
                var normalizedRuleDomain = ruleDomain.trim().toLowerCase();
                if (!normalizedRuleDomain) { return false; }
                if (normalizedRuleDomain.startsWith("*.")) {
                    var suffix = normalizedRuleDomain.slice(2);
                    return !!suffix && currentHost.length > suffix.length && currentHost.endsWith("." + suffix);
                }
                return currentHost === normalizedRuleDomain;
            };
            if (ifDomainList.length > 0) {
                if (!currentHost) { return; }
                if (!ifDomainList.some(domainMatches)) { return; }
            }
            if (currentHost && unlessDomainList.some(domainMatches)) { return; }
            """
        } else {
            domainGuard = ""
        }
        let frameGuard: String
        switch frameScope {
        case .mainFrameOnly:
            frameGuard = "if (window.top !== window.self) { return; }"
        case .subframesOnly:
            frameGuard = "if (window.top === window.self) { return; }"
        case .allFrames:
            frameGuard = ""
        }
        return """
        (function() {
            \(frameGuard)
            \(urlFilterGuard)
            \(domainGuard)
            var styleId = "\(styleIDLiteral)";
            var css = \(cssLiteral);
            var root = document.head || document.documentElement;
            if (!root) { return; }
            var style = document.getElementById(styleId);
            if (!style) {
                style = document.createElement('style');
                style.id = styleId;
                root.appendChild(style);
            }
            style.textContent = css;
        })();
        """
    }

    static func androidContentBlockerBatchedStyleInjectionScript(
        rules: [AndroidCosmeticRule],
        styleID: String
    ) -> String? {
        var serializedRules: [[String: Any]] = []
        serializedRules.reserveCapacity(rules.count)

        for rule in rules {
            let hiddenSelectors = normalizedAndroidCosmeticSelectors(rule.hiddenSelectors)
            guard !hiddenSelectors.isEmpty else {
                continue
            }
            serializedRules.append(
                [
                    "hiddenSelectors": hiddenSelectors,
                    "frameScope": rule.frameScope.rawValue,
                    "urlFilterPattern": rule.urlFilterPattern ?? NSNull(),
                    "ifDomainList": rule.ifDomainList,
                    "unlessDomainList": rule.unlessDomainList,
                ]
            )
        }

        guard !serializedRules.isEmpty else {
            return nil
        }
        guard
            let rulesData = try? JSONSerialization.data(withJSONObject: serializedRules, options: []),
            let rulesLiteral = String(data: rulesData, encoding: .utf8)
        else {
            return nil
        }

        let styleIDLiteral = styleID.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (function() {
            var rules = \(rulesLiteral);
            var locationHref = window.location.href || "";
            var currentHost = (window.location.hostname || "").toLowerCase();
            var collectedSelectors = [];
            var displayNoneDeclaration = "display: none !important;";

            var groupedDisplayNoneCSS = function(selectors) {
                var maximumSelectorsPerGroupedRule = 128;
                var maximumSelectorCharactersPerGroupedRule = 16384;
                var groupedCSS = [];
                var currentSelectors = [];
                var currentSelectorCharacters = 0;

                var flushCurrentSelectors = function() {
                    if (currentSelectors.length === 0) { return; }
                    groupedCSS.push(currentSelectors.join(", ") + " { " + displayNoneDeclaration + " }");
                    currentSelectors = [];
                    currentSelectorCharacters = 0;
                };

                for (var selectorIndex = 0; selectorIndex < selectors.length; selectorIndex += 1) {
                    var selector = selectors[selectorIndex];
                    var separatorCharacters = currentSelectors.length === 0 ? 0 : 2;
                    var projectedSelectorCharacters = currentSelectorCharacters + separatorCharacters + selector.length;
                    if (currentSelectors.length > 0 &&
                        (currentSelectors.length >= maximumSelectorsPerGroupedRule ||
                         projectedSelectorCharacters > maximumSelectorCharactersPerGroupedRule)) {
                        flushCurrentSelectors();
                    }

                    currentSelectors.push(selector);
                    currentSelectorCharacters += (currentSelectors.length === 1 ? 0 : 2) + selector.length;
                }

                flushCurrentSelectors();
                return groupedCSS;
            };

            var compactHiddenSelectors = function(hiddenSelectors) {
                var normalizedSelectors = [];
                for (var selectorIndex = 0; selectorIndex < hiddenSelectors.length; selectorIndex += 1) {
                    var hiddenSelector = hiddenSelectors[selectorIndex];
                    if (typeof hiddenSelector !== "string") { continue; }
                    var normalizedSelector = hiddenSelector.trim();
                    if (!normalizedSelector) { continue; }
                    normalizedSelectors.push(normalizedSelector);
                }

                if (normalizedSelectors.length === 0) { return []; }

                var uniqueSelectors = [];
                var seenSelectors = Object.create(null);
                for (var uniqueIndex = 0; uniqueIndex < normalizedSelectors.length; uniqueIndex += 1) {
                    var normalizedSelector = normalizedSelectors[uniqueIndex];
                    if (seenSelectors[normalizedSelector]) { continue; }
                    seenSelectors[normalizedSelector] = true;
                    uniqueSelectors.push(normalizedSelector);
                }

                return groupedDisplayNoneCSS(uniqueSelectors);
            };

            var domainMatches = function(ruleDomain) {
                if (typeof ruleDomain !== "string") { return false; }
                var normalizedRuleDomain = ruleDomain.trim().toLowerCase();
                if (!normalizedRuleDomain) { return false; }
                if (normalizedRuleDomain.startsWith("*.")) {
                    var suffix = normalizedRuleDomain.slice(2);
                    return !!suffix && currentHost.length > suffix.length && currentHost.endsWith("." + suffix);
                }
                return currentHost === normalizedRuleDomain;
            };

            var frameMatches = function(frameScope) {
                if (frameScope === "mainFrameOnly") {
                    return window.top === window.self;
                }
                if (frameScope === "subframesOnly") {
                    return window.top !== window.self;
                }
                return true;
            };

            for (var index = 0; index < rules.length; index += 1) {
                var rule = rules[index];
                if (!frameMatches(rule.frameScope)) { continue; }

                if (rule.urlFilterPattern) {
                    try {
                        if (!(new RegExp(rule.urlFilterPattern)).test(locationHref)) { continue; }
                    } catch (error) {
                        continue;
                    }
                }

                var ifDomainList = Array.isArray(rule.ifDomainList) ? rule.ifDomainList : [];
                var unlessDomainList = Array.isArray(rule.unlessDomainList) ? rule.unlessDomainList : [];

                if (ifDomainList.length > 0) {
                    if (!currentHost) { continue; }
                    if (!ifDomainList.some(domainMatches)) { continue; }
                }
                if (currentHost && unlessDomainList.some(domainMatches)) { continue; }

                var hiddenSelectors = Array.isArray(rule.hiddenSelectors) ? rule.hiddenSelectors : [];
                for (var hiddenSelectorIndex = 0; hiddenSelectorIndex < hiddenSelectors.length; hiddenSelectorIndex += 1) {
                    collectedSelectors.push(hiddenSelectors[hiddenSelectorIndex]);
                }
            }

            if (collectedSelectors.length === 0) { return; }
            var compactedCSS = compactHiddenSelectors(collectedSelectors);

            var styleId = "\(styleIDLiteral)";
            var root = document.head || document.documentElement;
            if (!root) { return; }
            var style = document.getElementById(styleId);
            if (!style) {
                style = document.createElement('style');
                style.id = styleId;
                root.appendChild(style);
            }
            style.textContent = compactedCSS.join("\\n");
        })();
        """
    }
    #endif

    /// Perform the given block and only return once the page has completed loading
    // SKIP @nobridge
    public func awaitPageLoaded(_ block: () -> ()) async throws {
        try throwProfileSetupErrorIfNeeded()
        #if SKIP
        let token = UUID()
        defer {
            androidPendingPageLoadCallbacks.removeValue(forKey: token)
        }

        let _: Void? = try await withCheckedThrowingContinuation { continuation in
            androidPendingPageLoadCallbacks[token] = { result in
                continuation.resume(with: result)
            }
            logger.log("WebEngine: awaitPageLoaded block()")
            block()
        }
        #else
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
        #endif
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
        for messageHandlerName in Self.systemMessageHandlers + Array(configuration.allRegisteredMessageHandlerNames) {
            if registeredMessageHandlerNames.contains(messageHandlerName) { continue }

            // Sometimes we reuse an underlying WKWebView for a new SwiftUI component.
            userContentController.removeScriptMessageHandler(forName: messageHandlerName, contentWorld: .page)
            userContentController.add(self, contentWorld: .page, name: messageHandlerName)
            registeredMessageHandlerNames.insert(messageHandlerName)
        }
        for missing in registeredMessageHandlerNames.subtracting(Set(Self.systemMessageHandlers).union(configuration.allRegisteredMessageHandlerNames)) {
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
        if configuration.scriptMessageHandlerNameSet.contains(message.name) {
            let scriptMessage = WebViewScriptMessage(
                name: message.name,
                bodyJSON: webViewScriptMessageBodyJSON(from: message.body),
                sourceURL: message.frameInfo.request.url?.absoluteString,
                isMainFrame: message.frameInfo.isMainFrame
            )
            configuration.scriptMessageDelegate?.webEngine(self, didReceiveScriptMessage: scriptMessage)
        }

        if let messageHandler = configuration.legacyMessageHandlers[message.name] {
            let msg = WebViewMessage(frameInfo: message.frameInfo, uuid: UUID(), name: message.name, body: message.body)
            Task {
                await messageHandler(msg)
            }
        }
    }
}
#endif

extension WebEngine {
    /// The engine delegate that handles client navigation events like the page being loaded or an error occuring
    // SKIP @nobridge
    @available(*, deprecated, message: "Use WebEngineConfiguration.navigationDelegate for app navigation hooks. Android installs an internal WebViewClient for blocker enforcement.")
    public var engineDelegate: WebEngineDelegate? {
        get {
            #if SKIP
            androidLegacyNavigationDelegate
            #else
            webView.navigationDelegate as? WebEngineDelegate
            #endif
        }

        set {
            #if SKIP
            setAndroidLegacyNavigationDelegate(newValue)
            #else
            webView.navigationDelegate = newValue
            #endif

        }
    }
}


#if SKIP
fileprivate struct AndroidDocumentStartPlanRegistration {
    let handlers: [ScriptHandler]
    let styleIDs: [String]
}

fileprivate struct AndroidDocumentStartRuleRegistration {
    let handler: ScriptHandler
    let styleID: String
}

fileprivate struct AndroidDocumentStartRuleBatch {
    let allowedOriginRules: [String]
    var rules: [AndroidCosmeticRule]
    var approximateCharacterCount: Int
}

final class AndroidContentBlockerController {
    let config: WebEngineConfiguration
    // Think of persistent rules as a baseline installed once per WebView and reused
    // until the provider says that baseline has changed.
    private var persistentCosmeticScriptHandlers: [ScriptHandler] = []
    private var persistentDocumentStartStyleIDs: [String] = []
    private var persistentLifecycleCosmeticCSS: [String] = []
    private var installedPersistentRules: [AndroidCosmeticRule] = []

    // Navigation rules are the per-page delta. They may change on every main-frame
    // navigation, so we track and refresh them separately from the persistent baseline.
    private var navigationCosmeticScriptHandlers: [ScriptHandler] = []
    private var navigationDocumentStartStyleIDs: [String] = []
    private var navigationLifecycleCosmeticCSS: [String] = []
    private var installedNavigationRules: [AndroidCosmeticRule] = []
    private var androidPreparedCosmeticPageURL: String?

    private let persistentDocumentStartStyleIDPrefix = "__skipweb_content_blockers_persistent"
    private let navigationDocumentStartStyleIDPrefix = "__skipweb_content_blockers_navigation"
    private let persistentLifecycleStyleID = "__skipweb_content_blockers_persistent"
    private let navigationLifecycleStyleID = "__skipweb_content_blockers_navigation"

    init(config: WebEngineConfiguration) {
        self.config = config
    }

    private var provider: (any AndroidContentBlockingProvider)? {
        config.contentBlockers?.effectiveAndroidProvider
    }

    func prepare(for pageURL: URL, in view: PlatformWebView) {
        let prepareStartedAt = currentMilliseconds()
        let documentStartSupported = WebEngine.isAndroidDocumentStartScriptSupported()
        let isWhitelisted = isWhitelisted(pageURL: pageURL)
        let desiredPersistentRules = desiredPersistentRules(for: pageURL, isWhitelisted: isWhitelisted)

        let cosmeticQueryStartedAt = currentMilliseconds()
        let desiredNavigationRules = desiredNavigationRules(for: pageURL, isWhitelisted: isWhitelisted)
        let cosmeticQueryMilliseconds = currentMilliseconds() - cosmeticQueryStartedAt

        let persistentChanged = desiredPersistentRules != installedPersistentRules
        let navigationChanged = desiredNavigationRules != installedNavigationRules

        let persistentPlanStartedAt = currentMilliseconds()
        var persistentPlan = AndroidCosmeticInjectionPlan()
        if persistentChanged {
            persistentPlan.documentStartRules = WebEngine.androidDocumentStartCosmeticRules(
                rules: desiredPersistentRules,
                isDocumentStartSupported: documentStartSupported
            )
        }
        persistentPlan.lifecycleCSS = WebEngine.androidLifecycleCosmeticCSS(
            rules: desiredPersistentRules,
            pageURL: pageURL,
            isDocumentStartSupported: documentStartSupported
        ) { message in
            logger.warning("\(message) for \(pageURL.absoluteString)")
        }
        let persistentPlanMilliseconds = currentMilliseconds() - persistentPlanStartedAt

        let navigationPlanStartedAt = currentMilliseconds()
        var navigationPlan = AndroidCosmeticInjectionPlan()
        if navigationChanged {
            navigationPlan.documentStartRules = WebEngine.androidDocumentStartCosmeticRules(
                rules: desiredNavigationRules,
                isDocumentStartSupported: documentStartSupported
            )
        }
        navigationPlan.lifecycleCSS = WebEngine.androidLifecycleCosmeticCSS(
            rules: desiredNavigationRules,
            pageURL: pageURL,
            isDocumentStartSupported: documentStartSupported
        ) { message in
            logger.warning("\(message) for \(pageURL.absoluteString)")
        }
        let navigationPlanMilliseconds = currentMilliseconds() - navigationPlanStartedAt

        persistentLifecycleCosmeticCSS = persistentPlan.lifecycleCSS
        navigationLifecycleCosmeticCSS = navigationPlan.lifecycleCSS

        let persistentRegisterStartedAt = currentMilliseconds()
        var removedPersistentHandlerCount = 0
        var registeredPersistentHandlerCount = 0
        if persistentChanged {
            removedPersistentHandlerCount = persistentCosmeticScriptHandlers.count
            removeDocumentStartRegistrations(
                handlers: &persistentCosmeticScriptHandlers,
                styleIDs: &persistentDocumentStartStyleIDs
            )
            if documentStartSupported {
                let registration = registerDocumentStartPlan(
                    persistentPlan,
                    styleIDPrefix: persistentDocumentStartStyleIDPrefix,
                    for: pageURL,
                    in: view
                )
                persistentCosmeticScriptHandlers = registration.handlers
                persistentDocumentStartStyleIDs = registration.styleIDs
                registeredPersistentHandlerCount = registration.handlers.count
            }
            installedPersistentRules = desiredPersistentRules
        }
        let persistentRegisterMilliseconds = currentMilliseconds() - persistentRegisterStartedAt

        let navigationRegisterStartedAt = currentMilliseconds()
        var removedNavigationHandlerCount = 0
        var registeredNavigationHandlerCount = 0
        if navigationChanged {
            removedNavigationHandlerCount = navigationCosmeticScriptHandlers.count
            removeDocumentStartRegistrations(
                handlers: &navigationCosmeticScriptHandlers,
                styleIDs: &navigationDocumentStartStyleIDs
            )
            if documentStartSupported {
                let registration = registerDocumentStartPlan(
                    navigationPlan,
                    styleIDPrefix: navigationDocumentStartStyleIDPrefix,
                    for: pageURL,
                    in: view
                )
                navigationCosmeticScriptHandlers = registration.handlers
                navigationDocumentStartStyleIDs = registration.styleIDs
                registeredNavigationHandlerCount = registration.handlers.count
            }
            installedNavigationRules = desiredNavigationRules
        }
        let navigationRegisterMilliseconds = currentMilliseconds() - navigationRegisterStartedAt

        androidPreparedCosmeticPageURL = pageURL.absoluteString
        logger.info(
            "Android blocker prepare url=\(pageURL.absoluteString) totalMs=\(formatMilliseconds(currentMilliseconds() - prepareStartedAt)) whitelisted=\(isWhitelisted) cosmeticQueryMs=\(formatMilliseconds(cosmeticQueryMilliseconds)) documentStartSupported=\(documentStartSupported) persistentChanged=\(persistentChanged) persistentRuleCount=\(desiredPersistentRules.count) persistentSelectorCount=\(selectorEntryCount(in: desiredPersistentRules)) persistentPlanMs=\(formatMilliseconds(persistentPlanMilliseconds)) persistentRegisterMs=\(formatMilliseconds(persistentRegisterMilliseconds)) removedPersistentHandlers=\(removedPersistentHandlerCount) registeredPersistentHandlers=\(registeredPersistentHandlerCount) navigationChanged=\(navigationChanged) navigationRuleCount=\(desiredNavigationRules.count) navigationSelectorCount=\(selectorEntryCount(in: desiredNavigationRules)) navigationPlanMs=\(formatMilliseconds(navigationPlanMilliseconds)) navigationRegisterMs=\(formatMilliseconds(navigationRegisterMilliseconds)) removedNavigationHandlers=\(removedNavigationHandlerCount) registeredNavigationHandlers=\(registeredNavigationHandlerCount)"
        )
    }

    func recoverIfNeeded(for url: String, in view: PlatformWebView) {
        guard androidPreparedCosmeticPageURL != url else {
            return
        }
        guard let pageURL = URL(string: url) else {
            clearInsertedDocumentStartStyles(in: view)
            persistentLifecycleCosmeticCSS = []
            navigationLifecycleCosmeticCSS = []
            androidPreparedCosmeticPageURL = nil
            return
        }

        let documentStartSupported = WebEngine.isAndroidDocumentStartScriptSupported()
        let isWhitelisted = isWhitelisted(pageURL: pageURL)
        let desiredPersistentRules = desiredPersistentRules(for: pageURL, isWhitelisted: isWhitelisted)
        let desiredNavigationRules = desiredNavigationRules(for: pageURL, isWhitelisted: isWhitelisted)
        let persistentChanged = desiredPersistentRules != installedPersistentRules
        let navigationChanged = desiredNavigationRules != installedNavigationRules

        if androidPreparedCosmeticPageURL != nil {
            logger.info("Falling back to late Android cosmetic injection for \(pageURL.absoluteString)")
        }

        var persistentFuturePlan = AndroidCosmeticInjectionPlan()
        if persistentChanged {
            persistentFuturePlan.documentStartRules = WebEngine.androidDocumentStartCosmeticRules(
                rules: desiredPersistentRules,
                isDocumentStartSupported: documentStartSupported
            )
        }
        var navigationFuturePlan = AndroidCosmeticInjectionPlan()
        if navigationChanged {
            navigationFuturePlan.documentStartRules = WebEngine.androidDocumentStartCosmeticRules(
                rules: desiredNavigationRules,
                isDocumentStartSupported: documentStartSupported
            )
        }
        let persistentFallbackPlan = WebEngine.androidRedirectFallbackCosmeticPlan(
            rules: desiredPersistentRules,
            pageURL: pageURL
        ) { message in
            logger.warning("\(message) for redirected final page \(pageURL.absoluteString)")
        }
        let navigationFallbackPlan = WebEngine.androidRedirectFallbackCosmeticPlan(
            rules: desiredNavigationRules,
            pageURL: pageURL
        ) { message in
            logger.warning("\(message) for redirected final page \(pageURL.absoluteString)")
        }

        if persistentChanged {
            let removedStyleIDs = persistentDocumentStartStyleIDs
            removeDocumentStartRegistrations(
                handlers: &persistentCosmeticScriptHandlers,
                styleIDs: &persistentDocumentStartStyleIDs
            )
            clearInsertedStyles(styleIDs: removedStyleIDs, in: view)
            if documentStartSupported {
                let registration = registerDocumentStartPlan(
                    persistentFuturePlan,
                    styleIDPrefix: persistentDocumentStartStyleIDPrefix,
                    for: pageURL,
                    in: view
                )
                persistentCosmeticScriptHandlers = registration.handlers
                persistentDocumentStartStyleIDs = registration.styleIDs
            }
            installedPersistentRules = desiredPersistentRules
        }

        if navigationChanged {
            let removedStyleIDs = navigationDocumentStartStyleIDs
            removeDocumentStartRegistrations(
                handlers: &navigationCosmeticScriptHandlers,
                styleIDs: &navigationDocumentStartStyleIDs
            )
            clearInsertedStyles(styleIDs: removedStyleIDs, in: view)
            if documentStartSupported {
                let registration = registerDocumentStartPlan(
                    navigationFuturePlan,
                    styleIDPrefix: navigationDocumentStartStyleIDPrefix,
                    for: pageURL,
                    in: view
                )
                navigationCosmeticScriptHandlers = registration.handlers
                navigationDocumentStartStyleIDs = registration.styleIDs
            }
            installedNavigationRules = desiredNavigationRules
        }

        // Redirects are already loading the final document, so always recompute the
        // late-injected CSS for that final URL even when the rule arrays are unchanged.
        persistentLifecycleCosmeticCSS = persistentFallbackPlan.lifecycleCSS
        navigationLifecycleCosmeticCSS = navigationFallbackPlan.lifecycleCSS
        androidPreparedCosmeticPageURL = pageURL.absoluteString
    }

    func injectIfNeeded(into view: PlatformWebView) {
        injectLifecycleCSS(
            persistentLifecycleCosmeticCSS,
            styleID: persistentLifecycleStyleID,
            in: view
        )
        injectLifecycleCSS(
            navigationLifecycleCosmeticCSS,
            styleID: navigationLifecycleStyleID,
            in: view
        )
    }

    func intercept(_ request: android.webkit.WebResourceRequest) -> android.webkit.WebResourceResponse? {
        guard let provider, let requestURL = URL(string: request.url.toString()) else {
            return nil
        }
        let headers = WebEngine.androidRequestHeaders(from: request)
        let blockableRequest = AndroidBlockableRequest(
            url: requestURL,
            mainDocumentURL: WebEngine.androidMainDocumentURL(
                for: request,
                requestURL: requestURL,
                headers: headers
            ),
            method: request.method,
            headers: headers,
            isForMainFrame: request.isForMainFrame,
            hasGesture: request.hasGesture(),
            isRedirect: WebEngine.androidRequestIsRedirect(request),
            resourceTypeHint: WebEngine.androidResourceTypeHint(
                for: request,
                requestURL: requestURL,
                headers: headers
            )
        )
        let decision = provider.requestDecision(for: blockableRequest)
        if case .block = decision {
            return WebEngine.blockedAndroidResponse()
        }
        return nil
    }

    private func desiredPersistentRules(
        for pageURL: URL,
        isWhitelisted: Bool
    ) -> [AndroidCosmeticRule] {
        guard !isWhitelisted, let provider else {
            return []
        }
        return provider.persistentCosmeticRules
    }

    private func desiredNavigationRules(
        for pageURL: URL,
        isWhitelisted: Bool
    ) -> [AndroidCosmeticRule] {
        guard !isWhitelisted, let provider else {
            return []
        }
        return provider.navigationCosmeticRules(for: AndroidPageContext(url: pageURL))
    }

    private func isWhitelisted(pageURL: URL) -> Bool {
        WebContentBlockerConfiguration.matchesWhitelistedURL(
            pageURL,
            in: config.contentBlockers?.normalizedWhitelistedDomains ?? []
        )
    }

    private func removeDocumentStartRegistrations(
        handlers: inout [ScriptHandler],
        styleIDs: inout [String]
    ) {
        for handler in handlers {
            handler.remove()
        }
        handlers.removeAll()
        styleIDs.removeAll()
    }

    private func registerDocumentStartPlan(
        _ plan: AndroidCosmeticInjectionPlan,
        styleIDPrefix: String,
        for pageURL: URL,
        in view: PlatformWebView
    ) -> AndroidDocumentStartPlanRegistration {
        var handlers: [ScriptHandler] = []
        var styleIDs: [String] = []
        let batchedRules = batchedDocumentStartRules(plan.documentStartRules)

        for (index, batch) in batchedRules.enumerated() {
            let registerStartedAt = currentMilliseconds()
            if let registration = registerAndroidDocumentStartCosmeticRuleBatch(
                batch,
                index: index,
                styleIDPrefix: styleIDPrefix,
                for: pageURL,
                in: view
            ) {
                handlers.append(registration.handler)
                styleIDs.append(registration.styleID)
            }
            let registerMilliseconds = currentMilliseconds() - registerStartedAt
            logger.info(
                "Android blocker register url=\(pageURL.absoluteString) prefix=\(styleIDPrefix) index=\(index) ruleCount=\(batch.rules.count) selectorCount=\(selectorEntryCount(in: batch.rules)) selectorChars=\(selectorCharacterCountInRules(batch.rules)) allowedOrigins=\(batch.allowedOriginRules.count) ms=\(formatMilliseconds(registerMilliseconds))"
            )
        }

        return AndroidDocumentStartPlanRegistration(
            handlers: handlers,
            styleIDs: styleIDs
        )
    }

    private func registerAndroidDocumentStartCosmeticRuleBatch(
        _ batch: AndroidDocumentStartRuleBatch,
        index: Int,
        styleIDPrefix: String,
        for pageURL: URL,
        in view: PlatformWebView
    ) -> AndroidDocumentStartRuleRegistration? {
        let styleID = "\(styleIDPrefix)_\(index)"
        guard let script = WebEngine.androidContentBlockerBatchedStyleInjectionScript(
            rules: batch.rules,
            styleID: styleID
        ) else {
            return nil
        }
        let allowedOriginRules: kotlin.collections.MutableSet<String> = kotlin.collections.HashSet()
        for allowedOriginRule in batch.allowedOriginRules {
            allowedOriginRules.add(allowedOriginRule)
        }

        // SKIP INSERT: try {
        // SKIP INSERT:     return AndroidDocumentStartRuleRegistration(
        // SKIP INSERT:         handler = androidx.webkit.WebViewCompat.addDocumentStartJavaScript(view, script_0, allowedOriginRules),
        // SKIP INSERT:         styleID = styleID
        // SKIP INSERT:     )
        // SKIP INSERT: } catch (t: Throwable) {
        // SKIP INSERT:     logger.warning("Skipping Android cosmetic rule registration for ${pageURL.absoluteString}: ${t.message ?: t}")
        // SKIP INSERT:     return null
        // SKIP INSERT: }
        return AndroidDocumentStartRuleRegistration(
            handler: WebViewCompat.addDocumentStartJavaScript(view, script, allowedOriginRules),
            styleID: styleID
        )
    }

    private func batchedDocumentStartRules(
        _ rules: [AndroidCosmeticRule]
    ) -> [AndroidDocumentStartRuleBatch] {
        let maximumRulesPerBatch = 128
        let maximumApproximateCharactersPerBatch = 24_000

        var batches: [AndroidDocumentStartRuleBatch] = []
        batches.reserveCapacity((rules.count / maximumRulesPerBatch) + 1)

        for rule in rules {
            let approximateCharacterCount = approximateDocumentStartRuleCharacterCount(rule)
            if var lastBatch = batches.last,
               lastBatch.allowedOriginRules == rule.allowedOriginRules,
               lastBatch.rules.count < maximumRulesPerBatch,
               lastBatch.approximateCharacterCount + approximateCharacterCount <= maximumApproximateCharactersPerBatch {
                lastBatch.rules.append(rule)
                lastBatch.approximateCharacterCount += approximateCharacterCount
                batches[batches.count - 1] = lastBatch
            } else {
                batches.append(
                    AndroidDocumentStartRuleBatch(
                        allowedOriginRules: rule.allowedOriginRules,
                        rules: [rule],
                        approximateCharacterCount: approximateCharacterCount
                    )
                )
            }
        }

        return batches
    }

    private func clearInsertedDocumentStartStyles(in view: PlatformWebView) {
        clearInsertedStyles(styleIDs: persistentDocumentStartStyleIDs, in: view)
        clearInsertedStyles(styleIDs: navigationDocumentStartStyleIDs, in: view)
    }

    private func clearInsertedStyles(styleIDs: [String], in view: PlatformWebView) {
        for styleID in styleIDs {
            let removalScript = WebEngine.androidContentBlockerStyleRemovalScript(styleID: styleID)
            view.evaluateJavascript(removalScript) { _ in
                logger.debug("Cleared Android content blocker CSS styleID=\(styleID)")
            }
        }
    }

    private func injectLifecycleCSS(
        _ cssRules: [String],
        styleID: String,
        in view: PlatformWebView
    ) {
        guard let injectionScript = WebEngine.androidContentBlockerStyleInjectionScript(
            cssRules: cssRules,
            styleID: styleID,
            frameScope: .mainFrameOnly
        ) else {
            let removalScript = WebEngine.androidContentBlockerStyleRemovalScript(styleID: styleID)
            view.evaluateJavascript(removalScript) { _ in
                logger.debug("Cleared Android content blocker CSS styleID=\(styleID)")
            }
            return
        }

        view.evaluateJavascript(injectionScript) { _ in
            logger.debug("Injected Android content blocker CSS styleID=\(styleID)")
        }
    }

    private func currentMilliseconds() -> Double {
        Date().timeIntervalSince1970 * 1000.0
    }

    private func formatMilliseconds(_ value: Double) -> String {
        String((value * 10.0).rounded() / 10.0)
    }

    private func selectorEntryCount(in rules: [AndroidCosmeticRule]) -> Int {
        var count = 0
        for rule in rules {
            count += rule.hiddenSelectors.count
        }
        return count
    }

    private func selectorCharacterCountInRules(_ rules: [AndroidCosmeticRule]) -> Int {
        var count = 0
        for rule in rules {
            count += selectorCharacterCountInSelectorEntries(rule.hiddenSelectors)
        }
        return count
    }

    private func selectorCharacterCountInSelectorEntries(_ hiddenSelectors: [String]) -> Int {
        var count = 0
        for hiddenSelector in hiddenSelectors {
            count += hiddenSelector.count
        }
        return count
    }

    private func approximateDocumentStartRuleCharacterCount(_ rule: AndroidCosmeticRule) -> Int {
        var count = selectorCharacterCountInSelectorEntries(rule.hiddenSelectors)
        count += rule.urlFilterPattern?.count ?? 0
        for domain in rule.ifDomainList {
            count += domain.count
        }
        for domain in rule.unlessDomainList {
            count += domain.count
        }
        return count + 64
    }
}

final class AndroidEngineWebViewClient : android.webkit.WebViewClient {
    weak var engine: WebEngine?
    var embeddedNavigationClient: android.webkit.WebViewClient?
    var legacyNavigationDelegate: WebEngineDelegate?

    init(engine: WebEngine) {
        self.engine = engine
        super.init()
    }

    private var config: WebEngineConfiguration? {
        engine?.configuration
    }

    private func logViewportProbe(stage: String, view: PlatformWebView, url: String) {
        logger.log(
            "viewport probe native stage=\(stage) url=\(url) size=\(view.width)x\(view.height) measured=\(view.measuredWidth)x\(view.measuredHeight) contentHeight=\(view.contentHeight) scale=\(view.scale) scroll=\(view.scrollX),\(view.scrollY) visibility=\(view.visibility) alpha=\(view.alpha)"
        )

        let script = """
        (function() {
            try {
                var doc = document.documentElement;
                var body = document.body;
                var vv = window.visualViewport;
                return JSON.stringify({
                    href: location.href,
                    readyState: document.readyState,
                    innerWidth: window.innerWidth,
                    innerHeight: window.innerHeight,
                    clientWidth: doc ? doc.clientWidth : null,
                    clientHeight: doc ? doc.clientHeight : null,
                    visualViewportWidth: vv ? vv.width : null,
                    visualViewportHeight: vv ? vv.height : null,
                    bodyChildCount: body ? body.children.length : null,
                    bodyTextLength: body && body.innerText ? body.innerText.length : null
                });
            } catch (error) {
                return JSON.stringify({ error: String(error) });
            }
        })();
        """
        view.evaluateJavascript(script) { result in
            logger.log("viewport probe js stage=\(stage) url=\(url) result=\(String(describing: result))")
        }
    }

    override func doUpdateVisitedHistory(view: PlatformWebView, url: String, isReload: Bool) {
        logger.log("application")
        embeddedNavigationClient?.doUpdateVisitedHistory(view, url, isReload)
        legacyNavigationDelegate?.doUpdateVisitedHistory(view, url, isReload)
    }

    override func onFormResubmission(view: PlatformWebView, dontResend: android.os.Message, resend: android.os.Message) {
        logger.log("onFormResubmission")
        embeddedNavigationClient?.onFormResubmission(view, dontResend, resend)
        legacyNavigationDelegate?.onFormResubmission(view, dontResend, resend)
    }

    override func onLoadResource(view: PlatformWebView, url: String) {
        logger.log("onLoadResource: \(url)")
        embeddedNavigationClient?.onLoadResource(view, url)
        legacyNavigationDelegate?.onLoadResource(view, url)
    }

    override func onPageCommitVisible(view: PlatformWebView, url: String) {
        logger.log("onPageCommitVisible: \(url)")
        logViewportProbe(stage: "commit-visible", view: view, url: url)
        engine?.androidContentBlockerController.recoverIfNeeded(for: url, in: view)
        engine?.androidContentBlockerController.injectIfNeeded(into: view)
        embeddedNavigationClient?.onPageCommitVisible(view, url)
        legacyNavigationDelegate?.onPageCommitVisible(view, url)
    }

    override func onPageFinished(view: PlatformWebView, url: String) {
        logger.log("onPageFinished: \(url)")
        logViewportProbe(stage: "page-finished", view: view, url: url)
        engine?.androidContentBlockerController.recoverIfNeeded(for: url, in: view)
        engine?.androidContentBlockerController.injectIfNeeded(into: view)
        if !WebEngine.isAndroidDocumentStartScriptSupported() {
            for userScript in config?.userScripts ?? [] {
                if userScript.webKitUserScript.injectionTime == .atDocumentEnd {
                    let source = userScript.webKitUserScript.source
                    view.evaluateJavascript(source) { _ in
                        logger.debug("Executed user script \(source)")
                    }
                }
            }
        }
        embeddedNavigationClient?.onPageFinished(view, url)
        if let engine {
            engine.androidNavigationDelegate?.webEngineDidFinishNavigation(engine)
        }
        legacyNavigationDelegate?.onPageFinished(view, url)
        engine?.completeAndroidPageLoad(.success(()))
    }

    override func onPageStarted(view: PlatformWebView, url: String, favicon: android.graphics.Bitmap?) {
        logger.log("onPageStarted: \(url)")
        logViewportProbe(stage: "page-started", view: view, url: url)
        engine?.androidContentBlockerController.recoverIfNeeded(for: url, in: view)
        if !(config?.allRegisteredMessageHandlerNames.isEmpty ?? true),
           !WebEngine.isAndroidDocumentStartScriptSupported() {
            view.evaluateJavascript(WebEngine.androidScriptMessageFacadeScript()) { _ in logger.debug("Added webkit.messageHandlers") }
        }
        if !WebEngine.isAndroidDocumentStartScriptSupported() {
            for userScript in config?.userScripts ?? [] {
                if userScript.webKitUserScript.injectionTime == .atDocumentStart {
                    let source = userScript.webKitUserScript.source
                    view.evaluateJavascript(source) { _ in
                        logger.debug("Executed user script \(source)")
                    }
                }
            }
        }
        engine?.androidContentBlockerController.injectIfNeeded(into: view)
        embeddedNavigationClient?.onPageStarted(view, url, favicon)
        if let engine {
            engine.androidNavigationDelegate?.webEngineDidCommitNavigation(engine)
        }
        legacyNavigationDelegate?.onPageStarted(view, url, favicon)
    }

    override func onReceivedClientCertRequest(view: PlatformWebView, request: android.webkit.ClientCertRequest) {
        logger.log("onReceivedClientCertRequest: \(request)")
        embeddedNavigationClient?.onReceivedClientCertRequest(view, request)
        legacyNavigationDelegate?.onReceivedClientCertRequest(view, request)
    }

    override func onReceivedError(view: PlatformWebView, request: android.webkit.WebResourceRequest, error: android.webkit.WebResourceError) {
        logger.log("onReceivedError: \(error)")
        embeddedNavigationClient?.onReceivedError(view, request, error)
        let loadError = WebLoadError(msg: String(error.description), code: error.errorCode)
        if let engine {
            engine.androidNavigationDelegate?.webEngine(engine, didFailNavigation: loadError)
        }
        legacyNavigationDelegate?.onReceivedError(view, request, error)
        engine?.completeAndroidPageLoad(.failure(loadError))
    }

    override func onReceivedHttpAuthRequest(view: PlatformWebView, handler: android.webkit.HttpAuthHandler, host: String, realm: String) {
        logger.log("onReceivedHttpAuthRequest: \(handler) \(host) \(realm)")
        embeddedNavigationClient?.onReceivedHttpAuthRequest(view, handler, host, realm)
        legacyNavigationDelegate?.onReceivedHttpAuthRequest(view, handler, host, realm)
    }

    override func onReceivedHttpError(view: PlatformWebView, request: android.webkit.WebResourceRequest, errorResponse: android.webkit.WebResourceResponse) {
        logger.log("onReceivedHttpError: \(request) \(errorResponse)")
        embeddedNavigationClient?.onReceivedHttpError(view, request, errorResponse)
        legacyNavigationDelegate?.onReceivedHttpError(view, request, errorResponse)
    }

    override func onReceivedSslError(view: PlatformWebView, handler: android.webkit.SslErrorHandler, error: android.net.http.SslError) {
        logger.log("onReceivedSslError: \(error)")
        embeddedNavigationClient?.onReceivedSslError(view, handler, error)
        legacyNavigationDelegate?.onReceivedSslError(view, handler, error)
    }

    override func onRenderProcessGone(view: PlatformWebView, detail: android.webkit.RenderProcessGoneDetail) -> Bool {
        logger.log("onRenderProcessGone: \(detail)")
        let embeddedHandled = embeddedNavigationClient?.onRenderProcessGone(view, detail) ?? false
        let legacyHandled = legacyNavigationDelegate?.onRenderProcessGone(view, detail) ?? false
        return embeddedHandled || legacyHandled
    }

    override func onSafeBrowsingHit(view: PlatformWebView, request: android.webkit.WebResourceRequest, threatType: Int, callback: android.webkit.SafeBrowsingResponse) {
        logger.log("onSafeBrowsingHit: \(request)")
        embeddedNavigationClient?.onSafeBrowsingHit(view, request, threatType, callback)
        legacyNavigationDelegate?.onSafeBrowsingHit(view, request, threatType, callback)
    }

    override func onScaleChanged(view: PlatformWebView, oldScale: Float, newScale: Float) {
        logger.log("onScaleChanged: \(oldScale) \(newScale)")
        embeddedNavigationClient?.onScaleChanged(view, oldScale, newScale)
        legacyNavigationDelegate?.onScaleChanged(view, oldScale, newScale)
    }

    override func onUnhandledKeyEvent(view: PlatformWebView, event: android.view.KeyEvent) {
        logger.log("onUnhandledKeyEvent: \(event)")
        embeddedNavigationClient?.onUnhandledKeyEvent(view, event)
        legacyNavigationDelegate?.onUnhandledKeyEvent(view, event)
    }

    public override func shouldInterceptRequest(view: PlatformWebView, request: android.webkit.WebResourceRequest) -> android.webkit.WebResourceResponse? {
        logger.log("shouldInterceptRequest: \(request.url)")
        let scheme: String = request.url?.scheme ?? ""
        if let handler = config?.schemeHandlers[scheme] {
            return handler.interceptRequest(view: view, request: request)
        }
        if let response = engine?.androidContentBlockerController.intercept(request) {
            return response
        }
        if let response = legacyNavigationDelegate?.shouldInterceptRequest(view, request) {
            return response
        }
        return embeddedNavigationClient?.shouldInterceptRequest(view, request)
    }

    override func shouldOverrideKeyEvent(view: PlatformWebView, event: android.view.KeyEvent) -> Bool {
        logger.log("shouldOverrideKeyEvent: \(event)")
        if embeddedNavigationClient?.shouldOverrideKeyEvent(view, event) == true {
            return true
        }
        if legacyNavigationDelegate?.shouldOverrideKeyEvent(view, event) == true {
            return true
        }
        return false
    }

    override func shouldOverrideUrlLoading(view: PlatformWebView, request: android.webkit.WebResourceRequest) -> Bool {
        logger.log("shouldOverrideUrlLoading: \(request.url)")
        let mainFrameURL = request.isForMainFrame ? URL(string: request.url.toString()) : nil
        if let engine, let url = mainFrameURL {
            engine.androidContentBlockerController.prepare(for: url, in: view)
        }
        if embeddedNavigationClient?.shouldOverrideUrlLoading(view, request) == true {
            return true
        }
        if let engine, let url = mainFrameURL {
            if engine.androidNavigationDelegate?.webEngine(engine, shouldOverrideURLLoading: url) == true {
                return true
            }
        }
        return legacyNavigationDelegate?.shouldOverrideUrlLoading(view, request) ?? false
    }
}

// SKIP @nobridge
public class WebEngineDelegate : android.webkit.WebViewClient {
    let config: WebEngineConfiguration
    let webViewClient: android.webkit.WebViewClient

    override init(config: WebEngineConfiguration, webViewClient: android.webkit.WebViewClient = android.webkit.WebViewClient()) {
        super.init()
        self.config = config
        self.webViewClient = webViewClient
    }

    override func doUpdateVisitedHistory(view: PlatformWebView, url: String, isReload: Bool) {
        webViewClient.doUpdateVisitedHistory(view, url, isReload)
    }

    override func onFormResubmission(view: PlatformWebView, dontResend: android.os.Message, resend: android.os.Message) {
        webViewClient.onFormResubmission(view, dontResend, resend)
    }

    override func onLoadResource(view: PlatformWebView, url: String) {
        webViewClient.onLoadResource(view, url)
    }

    override func onPageCommitVisible(view: PlatformWebView, url: String) {
        webViewClient.onPageCommitVisible(view, url)
    }

    override func onPageFinished(view: PlatformWebView, url: String) {
        webViewClient.onPageFinished(view, url)
    }

    override func onPageStarted(view: PlatformWebView, url: String, favicon: android.graphics.Bitmap?) {
        webViewClient.onPageStarted(view, url, favicon)
    }

    override func onReceivedClientCertRequest(view: PlatformWebView, request: android.webkit.ClientCertRequest) {
        webViewClient.onReceivedClientCertRequest(view, request)
    }

    override func onReceivedError(view: PlatformWebView, request: android.webkit.WebResourceRequest, error: android.webkit.WebResourceError) {
        webViewClient.onReceivedError(view, request, error)
    }

    override func onReceivedHttpAuthRequest(view: PlatformWebView, handler: android.webkit.HttpAuthHandler, host: String, realm: String) {
        webViewClient.onReceivedHttpAuthRequest(view, handler, host, realm)
    }

    override func onReceivedHttpError(view: PlatformWebView, request: android.webkit.WebResourceRequest, errorResponse: android.webkit.WebResourceResponse) {
        webViewClient.onReceivedHttpError(view, request, errorResponse)
    }

    override func onReceivedSslError(view: PlatformWebView, handler: android.webkit.SslErrorHandler, error: android.net.http.SslError) {
        webViewClient.onReceivedSslError(view, handler, error)
    }

    override func onRenderProcessGone(view: PlatformWebView, detail: android.webkit.RenderProcessGoneDetail) -> Bool {
        webViewClient.onRenderProcessGone(view, detail)
    }

    override func onSafeBrowsingHit(view: PlatformWebView, request: android.webkit.WebResourceRequest, threatType: Int, callback: android.webkit.SafeBrowsingResponse) {
        webViewClient.onSafeBrowsingHit(view, request, threatType, callback)
    }

    override func onScaleChanged(view: PlatformWebView, oldScale: Float, newScale: Float) {
        webViewClient.onScaleChanged(view, oldScale, newScale)
    }

    override func onUnhandledKeyEvent(view: PlatformWebView, event: android.view.KeyEvent) {
        webViewClient.onUnhandledKeyEvent(view, event)
    }

    public override func shouldInterceptRequest(view: PlatformWebView, request: android.webkit.WebResourceRequest) -> android.webkit.WebResourceResponse? {
        webViewClient.shouldInterceptRequest(view, request)
    }

    override func shouldOverrideKeyEvent(view: PlatformWebView, event: android.view.KeyEvent) -> Bool {
        webViewClient.shouldOverrideKeyEvent(view, event)
    }

    override func shouldOverrideUrlLoading(view: PlatformWebView, request: android.webkit.WebResourceRequest) -> Bool {
        webViewClient.shouldOverrideUrlLoading(view, request)
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
        super.onPageFinished(view: view, url: url)
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

/// Request metadata for creating a child window/web view.
public struct WebWindowRequest {
    /// The URL currently loaded by the parent web view, when available.
    public let sourceURL: URL?
    /// The target URL requested for the child view, when available.
    ///
    /// On Android this can be `nil` at `onCreateWindow` time.
    public let targetURL: URL?
    /// Whether this request was initiated from a user gesture.
    public let isUserGesture: Bool?
    /// Whether the child should be treated as a dialog window.
    public let isDialog: Bool?
    /// Whether the request targets the main frame.
    public let isMainFrame: Bool?

    public init(sourceURL: URL?, targetURL: URL?, isUserGesture: Bool?, isDialog: Bool?, isMainFrame: Bool?) {
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        self.isUserGesture = isUserGesture
        self.isDialog = isDialog
        self.isMainFrame = isMainFrame
    }
}

#if !SKIP
/// iOS-specific details passed through create-child callback.
public struct WebKitCreateWindowParams {
    public let configuration: WKWebViewConfiguration
    public let navigationAction: WKNavigationAction
    public let windowFeatures: WKWindowFeatures
    let parentConfigurationSnapshot: WebEngineConfiguration
    let parentIsInspectable: Bool

    public init(
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures,
        parentConfigurationSnapshot: WebEngineConfiguration = WebEngineConfiguration(),
        parentIsInspectable: Bool = true
    ) {
        self.configuration = configuration
        self.navigationAction = navigationAction
        self.windowFeatures = windowFeatures
        self.parentConfigurationSnapshot = parentConfigurationSnapshot
        self.parentIsInspectable = parentIsInspectable
    }
}

public extension WebKitCreateWindowParams {
    /// Creates a popup child engine using the exact WKWebViewConfiguration
    /// supplied by WebKit for this createWebViewWith callback.
    ///
    /// Using this helper preserves WebKit's popup contract and avoids
    /// NSInternalInconsistencyException ("Returned WKWebView was not created with
    /// the given configuration.") caused by configuration mismatches.
    @MainActor func makeChildWebEngine(
        configuration webEngineConfiguration: WebEngineConfiguration? = nil,
        frame: CGRect = .zero,
        isInspectable: Bool? = nil
    ) -> WebEngine {
        let effectiveConfiguration = (webEngineConfiguration ?? parentConfigurationSnapshot).popupChildMirroredConfiguration()
        let childWebView = WKWebView(frame: frame, configuration: configuration)
        registerPopupChild(childWebView)

        let preferences = childWebView.configuration.defaultWebpagePreferences!
        preferences.allowsContentJavaScript = effectiveConfiguration.javaScriptEnabled
        childWebView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = effectiveConfiguration.javaScriptCanOpenWindowsAutomatically
        childWebView.allowsBackForwardNavigationGestures = effectiveConfiguration.allowsBackForwardNavigationGestures
        childWebView.scrollView.isScrollEnabled = effectiveConfiguration.isScrollEnabled
        childWebView.pageZoom = effectiveConfiguration.pageZoom
        childWebView.isOpaque = effectiveConfiguration.isOpaque
        childWebView.isInspectable = isInspectable ?? parentIsInspectable
        if effectiveConfiguration.customUserAgent != "" {
            childWebView.customUserAgent = effectiveConfiguration.customUserAgent
        }

        let childEngine = WebEngine(configuration: effectiveConfiguration, webView: childWebView)
        childEngine.refreshMessageHandlers()
        childEngine.updateUserScripts()
        return childEngine
    }

    @MainActor func registerPopupChild(_ childWebView: WKWebView) {
        registerPopupChild(childWebView, initializedWith: configuration)
    }

    @MainActor func registerPopupChild(_ childWebView: WKWebView, initializedWith initConfiguration: WKWebViewConfiguration) {
        PopupConfigRegistry.register(
            childWebViewID: ObjectIdentifier(childWebView),
            initConfigID: ObjectIdentifier(initConfiguration)
        )
    }
}

/// Tracks popup child construction-time configuration for WKUIDelegate validation.
///
/// Why this exists:
/// - WebKit requires that the WKWebView returned from
///   `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)`
///   be initialized with the exact configuration passed into that callback.
/// - Violating this contract can raise
///   `NSInternalInconsistencyException` with:
///   "Returned WKWebView was not created with the given configuration."
/// - `child.webView.configuration` cannot be used for identity validation after init,
///   because WebKit may expose a distinct configuration instance there.
///
/// To verify the contract reliably, SkipWeb records the configuration identity used
/// at child construction time (via `makeChildWebEngine`) and compares that recorded
/// identity in createWebViewWith.
@MainActor enum PopupConfigRegistry {
    enum VerificationResult {
        case matched
        case mismatch
        case missingRegistration
    }

    private static var childInitConfigByWebViewID: [ObjectIdentifier: ObjectIdentifier] = [:]
    private static var didLogMissingRegistrationWarning = false

    static func register(childWebViewID: ObjectIdentifier, initConfigID: ObjectIdentifier) {
        childInitConfigByWebViewID[childWebViewID] = initConfigID
    }

    static func verifyAndConsume(childWebViewID: ObjectIdentifier, expectedConfigID: ObjectIdentifier) -> VerificationResult {
        guard let initConfigID = childInitConfigByWebViewID.removeValue(forKey: childWebViewID) else {
            return .missingRegistration
        }
        return initConfigID == expectedConfigID ? .matched : .mismatch
    }

    static func shouldLogMissingRegistrationWarning() -> Bool {
        if didLogMissingRegistrationWarning {
            return false
        }
        didLogMissingRegistrationWarning = true
        return true
    }
}
#else
/// iOS-specific details passed through create-child callback.
public struct WebKitCreateWindowParams {
    public init() {
    }
}
#endif

#if SKIP
/// Android-specific details passed through create-child callback.
public struct AndroidCreateWindowParams {
    public let isDialog: Bool
    public let isUserGesture: Bool
    public let resultMessage: android.os.Message

    public init(isDialog: Bool, isUserGesture: Bool, resultMessage: android.os.Message) {
        self.isDialog = isDialog
        self.isUserGesture = isUserGesture
        self.resultMessage = resultMessage
    }
}
#else
/// Android-specific details passed through create-child callback.
public struct AndroidCreateWindowParams {
    public init() {
    }
}
#endif

#if !SKIP
public typealias PlatformCreateWindowContext = WebKitCreateWindowParams
#else
public typealias PlatformCreateWindowContext = AndroidCreateWindowParams
#endif

/// Delegate for web view UI behaviors like popup child-window creation.
public protocol SkipWebUIDelegate: AnyObject {
    /// Return a child engine to allow popup creation, or `nil` to deny.
    ///
    /// Platform behavior:
    /// - iOS: called from `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)`.
    /// - Android: called from `WebChromeClient.onCreateWindow`.
    ///   `request.targetURL` may be `nil` on Android at creation time.
    func webView(_ webView: WebView, createWebViewWith request: WebWindowRequest, platformContext: PlatformCreateWindowContext) -> WebEngine?

    /// Called when a previously created child web view is closed.
    ///
    /// Platform behavior:
    /// - iOS: invoked from `WKUIDelegate.webViewDidClose(_:)`.
    /// - Android: invoked from `WebChromeClient.onCloseWindow`.
    func webViewDidClose(_ webView: WebView, child: WebEngine)
}

public extension SkipWebUIDelegate {
    func webView(_ webView: WebView, createWebViewWith request: WebWindowRequest, platformContext: PlatformCreateWindowContext) -> WebEngine? {
        nil
    }

    func webViewDidClose(_ webView: WebView, child: WebEngine) {
    }
}

/// The configuration for a WebEngine
@Observable public class WebEngineConfiguration {
    public var javaScriptEnabled: Bool
    public var javaScriptCanOpenWindowsAutomatically: Bool
    public var allowsBackForwardNavigationGestures: Bool
    public var allowsPullToRefresh: Bool
    public var allowsInlineMediaPlayback: Bool
    public var dataDetectorsEnabled: Bool
    public var isScrollEnabled: Bool
    public var pageZoom: CGFloat
    public var isOpaque: Bool
    public var customUserAgent: String?
    public var profile: WebProfile
    public var userScripts: [WebViewUserScript]
    /// JavaScript message handler names exposed through `window.webkit.messageHandlers`.
    public var scriptMessageHandlerNames: [String]
    /// Delegate that receives bridge-safe JavaScript messages.
    public var scriptMessageDelegate: (any WebViewScriptMessageDelegate)?
    fileprivate var legacyMessageHandlers: [String: ((WebViewMessage) async -> Void)]
    @available(*, deprecated, message: "Use scriptMessageHandlerNames and scriptMessageDelegate.")
    public var messageHandlers: [String: ((WebViewMessage) async -> Void)] {
        get {
            legacyMessageHandlers
        }
        set {
            legacyMessageHandlers = newValue
        }
    }
    public var schemeHandlers: [String: URLSchemeHandler]
    public var uiDelegate: (any SkipWebUIDelegate)?
    public var navigationDelegate: (any SkipWebNavigationDelegate)?
    /// Optional content-blocker configuration applied to web views created from this configuration.
    public var contentBlockers: WebContentBlockerConfiguration?
    /// The latest errors produced while preparing or installing content blockers.
    public private(set) var contentBlockerSetupErrors: [WebContentBlockerError] = []

    #if SKIP
    /// The Android context to use for creating a web context
    public var context: android.content.Context? = nil
    fileprivate var androidResolvedProfile: WebProfile?
    /// Optional Android-only callback for popup child-window creation.
    ///
    /// Think of it as the Android popup hook that runs before `SkipWebUIDelegate`:
    /// return a child `WebEngine` to allow popup creation, or `nil` to deny it.
    public var androidCreateWindowHandler: ((WebView, WebWindowRequest, AndroidCreateWindowParams) -> WebEngine?)?
    /// Optional Android-only callback for popup child-window closure events.
    public var androidCloseWindowHandler: ((WebView, WebEngine) -> Void)?
    #endif

    public init(javaScriptEnabled: Bool = true,
                javaScriptCanOpenWindowsAutomatically: Bool = false,
                allowsBackForwardNavigationGestures: Bool = true,
                allowsPullToRefresh: Bool = true,
                allowsInlineMediaPlayback: Bool = true,
                dataDetectorsEnabled: Bool = true,
                isScrollEnabled: Bool = true,
                pageZoom: CGFloat = 1.0,
                isOpaque: Bool = true,
                customUserAgent: String? = nil,
                profile: WebProfile = .default,
                userScripts: [WebViewUserScript] = [],
                scriptMessageHandlerNames: [String] = [],
                scriptMessageDelegate: (any WebViewScriptMessageDelegate)? = nil,
                messageHandlers: [String: ((WebViewMessage) async -> Void)] = [:],
                schemeHandlers: [String: URLSchemeHandler] = [:],
                uiDelegate: (any SkipWebUIDelegate)? = nil,
                navigationDelegate: (any SkipWebNavigationDelegate)? = nil,
                contentBlockers: WebContentBlockerConfiguration? = nil) {
        self.javaScriptEnabled = javaScriptEnabled
        self.javaScriptCanOpenWindowsAutomatically = javaScriptCanOpenWindowsAutomatically
        self.allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures
        self.allowsPullToRefresh = allowsPullToRefresh
        self.allowsInlineMediaPlayback = allowsInlineMediaPlayback
        self.dataDetectorsEnabled = dataDetectorsEnabled
        self.isScrollEnabled = isScrollEnabled
        self.pageZoom = pageZoom
        self.isOpaque = isOpaque
        self.customUserAgent = customUserAgent
        self.profile = profile
        self.userScripts = userScripts
        self.scriptMessageHandlerNames = scriptMessageHandlerNames
        self.scriptMessageDelegate = scriptMessageDelegate
        self.legacyMessageHandlers = messageHandlers
        self.schemeHandlers = schemeHandlers
        self.uiDelegate = uiDelegate
        self.navigationDelegate = navigationDelegate
        self.contentBlockers = contentBlockers
    }

    var scriptMessageHandlerNameSet: Set<String> {
        Set(scriptMessageHandlerNames)
    }

    var allRegisteredMessageHandlerNames: Set<String> {
        scriptMessageHandlerNameSet.union(legacyMessageHandlers.keys)
    }

    public func popupChildMirroredConfiguration() -> WebEngineConfiguration {
        let copy = WebEngineConfiguration(
            javaScriptEnabled: javaScriptEnabled,
            javaScriptCanOpenWindowsAutomatically: javaScriptCanOpenWindowsAutomatically,
            allowsBackForwardNavigationGestures: allowsBackForwardNavigationGestures,
            allowsPullToRefresh: allowsPullToRefresh,
            allowsInlineMediaPlayback: allowsInlineMediaPlayback,
            dataDetectorsEnabled: dataDetectorsEnabled,
            isScrollEnabled: isScrollEnabled,
            pageZoom: pageZoom,
            isOpaque: isOpaque,
            customUserAgent: customUserAgent,
            profile: profile,
            userScripts: userScripts,
            scriptMessageHandlerNames: scriptMessageHandlerNames,
            scriptMessageDelegate: scriptMessageDelegate,
            messageHandlers: legacyMessageHandlers,
            schemeHandlers: schemeHandlers,
            uiDelegate: uiDelegate,
            navigationDelegate: navigationDelegate,
            contentBlockers: contentBlockers
        )
        #if SKIP
        copy.context = context
        copy.androidResolvedProfile = androidResolvedProfile
        copy.androidCreateWindowHandler = androidCreateWindowHandler
        copy.androidCloseWindowHandler = androidCloseWindowHandler
        #endif
        return copy
    }

    /// Clears the persisted iOS content-blocker cache so the next setup recompiles from source.
    ///
    /// The cache is shared across `WebEngineConfiguration` instances. On non-Apple platforms this is a no-op.
    @MainActor public static func iOSClearContentBlockerCache() throws {
        #if !SKIP
        try WebContentBlockerStore.clearPersistentState()
        #endif
    }

    /// Prepares any configured content blockers and populates `contentBlockerSetupErrors`.
    ///
    /// On Apple platforms this compiles or loads persisted rule lists so later web view creation
    /// can attach them without the initial compile cost. On other platforms this is a no-op.
    @MainActor
    @discardableResult
    public func iOSPrepareContentBlockers() async -> [WebContentBlockerError] {
        #if !SKIP
        _ = await prepareIOSContentBlockerRuleLists()
        return contentBlockerSetupErrors
        #else
        contentBlockerSetupErrors = []
        return []
        #endif
    }

    #if !SKIP
    /// Create a `WebViewConfiguration` from the properties of this configuration and
    /// asynchronously install any configured iOS content blockers.
    @MainActor public func makeWebViewConfiguration() async -> WebViewConfiguration {
        let configuration = makeBaseWebViewConfiguration()
        _ = await installPreparedContentBlockers(into: configuration.userContentController)
        return configuration
    }

    @MainActor func makeBaseWebViewConfiguration() -> WebViewConfiguration {
        let configuration = WebViewConfiguration()
        configuration.websiteDataStore = webKitWebsiteDataStore

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

    @MainActor
    @discardableResult
    fileprivate func installPreparedContentBlockers(into userContentController: WKUserContentController) async -> [WebContentBlockerError] {
        let prepared = await prepareIOSContentBlockerRuleLists()
        for ruleList in prepared.ruleLists {
            userContentController.add(ruleList)
        }
        WebContentBlockerStore.recordInstallation(count: prepared.ruleLists.count)
        return prepared.errors
    }

    @MainActor
    private func prepareIOSContentBlockerRuleLists() async -> PreparedContentBlockerRuleLists {
        contentBlockerSetupErrors = []
        guard let contentBlockers, !contentBlockers.iOSRuleListPaths.isEmpty else {
            return PreparedContentBlockerRuleLists(ruleLists: [], errors: [])
        }

        let prepared = await WebContentBlockerStore.prepareRuleLists(
            from: contentBlockers.iOSRuleListPaths,
            whitelistedDomains: contentBlockers.normalizedWhitelistedDomains,
            popupWhitelistedSourceDomains: contentBlockers.normalizedPopupWhitelistedSourceDomains
        )
        contentBlockerSetupErrors = prepared.errors
        return prepared
    }

    @MainActor private var webKitWebsiteDataStore: WKWebsiteDataStore {
        switch profile {
        case .default:
            return WKWebsiteDataStore.default()
        case .ephemeral:
            return WKWebsiteDataStore.nonPersistent()
        case .named(let identifier):
            guard let dataStoreIdentifier = webKitDataStoreIdentifier(for: identifier) else {
                return WKWebsiteDataStore.default()
            }
            return WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)
        }
    }

    @MainActor private func webKitDataStoreIdentifier(for identifier: String) -> UUID? {
        guard let normalizedIdentifier = WebProfile.named(identifier).normalizedNamedIdentifier else {
            return nil
        }
        if let uuid = UUID(uuidString: normalizedIdentifier) {
            return uuid
        }

        let digest = Insecure.SHA1.hash(data: Data(normalizedIdentifier.utf8))
        let bytes = Array(digest.prefix(16))
        guard bytes.count == 16 else {
            return nil
        }

        let versionedBytes: [UInt8] = bytes.enumerated().map { index, byte in
            switch index {
            case 6:
                return (byte & 0x0F) | 0x50
            case 8:
                return (byte & 0x3F) | 0x80
            default:
                return byte
            }
        }

        return UUID(uuid: (
            versionedBytes[0], versionedBytes[1], versionedBytes[2], versionedBytes[3],
            versionedBytes[4], versionedBytes[5], versionedBytes[6], versionedBytes[7],
            versionedBytes[8], versionedBytes[9], versionedBytes[10], versionedBytes[11],
            versionedBytes[12], versionedBytes[13], versionedBytes[14], versionedBytes[15]
        ))
    }
    #endif
}

#if !SKIP
fileprivate struct PreparedContentBlockerRuleLists {
    let ruleLists: [WKContentRuleList]
    let errors: [WebContentBlockerError]
}

struct WebContentBlockerDiagnostics: Equatable {
    var cacheHitIdentifiers: [String] = []
    var compiledIdentifiers: [String] = []
    var prunedIdentifiers: [String] = []
    var installedRuleListCount: Int = 0
    var errors: [WebContentBlockerError] = []
}

    @MainActor enum WebContentBlockerDebug {
        static var diagnostics: WebContentBlockerDiagnostics {
            WebContentBlockerStore.diagnostics
        }

    static func resetDiagnostics() {
        WebContentBlockerStore.diagnostics = WebContentBlockerDiagnostics()
    }

    static func setBaseDirectoryOverride(_ url: URL?) {
        WebContentBlockerStore.baseDirectoryOverride = url
    }

    static func clearPersistentState() throws {
        try WebContentBlockerStore.clearPersistentState()
    }

    static func augmentedRuleListContent(_ content: String, whitelistedDomains: [String]) -> String {
        WebContentBlockerConfiguration.augmentedIOSRuleListContent(
            content,
            whitelistedDomains: WebContentBlockerConfiguration.normalizedWhitelistedDomains(from: whitelistedDomains)
        )
    }

    static func augmentedRuleListContent(
        _ content: String,
        whitelistedDomains: [String],
        popupWhitelistedSourceDomains: [String]
    ) -> String {
        WebContentBlockerConfiguration.augmentedIOSRuleListContent(
            content,
            whitelistedDomains: WebContentBlockerConfiguration.normalizedWhitelistedDomains(from: whitelistedDomains),
            popupWhitelistedSourceDomains: WebContentBlockerConfiguration.normalizedWhitelistedDomains(from: popupWhitelistedSourceDomains)
        )
    }
}

@MainActor
fileprivate enum WebContentBlockerStore {
    fileprivate static var baseDirectoryOverride: URL?
    fileprivate static var diagnostics = WebContentBlockerDiagnostics()

    private struct Metadata: Codable {
        var version: Int
        var identifiersBySourcePath: [String: String]

        init(version: Int = 1, identifiersBySourcePath: [String: String] = [:]) {
            self.version = version
            self.identifiersBySourcePath = identifiersBySourcePath
        }
    }

    private static let metadataFileName = "metadata.json"
    private static let storeDirectoryName = "RuleListStore"
    private static let metadataVersion = 1

    static func prepareRuleLists(
        from sourcePaths: [String],
        whitelistedDomains: [String],
        popupWhitelistedSourceDomains: [String] = []
    ) async -> PreparedContentBlockerRuleLists {
        var ruleLists: [WKContentRuleList] = []
        var errors: [WebContentBlockerError] = []

        let normalizedSourcePaths = normalizedPaths(from: sourcePaths)
        let normalizedWhitelistedDomains = WebContentBlockerConfiguration.normalizedWhitelistedDomains(from: whitelistedDomains)
        let normalizedPopupWhitelistedSourceDomains = WebContentBlockerConfiguration.normalizedWhitelistedDomains(from: popupWhitelistedSourceDomains)
        guard !normalizedSourcePaths.isEmpty else {
            diagnostics.errors = []
            return PreparedContentBlockerRuleLists(ruleLists: [], errors: [])
        }

        guard let store = makeStore(errors: &errors) else {
            diagnostics.errors = errors
            return PreparedContentBlockerRuleLists(ruleLists: [], errors: errors)
        }

        var metadata = loadMetadata(errors: &errors)
        let previousIdentifiersBySourcePath = metadata.identifiersBySourcePath
        var nextIdentifiersBySourcePath: [String: String] = [:]
        var staleIdentifiers = Set(previousIdentifiersBySourcePath.values)

        for sourcePath in normalizedSourcePaths {
            let fileURL = URL(fileURLWithPath: sourcePath)
            let fileData: Data
            do {
                fileData = try Data(contentsOf: fileURL)
            } catch {
                errors.append(.fileReadFailed(path: sourcePath, description: error.localizedDescription))
                continue
            }

            guard let content = String(data: fileData, encoding: .utf8) else {
                errors.append(.fileEncodingFailed(path: sourcePath))
                continue
            }

            let augmentedContent = WebContentBlockerConfiguration.augmentedIOSRuleListContent(
                content,
                whitelistedDomains: normalizedWhitelistedDomains,
                popupWhitelistedSourceDomains: normalizedPopupWhitelistedSourceDomains
            )
            if isEmptyRuleListContent(augmentedContent) {
                continue
            }
            let augmentedContentData = Data(augmentedContent.utf8)
            let identifier = ruleListIdentifier(for: sourcePath, contentData: augmentedContentData)
            nextIdentifiersBySourcePath[sourcePath] = identifier
            staleIdentifiers.remove(identifier)

            if let cachedRuleList = await lookupRuleList(identifier: identifier, in: store, errors: &errors) {
                ruleLists.append(cachedRuleList)
                diagnostics.cacheHitIdentifiers.append(identifier)
                continue
            }

            if let compiledRuleList = await compileRuleList(identifier: identifier, content: augmentedContent, sourcePath: sourcePath, in: store, errors: &errors) {
                ruleLists.append(compiledRuleList)
                diagnostics.compiledIdentifiers.append(identifier)
            }
        }

        let activeIdentifiers = Set(nextIdentifiersBySourcePath.values)
        for staleIdentifier in staleIdentifiers.subtracting(activeIdentifiers) {
            await removeRuleList(identifier: staleIdentifier, from: store, errors: &errors)
        }

        metadata.identifiersBySourcePath = nextIdentifiersBySourcePath
        saveMetadata(metadata, errors: &errors)
        diagnostics.errors = errors

        return PreparedContentBlockerRuleLists(ruleLists: ruleLists, errors: errors)
    }

    static func recordInstallation(count: Int) {
        diagnostics.installedRuleListCount += count
    }

    static func clearPersistentState() throws {
        guard let baseDirectory = resolvedBaseDirectoryURL() else {
            return
        }
        if FileManager.default.fileExists(atPath: baseDirectory.path) {
            try FileManager.default.removeItem(at: baseDirectory)
        }
    }

    private static func normalizedPaths(from sourcePaths: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for sourcePath in sourcePaths {
            let path = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
            if seen.insert(path).inserted {
                normalized.append(path)
            }
        }
        return normalized
    }

    private static func ruleListIdentifier(for sourcePath: String, contentData: Data) -> String {
        "skipweb.content-blocker.\(hexString(Insecure.SHA1.hash(data: Data(sourcePath.utf8)))).\(hexString(SHA256.hash(data: contentData)))"
    }

    private static func isEmptyRuleListContent(_ content: String) -> Bool {
        guard let data = content.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let rules = jsonObject as? [Any] else {
            return false
        }
        return rules.isEmpty
    }

    private static func makeStore(errors: inout [WebContentBlockerError]) -> WKContentRuleListStore? {
        let fileManager = FileManager.default
        guard let baseDirectory = resolvedBaseDirectoryURL() else {
            errors.append(.storeUnavailable("Missing application support directory"))
            return nil
        }

        let storeDirectory = baseDirectory.appendingPathComponent(storeDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        } catch {
            errors.append(.storeUnavailable(error.localizedDescription))
            return nil
        }

        guard let store = WKContentRuleListStore(url: storeDirectory) else {
            errors.append(.storeUnavailable("WKContentRuleListStore(url:) returned nil"))
            return nil
        }
        return store
    }

    private static func resolvedBaseDirectoryURL() -> URL? {
        if let baseDirectoryOverride {
            return baseDirectoryOverride
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SkipWeb", isDirectory: true)
            .appendingPathComponent("ContentBlockers", isDirectory: true)
    }

    private static func metadataURL() -> URL? {
        resolvedBaseDirectoryURL()?.appendingPathComponent(metadataFileName)
    }

    private static func loadMetadata(errors: inout [WebContentBlockerError]) -> Metadata {
        guard let metadataURL = metadataURL() else {
            return Metadata(version: metadataVersion)
        }

        do {
            if !FileManager.default.fileExists(atPath: metadataURL.path) {
                return Metadata(version: metadataVersion)
            }
            let data = try Data(contentsOf: metadataURL)
            return try JSONDecoder().decode(Metadata.self, from: data)
        } catch {
            errors.append(.metadataReadFailed(error.localizedDescription))
            return Metadata(version: metadataVersion)
        }
    }

    private static func saveMetadata(_ metadata: Metadata, errors: inout [WebContentBlockerError]) {
        guard let metadataURL = metadataURL() else {
            errors.append(.metadataWriteFailed("Missing metadata path"))
            return
        }

        do {
            let baseDirectory = metadataURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            errors.append(.metadataWriteFailed(error.localizedDescription))
        }
    }

    private static func lookupRuleList(identifier: String, in store: WKContentRuleListStore, errors: inout [WebContentBlockerError]) async -> WKContentRuleList? {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                store.lookUpContentRuleList(forIdentifier: identifier) { ruleList, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ruleList)
                    }
                }
            }
        } catch let error as WebContentBlockerError {
            errors.append(error)
        } catch {
            let nsError = error as NSError
            if nsError.domain == WKErrorDomain,
               nsError.code == WKError.Code.contentRuleListStoreLookUpFailed.rawValue {
                return nil
            }
            errors.append(.cacheLookupFailed(identifier: identifier, description: error.localizedDescription))
        }
        return nil
    }

    private static func compileRuleList(identifier: String, content: String, sourcePath: String, in store: WKContentRuleListStore, errors: inout [WebContentBlockerError]) async -> WKContentRuleList? {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: content) { ruleList, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ruleList)
                    }
                }
            }
        } catch let error as WebContentBlockerError {
            errors.append(error)
        } catch {
            errors.append(.compilationFailed(path: sourcePath, description: error.localizedDescription))
        }
        return nil
    }

    private static func removeRuleList(identifier: String, from store: WKContentRuleListStore, errors: inout [WebContentBlockerError]) async {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.removeContentRuleList(forIdentifier: identifier) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
            diagnostics.prunedIdentifiers.append(identifier)
        } catch let error as WebContentBlockerError {
            errors.append(error)
        } catch {
            let nsError = error as NSError
            // Failing to delete a stale compiled rule list should not prevent the current rule set from loading.
            if nsError.domain == WKErrorDomain,
               nsError.code == WKError.Code.contentRuleListStoreRemoveFailed.rawValue {
                return
            }
            errors.append(.staleRuleRemovalFailed(identifier: identifier, description: error.localizedDescription))
        }
    }

    private static func hexString<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif

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
