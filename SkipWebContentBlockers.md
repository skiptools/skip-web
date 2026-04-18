# SkipWeb Content Blockers

`SkipWeb` exposes portable content-blocking hooks through `WebEngineConfiguration.contentBlockers`.

Use this guide when you need:
- a quick integration example
- the current public API shape for blocker-related types
- platform notes for iOS rule lists, Android request/cosmetic blocking, and domain whitelisting

## Quick Usage Example

```swift
import Foundation
import WebKit
import SkipWeb

struct ContentBlockingProvider: AndroidContentBlockingProvider {
    var persistentCosmeticRules: [AndroidCosmeticRule] {
        [
            AndroidCosmeticRule(hiddenSelectors: [".ad-banner"])
        ]
    }

    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision {
        if request.url.host?.contains("ads") == true {
            return .block
        }
        return .allow
    }

    func navigationCosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule] {
        [
            AndroidCosmeticRule(
                hiddenSelectors: [".ad-slot", ".tracking-frame"],
                urlFilterPattern: ".*\\/ad-frame\\.html",
                allowedOriginRules: ["https://*.doubleclick.net"],
                frameScope: .subframesOnly
            ),
            AndroidCosmeticRule(
                hiddenSelectors: [".generic-overlay", "#sponsored-modal"],
                preferredTiming: .pageLifecycle,
                frameScope: .mainFrameOnly
            )
        ]
    }
}

let configuration = WebEngineConfiguration(
    contentBlockers: WebContentBlockerConfiguration(
        iOSRuleListPaths: ["/path/to/content-blockers.json"],
        whitelistedDomains: ["example.com", "*.example.org"],
        popupWhitelistedSourceDomains: ["example.com"],
        androidMode: .custom(ContentBlockingProvider())
    )
)

try WebEngineConfiguration.iOSClearContentBlockerCache()
_ = await configuration.iOSPrepareContentBlockers()
let webViewConfiguration = await configuration.makeWebViewConfiguration()
let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
let engine = WebEngine(configuration: configuration, webView: webView)
_ = await engine.awaitContentBlockerSetup()
```

## Configuration Surface

```swift
public struct WebContentBlockerConfiguration {
    public var iOSRuleListPaths: [String]
    public var whitelistedDomains: [String]
    public var popupWhitelistedSourceDomains: [String]
    public var androidMode: AndroidContentBlockingMode

    public init(
        iOSRuleListPaths: [String] = [],
        whitelistedDomains: [String] = [],
        popupWhitelistedSourceDomains: [String] = [],
        androidMode: AndroidContentBlockingMode = .disabled
    )
}
```

```swift
public final class WebEngineConfiguration {
    public var contentBlockers: WebContentBlockerConfiguration?
    public private(set) var contentBlockerSetupErrors: [WebContentBlockerError]

    @MainActor public static func iOSClearContentBlockerCache() throws
    @MainActor public func iOSPrepareContentBlockers() async -> [WebContentBlockerError]
    @MainActor public func makeWebViewConfiguration() async -> WebViewConfiguration
}
```

```swift
public final class WebEngine {
    public private(set) var contentBlockerSetupErrors: [WebContentBlockerError]

    public func awaitContentBlockerSetup() async -> [WebContentBlockerError]
}
```

## Android Content Blocking

### Mode And Provider

```swift
public protocol AndroidContentBlockingProvider {
    var persistentCosmeticRules: [AndroidCosmeticRule] { get }
    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision
    func navigationCosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule]
}
```

```swift
public enum AndroidContentBlockingMode {
    case disabled
    case custom(any AndroidContentBlockingProvider)
}
```

### Request Blocking

```swift
public enum AndroidRequestBlockDecision: Equatable, Sendable {
    case allow
    case block
}
```

```swift
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
```

```swift
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
    )
}
```

### Cosmetic Blocking

```swift
public struct AndroidPageContext: Equatable, Sendable {
    public var url: URL
    public var host: String?

    public init(url: URL, host: String? = nil)
}
```

```swift
public enum AndroidCosmeticFrameScope: String, CaseIterable, Hashable, Sendable {
    case mainFrameOnly
    case subframesOnly
    case allFrames
}
```

```swift
public enum AndroidCosmeticInjectionTiming: String, CaseIterable, Hashable, Sendable {
    case documentStart
    case pageLifecycle
}
```

```swift
public struct AndroidCosmeticRule: Equatable, Sendable {
    public var hiddenSelectors: [String]
    public var urlFilterPattern: String?
    public var allowedOriginRules: [String]
    public var ifDomainList: [String]
    public var unlessDomainList: [String]
    public var frameScope: AndroidCosmeticFrameScope
    public var preferredTiming: AndroidCosmeticInjectionTiming

    public init(
        hiddenSelectors: [String] = [],
        urlFilterPattern: String? = nil,
        allowedOriginRules: [String] = ["*"],
        ifDomainList: [String] = [],
        unlessDomainList: [String] = [],
        frameScope: AndroidCosmeticFrameScope = .mainFrameOnly,
        preferredTiming: AndroidCosmeticInjectionTiming = .documentStart
    )
}
```

