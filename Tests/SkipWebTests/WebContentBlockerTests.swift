// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
import XCTest
import Foundation
#if !SKIP
import WebKit
#endif
@testable import SkipWeb

// SKIP INSERT: @androidx.test.annotation.UiThreadTest
final class WebContentBlockerTests: XCTestCase {
    #if SKIP || os(iOS)

    final class AllowAllRequestBlocker: AndroidRequestBlocker {
        func decision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision {
            .allow
        }
    }

    final class StaticCosmeticBlocker: AndroidCosmeticBlocker {
        let rules: [AndroidCosmeticRule]

        init(rules: [AndroidCosmeticRule]) {
            self.rules = rules
        }

        func cosmetics(for page: AndroidPageContext) -> [AndroidCosmeticRule] {
            rules
        }
    }

    #if !SKIP
    @MainActor
    func contentBlockerTestDirectory() -> URL {
        URL.temporaryDirectory
            .appendingPathComponent("skipweb-content-blocker-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func writeContentBlockerRuleFile(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func validContentBlockerRules(filter: String = ".*ads.*") -> String {
        """
        [
          {
            "trigger": {
              "url-filter": "\(filter)"
            },
            "action": {
              "type": "block"
            }
          }
        ]
        """
    }
    #endif

    // Verifies content blocker configuration starts with no platform-specific blockers configured.
    func testContentBlockerConfigurationDefaults() {
        let config = WebContentBlockerConfiguration()
        XCTAssertTrue(config.iOSRuleListPaths.isEmpty)
        XCTAssertNil(config.androidRequestBlocker)
        XCTAssertNil(config.androidCosmeticBlocker)
    }

    // Verifies popup child configurations retain the parent's blocker settings.
    func testPopupChildMirroredConfigurationPreservesContentBlockers() {
        let contentBlockers = WebContentBlockerConfiguration(
            iOSRuleListPaths: ["/tmp/rules.json"],
            androidRequestBlocker: AllowAllRequestBlocker(),
            androidCosmeticBlocker: StaticCosmeticBlocker(
                rules: [AndroidCosmeticRule(css: [".ad{display:none!important;}"])]
            )
        )
        let config = WebEngineConfiguration(contentBlockers: contentBlockers)
        let mirrored = config.popupChildMirroredConfiguration()

        XCTAssertEqual(mirrored.contentBlockers?.iOSRuleListPaths, ["/tmp/rules.json"])
        XCTAssertNotNil(mirrored.contentBlockers?.androidRequestBlocker)
        XCTAssertNotNil(mirrored.contentBlockers?.androidCosmeticBlocker)
    }

    // Verifies Android page context derives its host from the supplied URL by default.
    func testAndroidPageContextDefaultsHostFromURL() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://example.com/path"))
        let context = AndroidPageContext(url: pageURL)
        XCTAssertEqual(context.host, "example.com")
    }

    // Verifies Android cosmetic rules default to wildcard origins, main-frame scope, and document-start timing.
    func testAndroidCosmeticRuleDefaults() {
        let rule = AndroidCosmeticRule(css: [".ad { display: none !important; }"])

        XCTAssertNil(rule.urlFilterPattern)
        XCTAssertEqual(rule.allowedOriginRules, ["*"])
        XCTAssertEqual(rule.frameScope, .mainFrameOnly)
        XCTAssertEqual(rule.preferredTiming, .documentStart)
    }

    // Verifies selector-based convenience rules compile to display:none for iOS-style hiding.
    func testAndroidCosmeticRuleHiddenSelectorsConvenienceInitializer() {
        let rule = AndroidCosmeticRule(
            hiddenSelectors: [
                ".ad-banner",
                " #sponsored "
            ],
            urlFilterPattern: ".*\\/ad-frame\\.html",
            allowedOriginRules: ["https://*.doubleclick.net"],
            frameScope: .subframesOnly,
            preferredTiming: .documentStart
        )

        XCTAssertEqual(rule.css, [
            ".ad-banner { display: none !important; }",
            "#sponsored { display: none !important; }"
        ])
        XCTAssertEqual(rule.urlFilterPattern, ".*\\/ad-frame\\.html")
        XCTAssertEqual(rule.allowedOriginRules, ["https://*.doubleclick.net"])
        XCTAssertEqual(rule.frameScope, .subframesOnly)
        XCTAssertEqual(rule.preferredTiming, .documentStart)
    }

