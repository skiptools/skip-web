// Copyright 2023-2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if os(iOS) && !SKIP
import XCTest
import WebKit
@testable import SkipWeb

/// Checks compiled WebKit behavior, since accepted rule JSON can still match no domains.
@MainActor
final class WebContentBlockerWhitelistTests: XCTestCase {
    func testCompiledExemptionsMatchExactAndSubdomainPages() async throws {
        let cases: [(String, [String], String)] = [
            ("video.example.com", [], "none"),
            ("video.example.com", ["example.com", "*.example.com"], "block"),
            ("example.com", ["example.com", "*.example.com"], "block"),
            ("example.com", ["*.example.com"], "none"),
            ("video.example.com", ["example.com"], "none"),
            ("badexample.com", ["example.com", "*.example.com"], "none"),
            ("example.com.evil.test", ["example.com", "*.example.com"], "none")
        ]
        for (host, domains, expected) in cases {
            let content = WebContentBlockerConfiguration.augmentedIOSRuleListContent(
                ##"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"#target"}}]"##,
                whitelistedDomains: domains)
            let identifier = "whitelist-test-\(UUID().uuidString)"
            let ruleStore = WKContentRuleListStore.default()!
            let rule = try await ruleStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: content)
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.add(try XCTUnwrap(rule))
            let webView = WKWebView(frame: .zero, configuration: configuration)
            let loader = WhitelistPageLoader()
            webView.navigationDelegate = loader
            await loader.load(webView, host: host)
            let display = try await webView.evaluateJavaScript("getComputedStyle(document.getElementById('target')).display")
            XCTAssertEqual(display as? String, expected, "host=\(host) domains=\(domains)")
            try await ruleStore.removeContentRuleList(forIdentifier: identifier)
        }
    }

    func testPopupPatternsMatchSourceSitesAndRejectLookalikeHosts() {
        let patterns = WebContentBlockerConfiguration.whitelistTopURLs(from: ["example.com"], includesBareSubdomains: true)
        for url in ["https://example.com/", "https://video.example.com:8443/page"] {
            XCTAssertTrue(patterns.contains { url.range(of: $0, options: .regularExpression) != nil })
        }
        for url in ["https://badexample.com/", "https://example.com.evil.test/", "https://example.com@evil.test/"] {
            XCTAssertFalse(patterns.contains { url.range(of: $0, options: .regularExpression) != nil })
        }
    }
}

@MainActor
private final class WhitelistPageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func load(_ webView: WKWebView, host: String) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString("<html><body><div id='target'>Target</div></body></html>",
                baseURL: URL(string: "https://\(host)/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
}
#endif
