# SkipWebUIDelegate

`SkipWebUIDelegate` is the popup/window-creation delegate API for `SkipWeb`.
Assign it through `WebEngineConfiguration.uiDelegate` when you need to control child-window behavior (`target=_blank`, `window.open`, multi-window flows).

## Protocol

```swift
public protocol SkipWebUIDelegate: AnyObject {
    func webView(
        _ webView: WebView,
        createWebViewWith request: WebWindowRequest,
        platformContext: PlatformCreateWindowContext
    ) -> WebEngine?

    func webViewDidClose(_ webView: WebView, child: WebEngine)
}
```

## Behavior

- `webView(_:createWebViewWith:platformContext:)`
  - Return `nil` to deny popup creation.
  - Return a child `WebEngine` to allow popup creation.
  - Without `WebEngineConfiguration.uiDelegate`, `_blank` / `window.open(...)` uses platform fallback behavior:
    iOS denies the popup request, while Android may navigate the current `WebView`.
  - `request.targetURL` may be `nil` on Android at creation time.
- `webViewDidClose(_:child:)`
  - Called when a previously-created child window is closed via javascript (`window.close()`).

## Platform Mapping

- iOS
  - create callback is wired from `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)`
  - close callback is wired from `WKUIDelegate.webViewDidClose(_:)`
- Android
  - create callback is wired from `WebChromeClient.onCreateWindow`
  - close callback is wired from `WebChromeClient.onCloseWindow`

## Usage Example

The example below is inspired by the sandbox experiment and demonstrates:
- a direct `SkipWebUIDelegate` implementation
- allowing popup creation by returning a child engine
- optional callback hooks for host UI/logging
- platform-safe child engine construction through `PlatformCreateWindowContext`

```swift
import Foundation
// Need to use @preconcurrency here because Type 'WebEngine' does not conform to the 'Sendable' protocol
@preconcurrency import SkipWeb

/* SKIP @bridge */
public final class PopupDelegateProbe: NSObject, SkipWebUIDelegate {
    // SKIP @nobridge
    var onCreate: ((WebWindowRequest, WebEngine) -> Void)?

    // SKIP @nobridge
    var onClose: ((WebView, WebEngine) -> Void)?

    /* SKIP @bridge */
    public func webView(
        _ webView: WebView,
        createWebViewWith request: WebWindowRequest,
        platformContext: PlatformCreateWindowContext
    ) -> WebEngine? {
        let child = Self.makeChildEngine(platformContext: platformContext)
        onCreate?(request, child)
        return child
    }

    /* SKIP @bridge */
    public func webViewDidClose(_ webView: WebView, child: WebEngine) {
        onClose?(webView, child)
    }

    private static func makeChildEngine(platformContext: PlatformCreateWindowContext) -> WebEngine {
        return MainActor.assumeIsolated {
            platformContext.makeChildWebEngine()
        }
    }
}
```

Attach the delegate to your configuration:

```swift
import SwiftUI
@preconcurrency import SkipWeb

struct PopupHostView: View {
    private let delegate = PopupDelegateProbe()

    @State internal var navigator = WebViewNavigator()
    @State internal var state = WebViewState()
    @State internal var configuration: WebEngineConfiguration

    init() {
        let config = WebEngineConfiguration(
            javaScriptEnabled: true,
            javaScriptCanOpenWindowsAutomatically: true
        )
        config.uiDelegate = delegate
        _configuration = State(initialValue: config)
    }

    var body: some View {
        WebView(
            configuration: configuration,
            navigator: navigator,
            url: URL(string: "https://example.com")!,
            state: $state
        )
    }
}
```

## Handling a blocked Android popup

A content rule can reject a popup’s first HTTP(S) main-frame navigation before the child
mounts in a `WebView`. **Only Android calls** the child navigation delegate’s
`webEngineDidBlockContentRuleNavigation(_:to:)` method. It receives the child engine and
the rejected URL. The method is declared on the shared `SkipWebNavigationDelegate`
protocol, so a cross-platform delegate can implement it without a platform guard.

Assign the delegate to the child’s `WebEngineConfiguration.navigationDelegate` when
creating the popup. For example, a delegate tracking pending windows can handle the block as follows.

```swift
func webEngineDidBlockContentRuleNavigation(_ engine: WebEngine, to url: URL) -> Bool {
    pendingPopups.finishBlockedWindow(for: engine, destination: url)
    return true
}
```

Here `pendingPopups` is the caller’s tracker. It can release the pending child and cancel
its timer even when several children requested the same URL. Returning `true` consumes
the notification. Returning `false` (the default) forwards it to the opener’s
`onContentRuleBlockedNavigation` callback, if set. Either way, the navigation is already
blocked. Once the child mounts, its own `WebView.onContentRuleBlockedNavigation` receives
subsequent blocks.

## Notes

- Keep delegate method signatures exactly aligned with the protocol.
- Keep the delegate class shape simple and direct.
- On iOS, WebKit requires the returned child to be initialized with the exact configuration supplied to `WKUIDelegate.createWebViewWith`.
- If this contract is violated, WebKit can raise `NSInternalInconsistencyException` with: `Returned WKWebView was not created with the given configuration.`
- On both platforms, prefer returning a child created via `platformContext.makeChildWebEngine(...)`.
- `makeChildWebEngine()` mirrors the parent `WebEngineConfiguration` by default, including its profile and resolved content-blocker runtime. On iOS it also preserves WebKit's required configuration identity and mirrors inspectability.
- Pass an explicit configuration only when you intentionally want different child behavior. An explicit content-blocker runtime on that configuration is preserved.
- Because popup children share the parent's resolved content-blocker runtime by default, later runtime reapplications update the child too.
- `makeChildWebEngine()` does not automatically copy platform delegate assignments (`WKUIDelegate`, `WKNavigationDelegate`) from the parent web view; assign those explicitly when needed.
- On Android, after your delegate returns a child `WebEngine`, SkipWeb also mirrors key parent web settings and verifies parent `WebProfile` inheritance; if profile inheritance fails, popup creation is denied.
- `PlatformCreateWindowContext` aliases `WebKitCreateWindowParams` on iOS and `AndroidCreateWindowParams` on Android.