Think of the Android cosmetic API as "selectors plus guards". `SkipWeb` is responsible for turning those selectors into `display: none !important` when a frame actually matches.

Practical example:

```swift
AndroidCosmeticRule(
    hiddenSelectors: [".ad-slot", ".tracking-frame"],
    urlFilterPattern: ".*\\/ad-frame\\.html",
    allowedOriginRules: ["https://*.doubleclick.net"],
    frameScope: .subframesOnly
)
```

Think of that rule as:
- register this document-start script only for `https://*.doubleclick.net`
- then, inside those matching subframes, only apply the CSS when the current frame URL also matches `.*\\/ad-frame\\.html`

`allowedOriginRules` is the registration-time scope. Android's `WebViewCompat.addDocumentStartJavaScript(...)` requires those origin rules up front, so SkipWeb cannot infer them later inside the script. `urlFilterPattern`, `ifDomainList`, and `unlessDomainList` are the runtime frame guards checked by the injected script after it has been installed.

Think of Android cosmetics as two buckets:
- `persistentCosmeticRules`: a long-lived baseline registered once per `WebView` and reused across navigations when it does not change
- `navigationCosmeticRules(for:)`: page-specific CSS that is refreshed for each main-frame navigation when needed

This split is mainly about avoiding repeated work. Think of it as "install the baseline once, then only swap the delta when the page changes." Rules that are effectively global to the browsing session belong in `persistentCosmeticRules`; rules that depend on the current page URL, host, or dynamic match context belong in `navigationCosmeticRules(for:)`.

Whitelist opt-out is enforced inside `SkipWeb`'s Android controller. If the current main-frame URL matches `whitelistedDomains`, neither the persistent baseline nor the per-navigation delta is applied.

## iOS Rule-List Notes

- `iOSRuleListPaths` points to WebKit content-blocker JSON files that are compiled into `WKContentRuleList` values and installed by SkipWeb.
- SkipWeb persists compiled iOS rule lists in a cache keyed by source path plus effective compiled content.
- `WebEngineConfiguration.iOSClearContentBlockerCache()` explicitly removes the persisted iOS compiled rule-list store.
- `iOSPrepareContentBlockers()` lets apps prewarm iOS rule-list compilation without touching WebKit types directly.
- `contentBlockerSetupErrors` is populated after `iOSPrepareContentBlockers()`, after `makeWebViewConfiguration()`, and after `awaitContentBlockerSetup()`.
- When you create a `WebEngine` with an already-constructed `WKWebView`, SkipWeb installs configured content blockers into that supplied web view as well.

### Whitelist Injection

`whitelistedDomains` accepts WebKit-style host entries such as `example.com` and `*.example.com`. SkipWeb normalizes those entries, then appends an in-memory exemption rule to each compiled iOS rule file when the whitelist is non-empty.

Generated rule shape:

```json
{
  "comment": "user-injected domain exemptions (whitelisted domains)",
  "trigger": {
    "url-filter": ".*",
    "if-domain": ["example.com", "*.example.org"]
  },
  "action": {
    "type": "ignore-previous-rules"
  }
}
```

Caller-owned rule files on disk are not modified.

### Popup Whitelist Injection

`popupWhitelistedSourceDomains` is the popup-only override path. SkipWeb normalizes those entries and appends an in-memory popup exemption rule to each compiled iOS rule file when the popup whitelist is non-empty.

Generated rule shape:

```json
{
  "comment": "user-injected popup exemptions (allowed source domains)",
  "trigger": {
    "url-filter": ".*",
    "resource-type": ["popup"],
    "if-top-url": [
      "https://example.com/*",
      "https://*.example.com/*"
    ]
  },
  "action": {
    "type": "ignore-previous-rules"
  }
}
```

This is source-site based, not popup-target based. Think of it as "allow popups from this site" rather than "allow popups to this destination."

## Cross-Platform Whitelist Semantics

- `whitelistedDomains` entries are trimmed, lowercased, deduplicated, and sorted before use.
- `popupWhitelistedSourceDomains` entries are trimmed, lowercased, deduplicated, and sorted before use.
- Exact entries like `example.com` match only that host.
- Wildcard entries like `*.example.com` match subdomains of `example.com`.
- Exact entries do not implicitly match subdomains.
- On Android, matching whitelisted page domains bypass request blocking and suppress cosmetic rules for the current page while leaving the caller's custom provider unchanged for non-whitelisted domains.
- `popupWhitelistedSourceDomains` uses site-level matching instead of exact-host matching: a bare entry like `example.com` covers both `example.com` and common subdomains such as `www.example.com`, while `*.example.com` remains subdomains-only.
- On Android, matching popup source domains bypass popup blocking only; normal request and cosmetic blocking still use `whitelistedDomains`.

## Error Reporting

```swift
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
}
```
