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
public class WebEngineConfiguration {
    public var contentBlockers: WebContentBlockerConfiguration?
    public var contentBlockerRuntime: WebContentBlockerRuntime?
    public private(set) var contentBlockerSetupErrors: [WebContentBlockerError]

    @MainActor public static func iOSClearContentBlockerCache() throws
    @MainActor public func iOSPrepareContentBlockers() async -> [WebContentBlockerError]
    @MainActor public func makeWebViewConfiguration() async -> WebViewConfiguration
}
```

```swift
public class WebEngine {
    public private(set) var contentBlockerRuntime: WebContentBlockerRuntime?
    public private(set) var contentBlockerSetupErrors: [WebContentBlockerError]

    public func awaitContentBlockerSetup() async -> [WebContentBlockerError]
    @MainActor public func reapplyContentBlockers() async -> [WebContentBlockerError]
}
```

## Sharing Prepared Rules Across Web Views

`contentBlockers` remains the simple compatibility API. A configuration using that property
creates an implicit runtime. After changing `contentBlockers` on an existing engine, call
`reapplyContentBlockers()`; setting the property to `nil` and reapplying removes installed rules.

Use an explicit `WebContentBlockerRuntime` when independently created engines or tabs should share
one prepared rule snapshot:

```swift
@MainActor public final class WebContentBlockerRuntime {
    public private(set) var configuration: WebContentBlockerConfiguration
    public private(set) var revision: Int

    public init(configuration: WebContentBlockerConfiguration)
    public func prepare() async -> [WebContentBlockerError]
    public func reapply(
        configuration: WebContentBlockerConfiguration,
        reloadLiveWebViews: Bool = false
    ) async -> [WebContentBlockerError]
}
```

```swift
let runtime = WebContentBlockerRuntime(configuration: blockers)
_ = await runtime.prepare()

let firstConfiguration = WebEngineConfiguration(contentBlockerRuntime: runtime)
let secondConfiguration = WebEngineConfiguration(contentBlockerRuntime: runtime)
```

The runtime is also shared with popup children created through
`PlatformCreateWindowContext.makeChildWebEngine()`. Calling `reapply` replaces the complete
configuration and updates every live engine attached to the runtime. The runtime tracks engines
weakly, so it does not keep web views alive.

With `reloadLiveWebViews: false`, new request rules apply to later loads; Android cosmetic rules
are also refreshed on the current page. Use `true` when every attached current page must reload.

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

Android also evaluates HTTP(S) main-frame navigations through the configured
`AndroidContentBlockingProvider`. These requests use `.document` as their resource type and carry
the currently displayed page in `mainDocumentURL`, allowing a provider to distinguish the source
page from the requested destination. Non-HTTP(S) schemes bypass this content-rule check.

Before a new popup has loaded a page, its current URL may be missing or empty. SkipWeb passes
`mainDocumentURL: nil` in either case, avoiding an empty URL that cannot be converted to native
Swift. The destination still goes through the provider's normal allow/block decision.

When the provider returns `.block`, SkipWeb cancels the navigation before the destination document
loads. A `WebView` can observe that cancellation through the Android-only
`onContentRuleBlockedNavigation` callback:

```swift
WebView(
    configuration: configuration,
    onContentRuleBlockedNavigation: { blockedURL in
        showBlockedNavigationNotice(for: blockedURL)
    }
)
```

The callback reports the rejected destination URL. It does not run on Apple platforms, where the
initializer remains source compatible because the closure defaults to `nil`.

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
    public var urlFilterIsCaseSensitive: Bool
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
        preferredTiming: AndroidCosmeticInjectionTiming = .documentStart,
        urlFilterIsCaseSensitive: Bool = true
    )
}
```

Think of the Android cosmetic API as "selectors plus guards". `SkipWeb` is responsible for turning those selectors into `display: none !important` when a frame actually matches.

`urlFilterIsCaseSensitive` defaults to `true` for compatibility with existing custom
providers. Set it explicitly when translating a source rule's case-sensitivity setting.
It applies to both document-start and lifecycle injection.

For `ifDomainList` and `unlessDomainList`, `example.com` matches only that host,
`*.example.com` matches only its subdomains, and `*example.com` matches both the host
and its subdomains. Matching respects domain-label boundaries: `*example.com` does
not match `badexample.com`.

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
- expose the fixed document-start blocker hook to the frame
- return CSS only when the frame origin matches `https://*.doubleclick.net`
- apply the CSS only when the current frame URL also matches `.*\\/ad-frame\\.html`

When Android document-start scripts are supported, SkipWeb installs one fixed hook per web view.
The shared runtime evaluates `allowedOriginRules`, `urlFilterPattern`, `ifDomainList`,
`unlessDomainList`, and `frameScope` against the current frame before returning CSS. Rule count no
longer determines the number of document-start registrations. Older runtimes use lifecycle
injection as a fallback.

### Android inline display enforcement

Android also derives a small JavaScript fallback from the generated cosmetic CSS. If an
element matches a `display: none !important` rule but has a conflicting inline important
display value, SkipWeb sets its inline display to `none !important`. Ordinary matching
elements remain handled by the stylesheet. Providers supply the same selectors and guards:

```swift
AndroidCosmeticRule(hiddenSelectors: [".ad-slot", "iframe[style^=\"width: 280px\"]"])
```

One helper per document coordinates document-start and lifecycle styles. It parses grouped
selectors through the browser's CSSOM, scans inline styles once when blocking starts, and
batches later mutations on a 16 ms timer. It scans added subtrees once and rechecks only
inline-important candidates. Ancestor, sibling, and descendant changes can affect matching,
so those candidates are rechecked even when the changed node is not itself a candidate.
SkipWeb's own writes do not schedule further observer work.

Matching uses authored style attributes before applying overrides. Rule replacement,
element detachment, and removal of the last applicable rule restore owned display values,
preserving later page edits to other properties. Removing the last stylesheet also stops
the observer and cancels pending work. A document-start injection waits for the document
root if necessary; removed or text-edited blocker stylesheets are repaired.

This is a DOM-based fallback, not user-origin CSS priority. Page rewrites can be visible
until the next batch runs. It handles generated top-level element-hiding rules; pseudo-elements,
shadow trees, arbitrary declarations, and selector state changes without DOM mutations
(such as hover or focus alone) retain ordinary CSS behavior. It runs only in frames that
receive cosmetic CSS through the existing injection paths. Mutation records cannot distinguish
a page deliberately writing the same `display: none !important` value from an unrelated style
edit that retains SkipWeb's value; cleanup treats an unchanged display as still owned.

The DOM regression tests use the production script in macOS WKWebView with no extra test
dependencies. Run `swift test --filter AndroidCosmeticStyleTests`. They cover inline priority,
late insertion, page rewrites, style-dependent selectors, replacement/cleanup, and operation
counts for approximately 14,400 selectors and 1,000 elements. Android's existing
`WebContentBlockerTests` cover rule generation and injection guards.

Think of Android cosmetics as two buckets:
- `persistentCosmeticRules`: a long-lived baseline captured by the runtime revision
- `navigationCosmeticRules(for:)`: page-specific CSS evaluated for the current page

This split is mainly about avoiding repeated work. Rules that are effectively global to the
browsing session belong in `persistentCosmeticRules`; rules that depend on the current page URL,
host, or dynamic match context belong in `navigationCosmeticRules(for:)`. Call runtime `reapply`
after changing the persistent baseline.

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
