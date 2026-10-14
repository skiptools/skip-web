// Copyright 2026 Skip
// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import SkipWeb
#if SKIP
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import androidx.webkit.UserAgentMetadata
#endif

#if SKIP || os(iOS)
final class WebsiteModeIdentityTests: XCTestCase {
    // Robolectric has no installed Chromium provider. Reflection keeps this fixture out of
    // device tests, where the real WebView supplies its version and metadata support.
    /* SKIP INSERT:
    @org.junit.Before
    fun seedRobolectricUserAgent() {
        if (isRobolectric) {
            Class.forName("org.robolectric.shadows.ShadowWebSettings")
                .getMethod("setDefaultUserAgent", String::class.java)
                .invoke(null, "Mozilla/5.0 (Linux; Android 16; Test; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/153.0.8010.36 Mobile Safari/537.36")
        }
    }

    @org.junit.After
    fun resetRobolectricUserAgent() {
        if (isRobolectric) {
            Class.forName("org.robolectric.shadows.ShadowWebSettings")
                .getMethod("reset").invoke(null)
        }
    }
    */

    @MainActor
    func testMobileIdentityUsesInstalledVersionWithoutWebViewMarkers() {
        let defaultAgent = "Mozilla/5.0 (Linux; Android 16; SM-S721U Build/example; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/153.0.8010.36 Mobile Safari/537.36"
        let major = WebWebsiteModeController.chromiumMajor(defaultAgent: defaultAgent, providerVersion: "152.0.0.0")
        XCTAssertEqual(major, "153")
        XCTAssertEqual(WebWebsiteModeController.chromeMobileAgent(major: major!, androidVersion: "16", model: "SM-S721U"),
            "Mozilla/5.0 (Linux; Android 16; SM-S721U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Mobile Safari/537.36")
        XCTAssertEqual(WebWebsiteModeController.chromiumMajor(defaultAgent: "unknown", providerVersion: "154.1.2.3"), "154")
        XCTAssertNil(WebWebsiteModeController.chromiumMajor(defaultAgent: "unknown", providerVersion: nil))
    }

    #if SKIP
    @MainActor
    func testMobileHintsReplaceWebViewBrandAndPreserveHardware() {
        let webViewBrand = UserAgentMetadata.BrandVersion.Builder().setBrand("Android WebView")
            .setMajorVersion("153").setFullVersion("153.0.8010.36").build()
        let base = UserAgentMetadata.Builder()
            .setBrandVersionList(java.util.Collections.singletonList(webViewBrand))
            .setPlatform("Android").setPlatformVersion("16.0.0").setModel("SM-S721U")
            .setArchitecture("arm").setBitness(64).setMobile(true).setWow64(false)
            .setFullVersion("153.0.8010.36").build()
        let metadata = WebWebsiteModeController.chromeMobileMetadata(base: base,
            major: "153", androidVersion: "16", model: "SM-S721U")
        XCTAssertEqual(metadata.platform, "Android")
        XCTAssertEqual(metadata.platformVersion, "16")
        XCTAssertEqual(metadata.model, "SM-S721U")
        XCTAssertTrue(metadata.isMobile)
        XCTAssertEqual(metadata.architecture, "arm")
        XCTAssertEqual(metadata.bitness, 64)
        XCTAssertEqual(metadata.fullVersion, "153.0.0.0")
        XCTAssertEqual(metadata.brandVersionList.size, 2)
        XCTAssertEqual(metadata.brandVersionList.get(0).brand, "Chromium")
        XCTAssertEqual(metadata.brandVersionList.get(1).brand, "Google Chrome")
        XCTAssertEqual(metadata.brandVersionList.get(1).fullVersion, "153.0.0.0")
    }

    // SKIP INSERT: @androidx.test.annotation.UiThreadTest
    @MainActor
    func testMobileDesktopMobileRestoresMatchingNativeIdentity() {
        let id = "identity-\(UUID().uuidString)"
        let configuration = WebEngineConfiguration()
        configuration.desktopWebsiteForURL = { url in url.host == "desktop.example" }
        let engine = WebView.preparePersistentEngine(id: id, configuration: configuration)
        defer { WebView.removePersistentWebView(id: id) }
        let settings = engine.webView.settings
        let wideViewport = settings.useWideViewPort
        let overview = settings.loadWithOverviewMode
        let controller = WebWebsiteModeController()
        let mobileURL = URL(string: "https://mobile.example")!
        let desktopURL = URL(string: "https://desktop.example")!
        let major = WebWebsiteModeController.chromiumMajor(
            defaultAgent: android.webkit.WebSettings.getDefaultUserAgent(engine.webView.context),
            providerVersion: android.webkit.WebView.getCurrentWebViewPackage()?.versionName)!
        let expected = WebWebsiteModeController.chromeMobileAgent(major: major,
            androidVersion: android.os.Build.VERSION.RELEASE, model: android.os.Build.MODEL)
        XCTAssertFalse(controller.apply(url: mobileURL, engine: engine))
        XCTAssertEqual(settings.userAgentString, expected)
        XCTAssertTrue(controller.apply(url: desktopURL, engine: engine))
        XCTAssertTrue(settings.userAgentString.contains("X11; Linux x86_64"))
        XCTAssertFalse(controller.apply(url: mobileURL, engine: engine))
        XCTAssertEqual(settings.userAgentString, expected)
        XCTAssertEqual(settings.useWideViewPort, wideViewport)
        XCTAssertEqual(settings.loadWithOverviewMode, overview)
        if WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA) {
            let metadata = WebSettingsCompat.getUserAgentMetadata(settings)
            XCTAssertEqual(metadata.platform, "Android")
            XCTAssertEqual(metadata.platformVersion, android.os.Build.VERSION.RELEASE)
            XCTAssertEqual(metadata.model, android.os.Build.MODEL)
            XCTAssertTrue(metadata.isMobile)
            XCTAssertEqual(metadata.fullVersion, "\(major).0.0.0")
            let brands = metadata.brandVersionList
            XCTAssertEqual(brands.size, 2)
            XCTAssertEqual(brands.get(0).brand, "Chromium")
            XCTAssertEqual(brands.get(1).brand, "Google Chrome")
            XCTAssertEqual(brands.get(1).majorVersion, major)
        }
    }

    // SKIP INSERT: @androidx.test.annotation.UiThreadTest
    @MainActor
    func testExplicitMobileOverrideSurvivesDesktopRoundTrip() {
        let id = "custom-identity-\(UUID().uuidString)"
        let configuration = WebEngineConfiguration(customUserAgent: "CustomAgent")
        configuration.desktopWebsiteForURL = { url in url.host == "desktop.example" }
        let engine = WebView.preparePersistentEngine(id: id, configuration: configuration)
        defer { WebView.removePersistentWebView(id: id) }
        let controller = WebWebsiteModeController()
        XCTAssertTrue(controller.apply(url: URL(string: "https://desktop.example")!, engine: engine))
        XCTAssertFalse(controller.apply(url: URL(string: "https://mobile.example")!, engine: engine))
        XCTAssertEqual(engine.webView.settings.userAgentString, "CustomAgent")
    }
    #endif
}
#endif
