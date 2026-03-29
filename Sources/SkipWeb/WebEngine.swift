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

#if SKIP || os(iOS)


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

public enum WebProfile: Equatable, Hashable, Sendable {
    case `default`
    case named(String)

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

public struct WebContentBlockerConfiguration {
    public var iOSRuleListPaths: [String]
    public var androidMode: AndroidContentBlockingMode
    @available(*, deprecated, message: "Use androidMode with AndroidContentBlockingMode.custom(...) instead.")
    public var androidRequestBlocker: (any AndroidRequestBlocker)?
    @available(*, deprecated, message: "Use androidMode with AndroidContentBlockingMode.custom(...) instead.")
    public var androidCosmeticBlocker: (any AndroidCosmeticBlocker)?

    public init(
        iOSRuleListPaths: [String] = [],
        androidMode: AndroidContentBlockingMode = .disabled,
        androidRequestBlocker: (any AndroidRequestBlocker)? = nil,
        androidCosmeticBlocker: (any AndroidCosmeticBlocker)? = nil
    ) {
        self.iOSRuleListPaths = iOSRuleListPaths
        self.androidMode = androidMode
        self.androidRequestBlocker = androidRequestBlocker
        self.androidCosmeticBlocker = androidCosmeticBlocker
    }
}

public protocol AndroidContentBlockingProvider {
    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision
    func cosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule]
}

public extension AndroidContentBlockingProvider {
    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision {
        .allow
    }

    func cosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule] {
        []
    }
}

public enum AndroidContentBlockingMode {
    case disabled
    case custom(any AndroidContentBlockingProvider)
}

public enum AndroidRequestBlockDecision: Equatable, Sendable {
    case allow
    case block
}

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

public struct AndroidBlockableRequest: Equatable, Sendable {
    public var url: URL
    public var mainDocumentURL: URL?
    public var method: String
    public var headers: [String: String]
    public var isForMainFrame: Bool
    public var hasGesture: Bool
    public var isRedirect: Bool?
    public var resourceTypeHint: AndroidResourceTypeHint?

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

public protocol AndroidRequestBlocker {
    func decision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision
}

public struct AndroidPageContext: Equatable, Sendable {
    public var url: URL
    public var host: String?

    public init(url: URL, host: String? = nil) {
        self.url = url
        self.host = host ?? url.host
    }
}

public enum AndroidCosmeticFrameScope: String, CaseIterable, Hashable, Sendable {
    case mainFrameOnly
    case subframesOnly
    case allFrames
}

public enum AndroidCosmeticInjectionTiming: String, CaseIterable, Hashable, Sendable {
    case documentStart
    case pageLifecycle
}

public struct AndroidCosmeticRule: Equatable, Sendable {
    public var css: [String]
    public var urlFilterPattern: String?
    public var allowedOriginRules: [String]
    public var frameScope: AndroidCosmeticFrameScope
    public var preferredTiming: AndroidCosmeticInjectionTiming

    public init(
        css: [String] = [],
        urlFilterPattern: String? = nil,
        allowedOriginRules: [String] = ["*"],
        frameScope: AndroidCosmeticFrameScope = .mainFrameOnly,
        preferredTiming: AndroidCosmeticInjectionTiming = .documentStart
    ) {
        self.css = css
        self.urlFilterPattern = urlFilterPattern
        self.allowedOriginRules = allowedOriginRules
        self.frameScope = frameScope
        self.preferredTiming = preferredTiming
    }

    /// Convenience initializer for selector-based hiding, matching iOS `css-display-none`.
    public init(
        hiddenSelectors: [String],
        urlFilterPattern: String? = nil,
        allowedOriginRules: [String] = ["*"],
        frameScope: AndroidCosmeticFrameScope = .mainFrameOnly,
        preferredTiming: AndroidCosmeticInjectionTiming = .documentStart
    ) {
        self.init(
            css: Self.hideCSS(for: hiddenSelectors),
            urlFilterPattern: urlFilterPattern,
            allowedOriginRules: allowedOriginRules,
            frameScope: frameScope,
            preferredTiming: preferredTiming
        )
    }

