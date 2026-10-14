// Copyright 2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if !SKIP_BRIDGE
import Foundation
#if !SKIP
import WebKit
#else
import androidx.webkit.WebSettingsCompat
import androidx.webkit.UserAgentMetadata
import androidx.webkit.WebViewFeature
#endif

#if SKIP || os(iOS)
/// Applies website-specific native settings without replaying navigation requests.
// SKIP @nobridge
@MainActor final class WebWebsiteModeController {
    private var appliedMode: Bool?
    #if SKIP
    private var mobileMetadata: UserAgentMetadata?
    private var mobileWideViewport = false
    private var mobileOverview = false
    #endif

    /// Returns the effective mode; absent policy leaves existing configuration untouched.
    func apply(url: URL, engine: WebEngine) -> Bool {
        guard let policy = engine.configuration.desktopWebsiteForURL else { return false }
        let desktop = policy(url)
        guard appliedMode != desktop else { return desktop }
        #if SKIP
        let settings = engine.webView.settings
        let supportsMetadata = WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA)
        if appliedMode == nil {
            mobileWideViewport = settings.useWideViewPort
            mobileOverview = settings.loadWithOverviewMode
            if supportsMetadata { mobileMetadata = WebSettingsCompat.getUserAgentMetadata(settings) }
        }
        let defaultAgent = android.webkit.WebSettings.getDefaultUserAgent(engine.webView.context)
        let providerVersion = android.webkit.WebView.getCurrentWebViewPackage()?.versionName
        let chromiumMajor = Self.chromiumMajor(defaultAgent: defaultAgent, providerVersion: providerVersion)
        if desktop {
            guard let major = chromiumMajor else { return false }
            settings.setUserAgentString(Self.chromeDesktopAgent(major: major))
            settings.setUseWideViewPort(true)
            settings.setLoadWithOverviewMode(true)
            if supportsMetadata {
                let brand = UserAgentMetadata.BrandVersion.Builder().setBrand("Chromium")
                    .setMajorVersion(major).setFullVersion("\(major).0.0.0").build()
                let metadata = UserAgentMetadata.Builder()
                    .setBrandVersionList(java.util.Collections.singletonList(brand))
                    .setPlatform("Linux").setPlatformVersion("").setArchitecture("x86")
                    .setBitness(64).setModel("").setMobile(false).setWow64(false)
                    .setFullVersion("\(major).0.0.0").build()
                WebSettingsCompat.setUserAgentMetadata(settings, metadata)
            }
        } else {
            if engine.configuration.customUserAgent == nil, let major = chromiumMajor {
                let androidVersion = android.os.Build.VERSION.RELEASE
                let model = android.os.Build.MODEL
                settings.setUserAgentString(Self.chromeMobileAgent(major: major, androidVersion: androidVersion, model: model))
                if supportsMetadata, let mobileMetadata {
                    WebSettingsCompat.setUserAgentMetadata(settings, Self.chromeMobileMetadata(
                        base: mobileMetadata, major: major, androidVersion: androidVersion, model: model))
                }
            } else {
                // Explicit overrides and an unknown engine version retain the original configuration.
                settings.setUserAgentString(engine.configuration.customUserAgent)
                if supportsMetadata, let mobileMetadata {
                    WebSettingsCompat.setUserAgentMetadata(settings, mobileMetadata)
                }
            }
            settings.setUseWideViewPort(mobileWideViewport)
            settings.setLoadWithOverviewMode(mobileOverview)
        }
        #else
        engine.webView.customUserAgent = desktop ? Self.safariDesktopAgent : engine.configuration.customUserAgent
        engine.webView.configuration.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .mobile
        #endif
        appliedMode = desktop
        return desktop
    }

    static let safariDesktopAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Safari/605.1.15"

    static func chromeDesktopAgent(major: String) -> String {
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36"
    }

    /// Advertises mobile Chrome using the installed engine and actual Android device identity.
    static func chromeMobileAgent(major: String, androidVersion: String, model: String) -> String {
        "Mozilla/5.0 (Linux; Android \(androidVersion); \(model)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Mobile Safari/537.36"
    }

    #if SKIP
    /// Keeps native hardware hints while replacing WebView branding and aligning the mobile identity.
    static func chromeMobileMetadata(base: UserAgentMetadata, major: String, androidVersion: String, model: String) -> UserAgentMetadata {
        let brands = java.util.ArrayList<UserAgentMetadata.BrandVersion>()
        brands.add(UserAgentMetadata.BrandVersion.Builder().setBrand("Chromium")
            .setMajorVersion(major).setFullVersion("\(major).0.0.0").build())
        brands.add(UserAgentMetadata.BrandVersion.Builder().setBrand("Google Chrome")
            .setMajorVersion(major).setFullVersion("\(major).0.0.0").build())
        return UserAgentMetadata.Builder(base).setBrandVersionList(brands)
            .setFullVersion("\(major).0.0.0").setPlatform("Android")
            .setPlatformVersion(androidVersion).setModel(model).setMobile(true).build()
    }
    #endif

    /// Uses the installed engine's version, never a hard-coded Chromium version.
    static func chromiumMajor(defaultAgent: String, providerVersion: String?) -> String? {
        if let token = defaultAgent.components(separatedBy: "Chrome/").dropFirst().first,
           let candidate = token.components(separatedBy: ".").first,
           let number = Int(candidate), number > 0 { return String(number) }
        if let candidate = providerVersion?.components(separatedBy: ".").first,
           let number = Int(candidate), number > 0 { return String(number) }
        return nil
    }
}
#endif
#endif
