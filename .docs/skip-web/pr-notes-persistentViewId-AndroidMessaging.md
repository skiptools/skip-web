# SkipWeb Persistent View ID and Android Messaging PR Notes

## Summary

This PR adds two public API surfaces to `SkipWeb`:

- persistent WebView identity for apps that need multiple live browser tabs
- bridge-safe JavaScript-to-app messaging on Android

The persistent view ID work gives tabbed browser features a stable way to keep one `WebEngine` per tab while SwiftUI views mount and unmount. Think of it as a parking spot for a browser runtime: a tab passes the same ID each time it appears, and SkipWeb reuses the existing engine instead of creating a fresh WebView.

The Android messaging work adds a new public script-message API because the previous `messageHandlers` API exposed a Swift closure shape that was not bridge-friendly. The new API separates registration from delivery: apps register handler names and receive bridge-safe `WebViewScriptMessage` values through a delegate.

## Public API Changes

### Persistent WebView Identity

`WebView` now accepts a stable optional ID:

```swift
WebView(
    configuration: configuration,
    navigator: navigator,
    url: tab.url,
    state: $state,
    persistentWebViewID: tab.id.uuidString
)
```

When `persistentWebViewID` is present, SkipWeb stores and reuses a cached `WebEngine` for that ID. This is intended for multi-tab browser apps where each tab needs to preserve page state, history, scroll position, and in-page runtime state across view recreation.

The public initializer changed from:

```swift
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
)
```

to:

```swift
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
    shouldOverrideUrlLoading: ((_ url: URL) -> Bool)? = nil,
    persistentWebViewID: String? = nil
)
```

SkipWeb also adds explicit cache eviction APIs:

```swift
@MainActor
public static func removePersistentWebView(id: String)

@MainActor
public static func removePersistentWebViews(ids: [String])
```

Apps should call these when a tab closes or when a background tab should no longer keep a live engine in memory.

### Bridge-Safe Script Messages

SkipWeb now exposes a bridge-safe script message envelope:

```swift
public struct WebViewScriptMessage: Equatable, Sendable {
    public let name: String
    public let bodyJSON: String
    public let sourceURL: String?
    public let isMainFrame: Bool?

    public init(
        name: String,
        bodyJSON: String,
        sourceURL: String? = nil,
        isMainFrame: Bool? = nil
    )
}
```

Apps receive messages through a main-actor delegate:

```swift
@MainActor
public protocol WebViewScriptMessageDelegate: AnyObject {
    func webEngine(_ webEngine: WebEngine, didReceiveScriptMessage message: WebViewScriptMessage)
}
```

`WebEngineConfiguration` now has explicit message registration and delivery properties:

```swift
public var scriptMessageHandlerNames: [String]
public var scriptMessageDelegate: (any WebViewScriptMessageDelegate)?
```

The initializer now accepts these values:

```swift
public init(
    ...,
    userScripts: [WebViewUserScript] = [],
    scriptMessageHandlerNames: [String] = [],
    scriptMessageDelegate: (any WebViewScriptMessageDelegate)? = nil,
    messageHandlers: [String: ((WebViewMessage) async -> Void)] = [:],
    ...
)
```

The old closure-based API remains available for source compatibility, but it is deprecated:

```swift
@available(*, deprecated, message: "Use scriptMessageHandlerNames and scriptMessageDelegate.")
public var messageHandlers: [String: ((WebViewMessage) async -> Void)]
```

The new API is the preferred path because it only uses bridge-safe values:

- `name` is the registered message handler name.
- `bodyJSON` is the JSON payload posted by JavaScript.
- `sourceURL` is the sending frame URL when available.
- `isMainFrame` reports whether the message came from the main frame when available.

Example:

```swift
@MainActor
final class ScriptSink: WebViewScriptMessageDelegate {
    func webEngine(_ webEngine: WebEngine, didReceiveScriptMessage message: WebViewScriptMessage) {
        handleMessage(name: message.name, json: message.bodyJSON)
    }
}

let sink = ScriptSink()
let configuration = WebEngineConfiguration(
    scriptMessageHandlerNames: ["native"],
    scriptMessageDelegate: sink
)
```

JavaScript can post through the same WebKit-style shape on both platforms:

```javascript
window.webkit.messageHandlers.native.postMessage({
  kind: "ready",
  href: window.location.href
});
```

## Android Behavior

On Android, SkipWeb installs a `window.webkit.messageHandlers` facade that forwards messages to the native app through the bridge-safe delegate path. When AndroidX `DOCUMENT_START_SCRIPT` support is available, the facade is installed at document start so main-frame and iframe messages can be delivered early. When that feature is unavailable, SkipWeb falls back to lifecycle-time injection, which is best-effort and mainly covers the main frame.

This change is specifically in support of JavaScript-to-app delivery. Native-to-JavaScript execution continues to use the existing `WebViewNavigator.evaluateJavaScript(_:)` / `WebEngine.evaluate(js:)` API.

## Device Tests

The sandbox lab `Skip Web JavaScript Bridge Lab` defines the following suite cases:

- `evaluate_main_frame`: evaluates JavaScript in the main document and verifies the returned probe.
- `evaluate_same_origin_subframe_via_dom`: evaluates JavaScript that reaches a same-origin iframe helper and verifies the subframe probe.
- `message_main_frame_manual`: sends a JavaScript message from the main document and waits for the native delegate to receive it.
- `message_subframe_manual`: sends a JavaScript message from a same-origin iframe and waits for the native delegate to receive it.
- `user_script_main_frame`: verifies main-frame and all-frame user scripts mark the main document.
- `user_script_all_frames_subframe`: verifies all-frame user scripts reach the iframe while main-frame-only scripts do not.
- `message_frame_metadata`: verifies native script-message metadata distinguishes main-frame and subframe messages when metadata is available.