    fileprivate static func hideCSS(for selectors: [String]) -> [String] {
        selectors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "\($0) { display: none !important; }" }
    }
}

public protocol AndroidCosmeticBlocker {
    func cosmetics(for page: AndroidPageContext) -> [AndroidCosmeticRule]
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

fileprivate struct LegacyAndroidContentBlockingProvider: AndroidContentBlockingProvider {
    let requestBlocker: (any AndroidRequestBlocker)?
    let cosmeticBlocker: (any AndroidCosmeticBlocker)?

    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision {
        requestBlocker?.decision(for: request) ?? .allow
    }

    func cosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule] {
        cosmeticBlocker?.cosmetics(for: page) ?? []
    }
}

extension WebContentBlockerConfiguration {
    var hasLegacyAndroidHooks: Bool {
        androidRequestBlocker != nil || androidCosmeticBlocker != nil
    }

    var effectiveAndroidMode: AndroidContentBlockingMode {
        switch androidMode {
        case .disabled:
            if hasLegacyAndroidHooks {
                return .custom(
                    LegacyAndroidContentBlockingProvider(
                        requestBlocker: androidRequestBlocker,
                        cosmeticBlocker: androidCosmeticBlocker
                    )
                )
            }
            return .disabled
        case .custom:
            return androidMode
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
}

public enum WebContentBlockerError: Error, Equatable, LocalizedError {
    case storeUnavailable(String)
    case fileReadFailed(path: String, description: String)
    case fileEncodingFailed(path: String)
    case cacheLookupFailed(identifier: String, description: String)
    case compilationFailed(path: String, description: String)
    case metadataReadFailed(String)
    case metadataWriteFailed(String)
    case staleRuleRemovalFailed(identifier: String, description: String)
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
    public private(set) var contentBlockerSetupErrors: [WebContentBlockerError] = []
    #if !SKIP
    public override var description: String {
        "WebEngine: \(webView)"
    }
    private var observers: [NSKeyValueObservation] = []
    private var profileSetupError: WebProfileError?
    #else
    private var profileSetupError: WebProfileError?
    private var androidProfileCookieManager: android.webkit.CookieManager?
    private var androidProfileWebStorage: android.webkit.WebStorage?
    fileprivate lazy var androidContentBlockerController = AndroidContentBlockerController(config: configuration)
    private lazy var androidInternalWebViewClient = AndroidEngineWebViewClient(engine: self)
    private var androidEmbeddedNavigationClient: android.webkit.WebViewClient?
    private var androidLegacyNavigationDelegate: WebEngineDelegate?
    private var androidPendingPageLoadCallbacks: [UUID: (Result<Void, Error>) -> Void] = [:]
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
            self.contentBlockerSetupErrors = configuration.installContentBlockers(into: webView.configuration.userContentController)
        } else {
            self.webView = WKWebView(frame: .zero, configuration: configuration.webViewConfiguration)
            self.contentBlockerSetupErrors = configuration.contentBlockerSetupErrors
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
            self.profileSetupError = nil
        case .failure(let error):
            self.profileSetupError = error
        }
        if let suppliedAndroidWebViewClient,
           !(suppliedAndroidWebViewClient is AndroidEngineWebViewClient) {
            setAndroidEmbeddedNavigationClient(suppliedAndroidWebViewClient)
        }
        self.webView.webViewClient = androidInternalWebViewClient
        #endif
    }

    public func reload() {
        if profileSetupError != nil {
            return
        }
        #if SKIP
        prepareAndroidContentBlockersForPendingMainFrameNavigation(targetURL: url)
        #endif
        webView.reload()
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
        #if SKIP
        prepareAndroidContentBlockersForPendingMainFrameNavigation(targetURL: pendingHistoryNavigationURL(offset: -1))
        #endif
        webView.goBack()
    }

