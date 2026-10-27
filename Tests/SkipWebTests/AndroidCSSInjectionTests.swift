// Copyright 2026-2026 Skip
// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import SkipWeb

#if SKIP
/// Checks the CSS literal with Android's JSON parser and the complete script in WebView.
final class AndroidCSSInjectionTests: XCTestCase {
    private let escapedCSS = ".ad[data-label=\"café 日本 😀\"] { content: '\"\\\\/\n\r\t\u{0008}\u{000c}\u{0000}\u{0001}\u{001f}\u{2028}\u{2029}'; } /* </script>; window.cssEscaped = false; */"

    func testCSSLiteralPreservesEscapesAndUnicode() throws {
        let script = try makeScript([escapedCSS])
        XCTAssertEqual(try decodedCSS(script), escapedCSS)
        // JSON requires every C0 control character to be escaped, even when a parser is lenient.
        let literal = try cssLiteral(script)
        for byte in literal.utf8 {
            XCTAssertGreaterThanOrEqual(Int(byte), 32)
        }
    }

    func testCSSRulesAreTrimmedAndJoined() throws {
        let script = try makeScript([" \n.first { display: none; }\t", "  ", "\r.second { color: red; }\n"])
        XCTAssertEqual(try decodedCSS(script), ".first { display: none; }\n.second { color: red; }")
    }

    func testEmptyCSSDoesNotProduceAScript() {
        for rules in [[String](), ["", " \n\t\r"]] {
            XCTAssertNil(WebEngine.androidContentBlockerStyleInjectionScript(
                cssRules: rules, styleID: "escaping-style", frameScope: AndroidCosmeticFrameScope.mainFrameOnly))
        }
    }

    // Keep Android's real main dispatcher available for WebView callbacks.
    /* SKIP INSERT:
    @Test
    fun testEscapedCSSReachesWebViewUnchanged() {
        org.junit.Assume.assumeFalse("Requires a real Android WebView", isRobolectric)
        kotlinx.coroutines.runBlocking {
            kotlinx.coroutines.withTimeout(15_000) {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                    verifyInjectedCSS()
                }
            }
        }
    }
    */

    @MainActor
    private func verifyInjectedCSS() async throws {
        let engine = WebEngine()
        defer { engine.webView.destroy() }
        engine.webView.settings.javaScriptEnabled = true
        try await engine.awaitPageLoaded {
            engine.loadHTML("<html><body><div class='ad'>Advertisement</div></body></html>")
        }
        _ = try await engine.evaluate(js: "window.cssEscaped = true;")
        _ = try await engine.evaluate(js: makeScript([escapedCSS]))
        let evaluated = try await engine.evaluate(js: "document.getElementById('escaping-style').textContent")
        let result = try XCTUnwrap(evaluated)
        XCTAssertEqual(org.json.JSONArray("[" + result + "]").getString(0), escapedCSS)
        let escaped = try await engine.evaluate(js: "window.cssEscaped")
        XCTAssertEqual(escaped, "true")
        _ = try await engine.evaluate(js: makeScript([".ad { display: none !important; }"]))
        let display = try await engine.evaluate(js: "getComputedStyle(document.querySelector('.ad')).display")
        XCTAssertEqual(display, "\"none\"")
    }

    private func makeScript(_ rules: [String]) throws -> String {
        try XCTUnwrap(WebEngine.androidContentBlockerStyleInjectionScript(
            cssRules: rules, styleID: "escaping-style", frameScope: AndroidCosmeticFrameScope.mainFrameOnly))
    }

    /// Reads the actual literal embedded in the production script, including its quotation marks.
    private func cssLiteral(_ script: String) throws -> String {
        let parts = script.components(separatedBy: "var css = ")
        XCTAssertEqual(parts.count, 2)
        return try XCTUnwrap(parts.last?.components(separatedBy: ";\n").first)
    }

    private func decodedCSS(_ script: String) throws -> String {
        org.json.JSONArray("[" + (try cssLiteral(script)) + "]").getString(0)
    }
}
#endif
