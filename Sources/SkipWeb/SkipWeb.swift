// This is free software: you can redistribute and/or modify it
// under the terms of the GNU Lesser General Public License 3.0
// as published by the Free Software Foundation https://fsf.org
import SwiftUI
#if SKIP
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.ui.viewinterop.AndroidView

public struct WebView: View {
    let url: URL
    let enableJavaScript: Bool

    public init(url: URL, enableJavaScript: Bool = true) {
        self.url = url
        self.enableJavaScript = enableJavaScript
    }

    @Composable public override func ComposeContent(context: ComposeContext) {
        AndroidView(factory: { ctx in
            let webView = WebView(ctx)
            webView.webViewClient = WebViewClient()
            webView.settings.javaScriptEnabled = enableJavaScript
            return webView
        }, modifier: context.modifier, update: { webView in
            webView.loadUrl(url.absoluteString)
        })
    }
}
#else
import WebKit

#if canImport(UIKit)
typealias ViewRepresentable = UIViewRepresentable
#elseif canImport(AppKit)
typealias ViewRepresentable = NSViewRepresentable
#endif

public struct WebView: ViewRepresentable {
    let url: URL
    let cfg = WKWebViewConfiguration()

    public init(url: URL, enableJavaScript: Bool = true) {
        self.url = url
        cfg.defaultWebpagePreferences.allowsContentJavaScript = enableJavaScript
    }

    public func makeCoordinator() -> WKWebView {
        WKWebView(frame: .zero, configuration: cfg)
    }

    public func update(webView: WKWebView) {
        webView.load(URLRequest(url: url))
    }

    #if canImport(UIKit)
    public func makeUIView(context: Context) -> WKWebView { context.coordinator }
    public func updateUIView(_ uiView: WKWebView, context: Context) { update(webView: uiView) }
    #elseif canImport(AppKit)
    public func makeNSView(context: Context) -> WKWebView { context.coordinator }
    public func updateNSView(_ nsView: WKWebView, context: Context) { update(webView: nsView) }
    #endif
}
#endif
