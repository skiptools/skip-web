// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
#if !SKIP
import WebKit
#endif
@testable import SkipWeb

#if SKIP || os(iOS) // This helper constructs an iOS WKWebView/WKWebsiteDataStore-backed engine or Android WebView; native macOS host tests cannot exercise that runtime path.
@MainActor
func makeCookieTestEngine(profile: WebProfile = WebProfile.default) async -> WebEngine {
    let config = WebEngineConfiguration(profile: profile)
    #if SKIP
    let instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
    let isMainLooperThread = (android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
    if isMainLooperThread {
        let context = instrumentation.targetContext
        config.context = context
        let platformWebView = PlatformWebView(context)
        return WebEngine(configuration: config, webView: platformWebView)
    } else {
        var createdEngine: WebEngine? = nil
        instrumentation.runOnMainSync {
            let context = instrumentation.targetContext
            config.context = context
            let platformWebView = PlatformWebView(context)
            createdEngine = WebEngine(configuration: config, webView: platformWebView)
        }
        guard let createdEngine else {
            fatalError("Expected Android cookie test engine to be created on the main looper")
        }
        return createdEngine
    }
    #else
    let platformWebView = PlatformWebView(frame: CGRectZero, configuration: await config.makeWebViewConfiguration())
    return WebEngine(configuration: config, webView: platformWebView)
    #endif
}

#if !SKIP
@MainActor
func awaitCookieHeaderContains(
    _ token: String,
    for engine: WebEngine,
    url: URL,
    shouldContain: Bool,
    timeoutNanoseconds: UInt64,
    pollNanoseconds: UInt64 = 50_000_000
) async -> String? {
    let start = DispatchTime.now().uptimeNanoseconds
    var lastHeader: String?
    while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
        let header = await engine.cookieHeader(for: url)
        lastHeader = header
        if (header?.contains(token) == true) == shouldContain {
            return header
        }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return lastHeader
}
#endif

#endif
