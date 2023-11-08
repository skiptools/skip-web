// This is free software: you can redistribute and/or modify it
// under the terms of the GNU Lesser General Public License 3.0
// as published by the Free Software Foundation https://fsf.org
import SwiftUI
#if SKIP
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.ui.viewinterop.AndroidView

struct WebView: View {
    let url: URL
    let enableJavaScript: Bool

    init(url: URL, enableJavaScript: Bool = true) {
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

struct WebView: ViewRepresentable {
    let url: URL
    let cfg = WKWebViewConfiguration()

    init(url: URL, enableJavaScript: Bool = true) {
        self.url = url
        cfg.defaultWebpagePreferences.allowsContentJavaScript = enableJavaScript
    }

    func makeCoordinator() -> WKWebView {
        WKWebView(frame: .zero, configuration: cfg)
    }

    func update(webView: WKWebView) {
        webView.load(URLRequest(url: url))
    }

    #if canImport(UIKit)
    func makeUIView(context: Context) -> WKWebView { context.coordinator }
    func updateUIView(_ uiView: WKWebView, context: Context) { update(webView: uiView) }
    #elseif canImport(AppKit)
    func makeNSView(context: Context) -> WKWebView { context.coordinator }
    func updateNSView(_ nsView: WKWebView, context: Context) { update(webView: nsView) }
    #endif
}
#endif
