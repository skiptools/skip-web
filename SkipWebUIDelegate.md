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
- platform-safe child engine construction with `PlatformWebView`, an alias for `WkWebView` (iOS) and `WebView` (Android)

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
        #if os(Android)
        return MainActor.assumeIsolated {
            WebEngine(configuration: WebEngineConfiguration())
        }
        #else
        return MainActor.assumeIsolated {
            let child = platformContext.makeChildWebEngine()
            return child
        }
        #endif
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

## Notes

- Keep delegate method signatures exactly aligned with the protocol.
- Keep the delegate class shape simple and direct.
- On iOS, WebKit requires the returned child to be initialized with the exact configuration supplied to `WKUIDelegate.createWebViewWith`.
- If this contract is violated, WebKit can raise `NSInternalInconsistencyException` with: `Returned WKWebView was not created with the given configuration.`
- For iOS popup creation, return a child created via `platformContext.makeChildWebEngine(...)`.
- `makeChildWebEngine()` mirrors the parent `WebEngineConfiguration` and inspectability by default. Pass an explicit configuration only when you intentionally want different child behavior.
- `makeChildWebEngine()` does not automatically copy platform delegate assignments (`WKUIDelegate`, `WKNavigationDelegate`) from the parent web view; assign those explicitly when needed.
- `PlatformCreateWindowContext` aliases `WebKitCreateWindowParams` on iOS and `AndroidCreateWindowParams` on Android.