    public func goForward() {
        if profileSetupError != nil {
            return
        }
        #if SKIP
        prepareAndroidContentBlockersForPendingMainFrameNavigation(targetURL: pendingHistoryNavigationURL(offset: 1))
        #endif
        webView.goForward()
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
        switch profile {
        case .default:
            return nil
        case .named:
            return profile.normalizedNamedIdentifier == nil ? .invalidProfileName : nil
        }
    }

    private func throwProfileSetupErrorIfNeeded() throws {
        if let profileSetupError {
            throw profileSetupError
        }
    }

    #if SKIP
    struct AndroidProfileResources {
        let cookieManager: android.webkit.CookieManager?
        let webStorage: android.webkit.WebStorage?
    }

    public static func isAndroidMultiProfileSupported() -> Bool {
        WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
    }

    public static func isAndroidDocumentStartScriptSupported() -> Bool {
        WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
    }

    private static func configureAndroidProfile(_ profile: WebProfile, for webView: PlatformWebView) -> Result<AndroidProfileResources, WebProfileError> {
        if let supportError = androidProfileSupportError(for: profile, isMultiProfileFeatureSupported: isAndroidMultiProfileSupported()) {
            return .failure(supportError)
        }

        switch profile {
        case .default:
            return .success(AndroidProfileResources(cookieManager: nil, webStorage: nil))
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
                    webStorage: profile.getWebStorage()
                )
            )
        }
    }

    static func androidProfileSupportError(for profile: WebProfile, isMultiProfileFeatureSupported: Bool) -> WebProfileError? {
        if let validationError = profileValidationError(for: profile) {
            return validationError
        }
        switch profile {
        case .default:
            return nil
        case .named:
            return isMultiProfileFeatureSupported ? nil : .unsupportedOnAndroid
        }
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
            self.profileSetupError = nil
            return nil
        case .failure(let error):
            self.profileSetupError = error
            return error
        }
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
        refreshMessageHandlers()
        //try await awaitPageLoaded {
        webView.load(Data(html.utf8), mimeType: mimeType, characterEncodingName: encoding, baseURL: baseURL ?? URL(string: "about:blank")!)
        //}
        #endif
    }

    /// Asyncronously load the given URL, returning once the page has been loaded or an error has occurred
    public func load(url: URL) async throws {
        try throwProfileSetupErrorIfNeeded()
        let urlString = url.absoluteString
        logger.info("load URL=\(urlString) webView: \(self.description)")
        #if SKIP
        androidContentBlockerController.prepare(for: url, in: webView)
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

    fileprivate static func normalizedAndroidCosmeticCSS(_ cssRules: [String]) -> [String] {
        cssRules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

    static func androidCosmeticInjectionPlan(
        rules: [AndroidCosmeticRule],
        pageURL: URL,
        isDocumentStartSupported: Bool,
        log: ((String) -> Void)? = nil
    ) -> AndroidCosmeticInjectionPlan {
        var plan = AndroidCosmeticInjectionPlan()

        for rule in rules {
            let normalizedCSS = normalizedAndroidCosmeticCSS(rule.css)
            guard !normalizedCSS.isEmpty else {
                continue
            }

            switch rule.preferredTiming {
            case .documentStart:
                if isDocumentStartSupported {
                    var normalizedRule = rule
                    normalizedRule.css = normalizedCSS
                    normalizedRule.allowedOriginRules = normalizedAndroidAllowedOriginRules(rule.allowedOriginRules)
                    plan.documentStartRules.append(normalizedRule)
                } else if rule.frameScope == .mainFrameOnly,
                          androidAllowedOriginRulesMatchPage(rule.allowedOriginRules, pageURL: pageURL),
                          androidURLFilterPatternMatchesPage(rule.urlFilterPattern, pageURL: pageURL) {
                    plan.lifecycleCSS.append(contentsOf: normalizedCSS)
                } else if rule.frameScope == .mainFrameOnly {
                    if !androidAllowedOriginRulesMatchPage(rule.allowedOriginRules, pageURL: pageURL) {
                        log?("Skipping Android cosmetic rule because page origin does not match allowedOriginRules")
                    } else {
                        log?("Skipping Android cosmetic rule because page URL does not match urlFilterPattern")
                    }
                } else {
                    log?("Skipping Android cosmetic rule with frameScope=\(rule.frameScope.rawValue) because document-start frame injection is unavailable")
                }
            case .pageLifecycle:
                if rule.frameScope == .mainFrameOnly,
                   androidAllowedOriginRulesMatchPage(rule.allowedOriginRules, pageURL: pageURL),
                   androidURLFilterPatternMatchesPage(rule.urlFilterPattern, pageURL: pageURL) {
                    plan.lifecycleCSS.append(contentsOf: normalizedCSS)
                } else if rule.frameScope == .mainFrameOnly {
                    if !androidAllowedOriginRulesMatchPage(rule.allowedOriginRules, pageURL: pageURL) {
                        log?("Skipping Android cosmetic rule because page origin does not match allowedOriginRules")
                    } else {
                        log?("Skipping Android cosmetic rule because page URL does not match urlFilterPattern")
                    }
                } else {
                    log?("Skipping Android cosmetic rule with frameScope=\(rule.frameScope.rawValue) because page-lifecycle injection only supports the main frame")
                }
            }
        }

        return plan
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
        urlFilterPattern: String? = nil
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
final class AndroidContentBlockerController {
    let config: WebEngineConfiguration
    private var androidCosmeticScriptHandlers: [ScriptHandler] = []
    private var androidLifecycleCosmeticCSS: [String] = []
    private var androidPreparedCosmeticPageURL: String?

    init(config: WebEngineConfiguration) {
        self.config = config
    }

    private var provider: (any AndroidContentBlockingProvider)? {
        config.contentBlockers?.effectiveAndroidProvider
    }

    func prepare(for pageURL: URL, in view: PlatformWebView) {
        removeAllAndroidCosmeticScriptHandlers()
        let plan = androidCosmeticPlan(for: pageURL)
        androidLifecycleCosmeticCSS = plan.lifecycleCSS

        if WebEngine.isAndroidDocumentStartScriptSupported() {
            for (index, rule) in plan.documentStartRules.enumerated() {
                if let handler = registerAndroidDocumentStartCosmeticRule(rule, index: index, for: pageURL, in: view) {
                    androidCosmeticScriptHandlers.append(handler)
                }
            }
        }

        androidPreparedCosmeticPageURL = pageURL.absoluteString
    }

    func recoverIfNeeded(for url: String) {
        guard androidPreparedCosmeticPageURL != url else {
            return
        }
        guard let pageURL = URL(string: url) else {
            removeAllAndroidCosmeticScriptHandlers()
            androidLifecycleCosmeticCSS = []
            androidPreparedCosmeticPageURL = nil
            return
        }

        if androidPreparedCosmeticPageURL != nil {
            logger.info("Falling back to late Android cosmetic injection for \(pageURL.absoluteString)")
        }
        removeAllAndroidCosmeticScriptHandlers()
        let fallbackPlan = fallbackAndroidCosmeticPlan(for: pageURL)
        androidLifecycleCosmeticCSS = fallbackPlan.lifecycleCSS
        androidPreparedCosmeticPageURL = pageURL.absoluteString
    }

    func injectIfNeeded(into view: PlatformWebView) {
        guard let injectionScript = WebEngine.androidContentBlockerStyleInjectionScript(
            cssRules: androidLifecycleCosmeticCSS,
            styleID: "__skipweb_content_blockers",
            frameScope: .mainFrameOnly
        ) else {
            clearCSS(in: view)
            return
        }

        view.evaluateJavascript(injectionScript) { _ in
            logger.debug("Injected Android content blocker CSS")
        }
    }

    func intercept(_ request: android.webkit.WebResourceRequest) -> android.webkit.WebResourceResponse? {
        guard let provider, let requestURL = URL(string: request.url.toString()) else {
            return nil
        }
        let headers = WebEngine.androidRequestHeaders(from: request)
        let decision = provider.requestDecision(
            for: AndroidBlockableRequest(
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
        )
        if case .block = decision {
            return WebEngine.blockedAndroidResponse()
        }
        return nil
    }

    private func removeAllAndroidCosmeticScriptHandlers() {
        for handler in androidCosmeticScriptHandlers {
            handler.remove()
        }
        androidCosmeticScriptHandlers.removeAll()
    }

    private func androidCosmeticPlan(for pageURL: URL) -> AndroidCosmeticInjectionPlan {
        guard let provider else {
            return AndroidCosmeticInjectionPlan()
        }
        return WebEngine.androidCosmeticInjectionPlan(
            rules: provider.cosmeticRules(for: AndroidPageContext(url: pageURL)),
            pageURL: pageURL,
            isDocumentStartSupported: WebEngine.isAndroidDocumentStartScriptSupported()
        ) { message in
            logger.warning("\(message) for \(pageURL.absoluteString)")
        }
    }

    private func fallbackAndroidCosmeticPlan(for pageURL: URL) -> AndroidCosmeticInjectionPlan {
        guard let provider else {
            return AndroidCosmeticInjectionPlan()
        }
        return WebEngine.androidRedirectFallbackCosmeticPlan(
            rules: provider.cosmeticRules(for: AndroidPageContext(url: pageURL)),
            pageURL: pageURL
        ) { message in
            logger.warning("\(message) for redirected final page \(pageURL.absoluteString)")
        }
    }

    private func registerAndroidDocumentStartCosmeticRule(
        _ rule: AndroidCosmeticRule,
        index: Int,
        for pageURL: URL,
        in view: PlatformWebView
    ) -> ScriptHandler? {
        guard let script = WebEngine.androidContentBlockerStyleInjectionScript(
            cssRules: rule.css,
            styleID: "__skipweb_content_blockers_\(index)",
            frameScope: rule.frameScope,
            urlFilterPattern: rule.urlFilterPattern
        ) else {
            return nil
        }
        let allowedOriginRules: kotlin.collections.MutableSet<String> = kotlin.collections.HashSet()
        for allowedOriginRule in rule.allowedOriginRules {
            allowedOriginRules.add(allowedOriginRule)
        }

        // SKIP INSERT: try {
        // SKIP INSERT:     return androidx.webkit.WebViewCompat.addDocumentStartJavaScript(view, script_0, allowedOriginRules)
        // SKIP INSERT: } catch (t: Throwable) {
        // SKIP INSERT:     logger.warning("Skipping Android cosmetic rule registration for ${pageURL.absoluteString}: ${t.message ?: t}")
        // SKIP INSERT:     return null
        // SKIP INSERT: }
        return WebViewCompat.addDocumentStartJavaScript(view, script, allowedOriginRules)
    }

    private func clearCSS(in view: PlatformWebView) {
        let removalScript = WebEngine.androidContentBlockerStyleRemovalScript(styleID: "__skipweb_content_blockers")
        view.evaluateJavascript(removalScript) { _ in
            logger.debug("Cleared Android content blocker CSS")
        }
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
        engine?.androidContentBlockerController.recoverIfNeeded(for: url)
        engine?.androidContentBlockerController.injectIfNeeded(into: view)
        embeddedNavigationClient?.onPageCommitVisible(view, url)
        legacyNavigationDelegate?.onPageCommitVisible(view, url)
    }

    override func onPageFinished(view: PlatformWebView, url: String) {
        logger.log("onPageFinished: \(url)")
        engine?.androidContentBlockerController.recoverIfNeeded(for: url)
        engine?.androidContentBlockerController.injectIfNeeded(into: view)
        for userScript in config?.userScripts ?? [] {
            if userScript.webKitUserScript.injectionTime == .atDocumentEnd {
                let source = userScript.webKitUserScript.source
                view.evaluateJavascript(source) { _ in
                    logger.debug("Executed user script \(source)")
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
        engine?.androidContentBlockerController.recoverIfNeeded(for: url)
        if !(config?.messageHandlers.isEmpty ?? true) {
            view.evaluateJavascript("""
            if (!window.webkit) window.webkit = {};
            webkit.messageHandlers = new Proxy({}, {
                get: (target, messageHandlerName, receiver) => ({
                    postMessage: (body) => skipWebAndroidMessageHandler.postMessage(String(messageHandlerName), JSON.stringify(body))
                })
            });
        """) { _ in logger.debug("Added webkit.messageHandlers") }
        }
        for userScript in config?.userScripts ?? [] {
            if userScript.webKitUserScript.injectionTime == .atDocumentStart {
                let source = userScript.webKitUserScript.source
                view.evaluateJavascript(source) { _ in
                    logger.debug("Executed user script \(source)")
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
    public var messageHandlers: [String: ((WebViewMessage) async -> Void)]
    public var schemeHandlers: [String: URLSchemeHandler]
    public var uiDelegate: (any SkipWebUIDelegate)?
    public var navigationDelegate: (any SkipWebNavigationDelegate)?
    public var contentBlockers: WebContentBlockerConfiguration?
    public private(set) var contentBlockerSetupErrors: [WebContentBlockerError] = []

    #if SKIP
    /// The Android context to use for creating a web context
    public var context: android.content.Context? = nil
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
        self.messageHandlers = messageHandlers
        self.schemeHandlers = schemeHandlers
        self.uiDelegate = uiDelegate
        self.navigationDelegate = navigationDelegate
        self.contentBlockers = contentBlockers
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
            messageHandlers: messageHandlers,
            schemeHandlers: schemeHandlers,
            uiDelegate: uiDelegate,
            navigationDelegate: navigationDelegate,
            contentBlockers: contentBlockers
        )
        #if SKIP
        copy.context = context
        #endif
        return copy
    }

    #if !SKIP
    /// Create a `WebViewConfiguration` from the properties of this configuration.
    @MainActor public var webViewConfiguration: WebViewConfiguration {
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

        _ = installContentBlockers(into: configuration.userContentController)

        return configuration
    }

    @MainActor
    @discardableResult
    func installContentBlockers(into userContentController: WKUserContentController) -> [WebContentBlockerError] {
        contentBlockerSetupErrors = []
        guard let contentBlockers, !contentBlockers.iOSRuleListPaths.isEmpty else {
            return []
        }

        let prepared = WebContentBlockerStore.prepareRuleLists(from: contentBlockers.iOSRuleListPaths)
        contentBlockerSetupErrors = prepared.errors
        for ruleList in prepared.ruleLists {
            userContentController.add(ruleList)
        }
        WebContentBlockerStore.recordInstallation(count: prepared.ruleLists.count)
        return prepared.errors
    }

    @MainActor private var webKitWebsiteDataStore: WKWebsiteDataStore {
        switch profile {
        case .default:
            return WKWebsiteDataStore.default()
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

    static func prepareRuleLists(from sourcePaths: [String]) -> PreparedContentBlockerRuleLists {
        var ruleLists: [WKContentRuleList] = []
        var errors: [WebContentBlockerError] = []

        let normalizedSourcePaths = normalizedPaths(from: sourcePaths)
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

            let identifier = ruleListIdentifier(for: sourcePath, contentData: fileData)
            nextIdentifiersBySourcePath[sourcePath] = identifier
            staleIdentifiers.remove(identifier)

            if let cachedRuleList = lookupRuleList(identifier: identifier, in: store, errors: &errors) {
                ruleLists.append(cachedRuleList)
                diagnostics.cacheHitIdentifiers.append(identifier)
                continue
            }

            if let compiledRuleList = compileRuleList(identifier: identifier, content: content, sourcePath: sourcePath, in: store, errors: &errors) {
                ruleLists.append(compiledRuleList)
                diagnostics.compiledIdentifiers.append(identifier)
            }
        }

        let activeIdentifiers = Set(nextIdentifiersBySourcePath.values)
        for staleIdentifier in staleIdentifiers.subtracting(activeIdentifiers) {
            removeRuleList(identifier: staleIdentifier, from: store, errors: &errors)
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

    private static func lookupRuleList(identifier: String, in store: WKContentRuleListStore, errors: inout [WebContentBlockerError]) -> WKContentRuleList? {
        switch awaitCallback(description: "lookup \(identifier)") { completion in
            store.lookUpContentRuleList(forIdentifier: identifier) { ruleList, error in
                completion(ruleList, error)
            }
        } {
        case .success(let ruleList):
            return ruleList
        case .failure(let error as WebContentBlockerError):
            errors.append(error)
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain == WKErrorDomain,
               nsError.code == WKError.Code.contentRuleListStoreLookUpFailed.rawValue {
                return nil
            }
            errors.append(.cacheLookupFailed(identifier: identifier, description: error.localizedDescription))
        }
        return nil
    }

    private static func compileRuleList(identifier: String, content: String, sourcePath: String, in store: WKContentRuleListStore, errors: inout [WebContentBlockerError]) -> WKContentRuleList? {
        switch awaitCallback(description: "compile \(sourcePath)") { completion in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: content) { ruleList, error in
                completion(ruleList, error)
            }
        } {
        case .success(let ruleList):
            return ruleList
        case .failure(let error as WebContentBlockerError):
            errors.append(error)
        case .failure(let error):
            errors.append(.compilationFailed(path: sourcePath, description: error.localizedDescription))
        }
        return nil
    }

    private static func removeRuleList(identifier: String, from store: WKContentRuleListStore, errors: inout [WebContentBlockerError]) {
        switch awaitVoidCallback(description: "remove \(identifier)") { completion in
            store.removeContentRuleList(forIdentifier: identifier) { error in
                completion(error)
            }
        } {
        case .success:
            diagnostics.prunedIdentifiers.append(identifier)
        case .failure(let error as WebContentBlockerError):
            errors.append(error)
        case .failure(let error):
            let nsError = error as NSError
            // Failing to delete a stale compiled rule list should not prevent the current rule set from loading.
            if nsError.domain == WKErrorDomain,
               nsError.code == WKError.Code.contentRuleListStoreRemoveFailed.rawValue {
                return
            }
            errors.append(.staleRuleRemovalFailed(identifier: identifier, description: error.localizedDescription))
        }
    }

    private static func awaitCallback<T>(
        description: String,
        operation: (@escaping (T?, Error?) -> Void) -> Void
    ) -> Result<T?, Error> {
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T?, Error>?
        operation { value, error in
            let callbackResult: Result<T?, Error>
            if let error {
                callbackResult = .failure(error)
            } else {
                callbackResult = .success(value)
            }
            lock.lock()
            result = callbackResult
            lock.unlock()
            semaphore.signal()
        }

        let deadline = Date().addingTimeInterval(contentBlockerCallbackTimeout)
        while deadline.timeIntervalSinceNow > 0 {
            if semaphore.wait(timeout: .now()) == .success {
                lock.lock()
                defer { lock.unlock() }
                return result ?? .failure(WebContentBlockerError.operationTimedOut(description))
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.01))
        }

        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(WebContentBlockerError.operationTimedOut(description))
    }

    private static func awaitVoidCallback(
        description: String,
        operation: (@escaping (Error?) -> Void) -> Void
    ) -> Result<Void, Error> {
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        operation { error in
            let callbackResult: Result<Void, Error>
            if let error {
                callbackResult = .failure(error)
            } else {
                callbackResult = .success(())
            }
            lock.lock()
            result = callbackResult
            lock.unlock()
            semaphore.signal()
        }

        let deadline = Date().addingTimeInterval(contentBlockerCallbackTimeout)
        while deadline.timeIntervalSinceNow > 0 {
            if semaphore.wait(timeout: .now()) == .success {
                lock.lock()
                defer { lock.unlock() }
                return result ?? .failure(WebContentBlockerError.operationTimedOut(description))
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.01))
        }

        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(WebContentBlockerError.operationTimedOut(description))
    }

    private static var contentBlockerCallbackTimeout: TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        if let rawValue = environment["SKIPWEB_CONTENT_BLOCKER_TIMEOUT"],
           let timeout = TimeInterval(rawValue),
           timeout > 0 {
            return timeout
        }

        if environment["GITHUB_ACTIONS"] == "true" || environment["CI"] == "true" {
            return 60.0
        }

        return 10.0
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