    #if SKIP
    // Verifies redirect lookup is skipped when the Android WebView runtime does not support it.
    func testAndroidRedirectDetectionSkipsLookupWhenFeatureUnsupported() {
        var resolvedRedirect = false

        let redirect = WebEngine.androidRedirectFlag(isRedirectFeatureSupported: false) {
            resolvedRedirect = true
            return true
        }

        XCTAssertNil(redirect)
        XCTAssertFalse(resolvedRedirect)
    }

    // Verifies back/forward navigation resolves the target history index before the Android load begins.
    func testAndroidHistoryNavigationIndexUsesOffsetFromCurrentEntry() {
        XCTAssertEqual(WebEngine.androidHistoryNavigationIndex(currentIndex: 2, size: 5, offset: -1), 1)
        XCTAssertEqual(WebEngine.androidHistoryNavigationIndex(currentIndex: 2, size: 5, offset: 1), 3)
    }

    // Verifies history navigation skips cosmetic pre-registration when there is no target entry.
    func testAndroidHistoryNavigationIndexRejectsOutOfBoundsTargets() {
        XCTAssertNil(WebEngine.androidHistoryNavigationIndex(currentIndex: 0, size: 1, offset: -1))
        XCTAssertNil(WebEngine.androidHistoryNavigationIndex(currentIndex: 0, size: 1, offset: 1))
    }

    // Verifies document-start cosmetic rules preserve the caller-provided ordering.
    func testAndroidCosmeticPlanPreservesDocumentStartRuleOrder() {
        let rules = [
            AndroidCosmeticRule(
                css: [".primary { display: none !important; }"],
                allowedOriginRules: ["https://*.doubleclick.net"],
                frameScope: .subframesOnly,
                preferredTiming: .documentStart
            ),
            AndroidCosmeticRule(
                css: [".secondary { opacity: 0 !important; }"],
                allowedOriginRules: ["*"],
                frameScope: .allFrames,
                preferredTiming: .documentStart
            )
        ]

        let plan = WebEngine.androidCosmeticInjectionPlan(
            rules: rules,
            pageURL: URL(string: "https://www.example.com")!,
            isDocumentStartSupported: true
        )

        XCTAssertEqual(plan.documentStartRules, rules)
        XCTAssertTrue(plan.lifecycleCSS.isEmpty)
    }

    // Verifies unsupported document-start injection falls back only for main-frame rules.
    func testAndroidCosmeticPlanFallsBackOnlyForMainFrameRulesWhenUnsupported() {
        let plan = WebEngine.androidCosmeticInjectionPlan(
            rules: [
                AndroidCosmeticRule(
                    css: [".main { display: none !important; }"],
                    preferredTiming: .documentStart
                ),
                AndroidCosmeticRule(
                    css: [".subframe { display: none !important; }"],
                    frameScope: .subframesOnly,
                    preferredTiming: .documentStart
                )
            ],
            pageURL: URL(string: "https://www.example.com")!,
            isDocumentStartSupported: false
        )

        XCTAssertTrue(plan.documentStartRules.isEmpty)
        XCTAssertEqual(plan.lifecycleCSS, [".main { display: none !important; }"])
    }

