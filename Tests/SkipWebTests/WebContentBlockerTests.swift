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
        let payload: AndroidCosmeticPayload

        init(payload: AndroidCosmeticPayload) {
            self.payload = payload
        }

        func cosmetics(for page: AndroidPageContext) -> AndroidCosmeticPayload? {
            payload
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
            androidCosmeticBlocker: StaticCosmeticBlocker(payload: AndroidCosmeticPayload(css: [".ad{display:none!important;}"]))
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
