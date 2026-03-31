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
    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision {
        if request.url.host?.contains("ads") == true {
            return .block
        }
        return .allow
    }

    func cosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule] {
        [
            AndroidCosmeticRule(hiddenSelectors: [".ad-banner"]),
            AndroidCosmeticRule(
                hiddenSelectors: [".ad-slot", ".tracking-frame"],
                urlFilterPattern: ".*\\/ad-frame\\.html",
                allowedOriginRules: ["https://*.doubleclick.net"],
                frameScope: .subframesOnly
            ),
            AndroidCosmeticRule(
                css: ["body.modal-open { overflow: auto !important; }"],
                preferredTiming: .pageLifecycle
            )
        ]
    }
}

let configuration = WebEngineConfiguration(
    contentBlockers: WebContentBlockerConfiguration(
        iOSRuleListPaths: ["/path/to/content-blockers.json"],
        whitelistedDomains: ["example.com", "*.example.org"],
        androidMode: .custom(ContentBlockingProvider())
    )
)

try WebEngineConfiguration.clearContentBlockerCache()
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
    public var androidMode: AndroidContentBlockingMode
    @available(*, deprecated, message: "Use androidMode with AndroidContentBlockingMode.custom(...) instead.")
    public var androidRequestBlocker: (any AndroidRequestBlocker)?
    @available(*, deprecated, message: "Use androidMode with AndroidContentBlockingMode.custom(...) instead.")
    public var androidCosmeticBlocker: (any AndroidCosmeticBlocker)?

    public init(
        iOSRuleListPaths: [String] = [],
        whitelistedDomains: [String] = [],
        androidMode: AndroidContentBlockingMode = .disabled,
        androidRequestBlocker: (any AndroidRequestBlocker)? = nil,
        androidCosmeticBlocker: (any AndroidCosmeticBlocker)? = nil
    )
}
```

```swift
public final class WebEngineConfiguration {
    public var contentBlockers: WebContentBlockerConfiguration?
    public private(set) var contentBlockerSetupErrors: [WebContentBlockerError]

    @MainActor public static func clearContentBlockerCache() throws
    @MainActor public func makeWebViewConfiguration() async -> WebViewConfiguration
    @MainActor public func installContentBlockers(
        into userContentController: WKUserContentController
    ) async -> [WebContentBlockerError]
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
    func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision
    func cosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule]
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

```swift
public protocol AndroidRequestBlocker {
    func decision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision
}
```

`AndroidRequestBlocker` remains available as a deprecated compatibility shim for one release, but the primary API is `androidMode: .custom(...)`.

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
    )

    public init(
        hiddenSelectors: [String],
        urlFilterPattern: String? = nil,
        allowedOriginRules: [String] = ["*"],
        frameScope: AndroidCosmeticFrameScope = .mainFrameOnly,
        preferredTiming: AndroidCosmeticInjectionTiming = .documentStart
    )
}
```

```swift
public protocol AndroidCosmeticBlocker {
    func cosmetics(for page: AndroidPageContext) -> [AndroidCosmeticRule]
}
```

`AndroidCosmeticBlocker` remains available as a deprecated compatibility shim for one release, but the primary API is `androidMode: .custom(...)`.

## iOS Rule-List Notes

- `iOSRuleListPaths` points to WebKit content-blocker JSON files that are compiled into `WKContentRuleList` values and installed on the `WKUserContentController`.
- SkipWeb persists compiled iOS rule lists in a cache keyed by source path plus effective compiled content.
- `WebEngineConfiguration.clearContentBlockerCache()` explicitly removes the persisted iOS compiled rule-list store.
- `contentBlockerSetupErrors` is populated after `makeWebViewConfiguration()` and after `awaitContentBlockerSetup()`.
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

## Cross-Platform Whitelist Semantics

- `whitelistedDomains` entries are trimmed, lowercased, deduplicated, and sorted before use.
- Exact entries like `example.com` match only that host.
- Wildcard entries like `*.example.com` match subdomains of `example.com`.
- Exact entries do not implicitly match subdomains.
- On Android, matching whitelisted page domains bypass request blocking and suppress cosmetic rules for the current page while leaving the caller's custom provider unchanged for non-whitelisted domains.

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