    // Verifies page-lifecycle injection keeps only rules that are valid for main-frame fallback.
    func testAndroidCosmeticPlanKeepsPageLifecycleRulesForMainFrameOnly() {
        let plan = WebEngine.androidCosmeticInjectionPlan(
            rules: [
                AndroidCosmeticRule(
                    css: [".late { display: none !important; }"],
                    preferredTiming: .pageLifecycle
                ),
                AndroidCosmeticRule(
                    css: [".ignored { display: none !important; }"],
                    frameScope: .allFrames,
                    preferredTiming: .pageLifecycle
                )
            ],
            pageURL: URL(string: "https://www.example.com")!,
            isDocumentStartSupported: true
        )

        XCTAssertTrue(plan.documentStartRules.isEmpty)
        XCTAssertEqual(plan.lifecycleCSS, [".late { display: none !important; }"])
    }

    // Verifies page-lifecycle rules honor allowed origin scoping before injecting CSS into the main frame.
    func testAndroidCosmeticPlanFiltersLifecycleRulesByAllowedOriginRules() {
        let plan = WebEngine.androidCosmeticInjectionPlan(
            rules: [
                AndroidCosmeticRule(
                    css: [".match { display: none !important; }"],
                    allowedOriginRules: ["https://*.example.com"],
                    preferredTiming: .pageLifecycle
                ),
                AndroidCosmeticRule(
                    css: [".skip { display: none !important; }"],
                    allowedOriginRules: ["https://ads.example.net"],
                    preferredTiming: .pageLifecycle
                )
            ],
            pageURL: URL(string: "https://news.example.com")!,
            isDocumentStartSupported: true
        )

        XCTAssertEqual(plan.lifecycleCSS, [".match { display: none !important; }"])
    }

    // Verifies document-start fallback keeps origin scoping when it degrades to lifecycle injection.
    func testAndroidCosmeticPlanFiltersFallbackRulesByAllowedOriginRules() {
        let plan = WebEngine.androidCosmeticInjectionPlan(
            rules: [
                AndroidCosmeticRule(
                    css: [".match { display: none !important; }"],
                    allowedOriginRules: ["https://example.com"],
                    preferredTiming: .documentStart
                ),
                AndroidCosmeticRule(
                    css: [".skip { display: none !important; }"],
                    allowedOriginRules: ["https://other.example.com"],
                    preferredTiming: .documentStart
                )
            ],
            pageURL: URL(string: "https://example.com")!,
            isDocumentStartSupported: false
        )

        XCTAssertEqual(plan.lifecycleCSS, [".match { display: none !important; }"])
    }

    // Verifies lifecycle fallback also requires the main document URL to match urlFilterPattern.
    func testAndroidCosmeticPlanFiltersFallbackRulesByURLFilterPattern() {
        let plan = WebEngine.androidCosmeticInjectionPlan(
            rules: [
                AndroidCosmeticRule(
                    css: [".match { display: none !important; }"],
                    urlFilterPattern: ".*\\/index\\.html",
                    preferredTiming: .documentStart
                ),
                AndroidCosmeticRule(
                    css: [".skip { display: none !important; }"],
                    urlFilterPattern: ".*\\/subframe\\.html",
                    preferredTiming: .documentStart
                )
            ],
            pageURL: URL(string: "https://example.com/index.html")!,
            isDocumentStartSupported: false
        )

        XCTAssertEqual(plan.lifecycleCSS, [".match { display: none !important; }"])
    }

    // Verifies redirected pages degrade document-start rules to main-frame lifecycle injection.
    func testAndroidRedirectFallbackPlanDegradesDocumentStartRulesEvenWhenSupported() {
        let plan = WebEngine.androidRedirectFallbackCosmeticPlan(
            rules: [
                AndroidCosmeticRule(
                    css: [".main { display: none !important; }"],
                    preferredTiming: .documentStart
                ),
                AndroidCosmeticRule(
                    css: [".subframe { display: none !important; }"],
                    frameScope: .subframesOnly,
                    preferredTiming: .documentStart
                )
            ],
            pageURL: URL(string: "https://www.example.com")!
        )

        XCTAssertTrue(plan.documentStartRules.isEmpty)
        XCTAssertEqual(plan.lifecycleCSS, [".main { display: none !important; }"])
    }

    // Verifies main-frame-only scripts bail out when executed inside a subframe.
    func testAndroidContentBlockerStyleInjectionScriptAddsMainFrameGuard() throws {
        let script = try XCTUnwrap(
            WebEngine.androidContentBlockerStyleInjectionScript(
                cssRules: [".main { display: none !important; }"],
                styleID: "main-style",
                frameScope: AndroidCosmeticFrameScope.mainFrameOnly
            )
        )

        XCTAssertTrue(script.contains("window.top !== window.self"))
        XCTAssertTrue(script.contains("main-style"))
    }

    // Verifies subframe-only scripts bail out when executed in the top-level frame.
    func testAndroidContentBlockerStyleInjectionScriptAddsSubframeGuard() throws {
        let script = try XCTUnwrap(
            WebEngine.androidContentBlockerStyleInjectionScript(
                cssRules: [".subframe { display: none !important; }"],
                styleID: "subframe-style",
                frameScope: AndroidCosmeticFrameScope.subframesOnly
            )
        )

        XCTAssertTrue(script.contains("window.top === window.self"))
        XCTAssertTrue(script.contains("subframe-style"))
    }

    // Verifies URL-scoped scripts bail out when the frame URL does not match the provided rule pattern.
    func testAndroidContentBlockerStyleInjectionScriptAddsURLGuard() throws {
        let script = try XCTUnwrap(
            WebEngine.androidContentBlockerStyleInjectionScript(
                cssRules: [".subframe { display: none !important; }"],
                styleID: "url-style",
                frameScope: AndroidCosmeticFrameScope.allFrames,
                urlFilterPattern: ".*\\/subframe\\.html"
            )
        )

        XCTAssertTrue(script.contains("new RegExp"))
        XCTAssertTrue(script.contains("window.location.href"))
        XCTAssertTrue(script.contains("subframe\\\\.html"))
    }

    // Verifies all-frame scripts omit frame guards so they can run in any frame context.
    func testAndroidContentBlockerStyleInjectionScriptLeavesAllFramesUngarded() throws {
        let script = try XCTUnwrap(
            WebEngine.androidContentBlockerStyleInjectionScript(
                cssRules: [".shared { display: none !important; }"],
                styleID: "shared-style",
                frameScope: AndroidCosmeticFrameScope.allFrames
            )
        )

        XCTAssertFalse(script.contains("window.top !== window.self"))
        XCTAssertFalse(script.contains("window.top === window.self"))
        XCTAssertTrue(script.contains("shared-style"))
    }

    // Verifies stale injected CSS can be removed when a redirected final page no longer matches any rules.
    func testAndroidContentBlockerStyleRemovalScriptTargetsInjectedStyle() {
        let script = WebEngine.androidContentBlockerStyleRemovalScript(styleID: "shared-style")

        XCTAssertTrue(script.contains("document.getElementById(\"shared-style\")"))
        XCTAssertTrue(script.contains("style.remove()"))
    }
    #endif

    #if !SKIP
    // Verifies iOS rule lists compile once and are reused from the persistent cache on subsequent loads.
    @MainActor
    func testIOSContentBlockerRuleListsCompileAndReusePersistentCache() throws {
        let baseDirectory = contentBlockerTestDirectory()
        let ruleFile = baseDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules())

        WebContentBlockerDebug.setBaseDirectoryOverride(baseDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let firstConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )
        _ = firstConfig.webViewConfiguration
        XCTAssertTrue(firstConfig.contentBlockerSetupErrors.isEmpty)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.compiledIdentifiers.count, 1)
        let firstIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)

        WebContentBlockerDebug.resetDiagnostics()

        let secondConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )
        _ = secondConfig.webViewConfiguration
        XCTAssertTrue(secondConfig.contentBlockerSetupErrors.isEmpty)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.cacheHitIdentifiers, [firstIdentifier])
    }

    // Verifies caller-supplied WKWebView instances receive configured blocker rule lists.
    @MainActor
    func testIOSContentBlockersInstallIntoSuppliedWKWebView() throws {
        let baseDirectory = contentBlockerTestDirectory()
        let ruleFile = baseDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules())

        WebContentBlockerDebug.setBaseDirectoryOverride(baseDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let config = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )
        let existingWebView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        let engine = WebEngine(configuration: config, webView: existingWebView)

        XCTAssertTrue(engine.contentBlockerSetupErrors.isEmpty)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.installedRuleListCount, 1)
    }

    // Verifies changing an iOS rule file invalidates the previous compiled identifier and prunes it.
    @MainActor
    func testIOSContentBlockerRuleListChangesInvalidateCachedIdentifier() throws {
        let baseDirectory = contentBlockerTestDirectory()
        let ruleFile = baseDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules(filter: ".*ads-v1.*"))

        WebContentBlockerDebug.setBaseDirectoryOverride(baseDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let firstConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )
        _ = firstConfig.webViewConfiguration
        let firstIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)

        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules(filter: ".*ads-v2.*"))
        WebContentBlockerDebug.resetDiagnostics()

        let secondConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )
        _ = secondConfig.webViewConfiguration
        XCTAssertTrue(secondConfig.contentBlockerSetupErrors.isEmpty)
        let secondIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)
        XCTAssertNotEqual(firstIdentifier, secondIdentifier)
        XCTAssertTrue(WebContentBlockerDebug.diagnostics.prunedIdentifiers.contains(firstIdentifier))
    }

    // Verifies removing a rule file from configuration prunes its stale cached identifier.
    @MainActor
    func testIOSContentBlockerRemovingRuleFilePrunesStaleIdentifier() throws {
        let baseDirectory = contentBlockerTestDirectory()
        let firstRuleFile = baseDirectory.appendingPathComponent("rules-1.json")
        let secondRuleFile = baseDirectory.appendingPathComponent("rules-2.json")
        try writeContentBlockerRuleFile(at: firstRuleFile, contents: validContentBlockerRules(filter: ".*ads-one.*"))
        try writeContentBlockerRuleFile(at: secondRuleFile, contents: validContentBlockerRules(filter: ".*ads-two.*"))

        WebContentBlockerDebug.setBaseDirectoryOverride(baseDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let initialConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [firstRuleFile.path, secondRuleFile.path])
        )
        _ = initialConfig.webViewConfiguration
        let compiledIdentifiers = WebContentBlockerDebug.diagnostics.compiledIdentifiers
        XCTAssertEqual(compiledIdentifiers.count, 2)
        let removedIdentifier = compiledIdentifiers[1]

        WebContentBlockerDebug.resetDiagnostics()

        let prunedConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [firstRuleFile.path])
        )
        _ = prunedConfig.webViewConfiguration

        XCTAssertTrue(prunedConfig.contentBlockerSetupErrors.isEmpty)
        XCTAssertTrue(WebContentBlockerDebug.diagnostics.prunedIdentifiers.contains(removedIdentifier))
    }

    // Verifies invalid iOS rule files surface setup errors without aborting configuration creation.
    @MainActor
    func testIOSContentBlockerSetupErrorsAreRecordedWithoutFailingConfiguration() throws {
        let baseDirectory = contentBlockerTestDirectory()
        let invalidRuleFile = baseDirectory.appendingPathComponent("invalid-rules.json")
        try writeContentBlockerRuleFile(at: invalidRuleFile, contents: "[{\"trigger\":{},\"action\":{\"type\":\"block\"}}]")

        WebContentBlockerDebug.setBaseDirectoryOverride(baseDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let config = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [invalidRuleFile.path])
        )
        _ = config.webViewConfiguration

        XCTAssertEqual(config.contentBlockerSetupErrors.count, 1)
        guard case .compilationFailed(let path, _) = try XCTUnwrap(config.contentBlockerSetupErrors.first) else {
            return XCTFail("Expected a compilationFailed error")
        }
        XCTAssertEqual(path, invalidRuleFile.path)
    }
    #endif
    #endif
}
