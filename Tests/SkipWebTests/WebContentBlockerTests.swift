// Copyright 2023-2026 Skip
// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
#if !SKIP
import WebKit
#endif
@testable import SkipWeb

// SKIP INSERT: @androidx.test.annotation.UiThreadTest
final class WebContentBlockerTests: XCTestCase {
    #if SKIP || os(iOS)

    final class StaticContentBlockingProvider: AndroidContentBlockingProvider {
        let decision: AndroidRequestBlockDecision
        let persistentRules: [AndroidCosmeticRule]
        let navigationRules: [AndroidCosmeticRule]

        init(
            decision: AndroidRequestBlockDecision = AndroidRequestBlockDecision.allow,
            persistentRules: [AndroidCosmeticRule] = [],
            navigationRules: [AndroidCosmeticRule] = []
        ) {
            self.decision = decision
            self.persistentRules = persistentRules
            self.navigationRules = navigationRules
        }

        var persistentCosmeticRules: [AndroidCosmeticRule] {
            persistentRules
        }

        func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision {
            decision
        }

        func navigationCosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule] {
            navigationRules
        }
    }

    final class HostScopedContentBlockingProvider: AndroidContentBlockingProvider {
        let mainPageHost: String
        let rule: AndroidCosmeticRule
        var requestedPageURLs: [URL] = []

        init(mainPageHost: String, rule: AndroidCosmeticRule) {
            self.mainPageHost = mainPageHost
            self.rule = rule
        }

        var persistentCosmeticRules: [AndroidCosmeticRule] {
            []
        }

        func navigationCosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule] {
            requestedPageURLs.append(page.url)
            if page.url.host == mainPageHost {
                return [rule]
            }
            return []
        }
    }

    final class RecordingContentBlockingProvider: AndroidContentBlockingProvider {
        let decision: AndroidRequestBlockDecision
        var requests: [AndroidBlockableRequest] = []

        init(decision: AndroidRequestBlockDecision) {
            self.decision = decision
        }

        var persistentCosmeticRules: [AndroidCosmeticRule] {
            []
        }

        func requestDecision(for request: AndroidBlockableRequest) -> AndroidRequestBlockDecision {
            requests.append(request)
            return decision
        }

        func navigationCosmeticRules(for page: AndroidPageContext) -> [AndroidCosmeticRule] {
            []
        }
    }

    final class TestNavigationDelegate: SkipWebNavigationDelegate {
    }

    #if !SKIP
    @MainActor
    final class ControlledIOSContentBlockerPreparer {
        private var continuations: [String: CheckedContinuation<PreparedContentBlockerRuleLists, Never>] = [:]
        private var invocationWaiters: [String: CheckedContinuation<Void, Never>] = [:]

        func prepare(sourcePaths: [String]) async -> PreparedContentBlockerRuleLists {
            let key = sourcePaths.first ?? ""
            return await withCheckedContinuation { continuation in
                continuations[key] = continuation
                invocationWaiters.removeValue(forKey: key)?.resume()
            }
        }

        func waitUntilInvoked(_ key: String) async {
            if continuations[key] != nil {
                return
            }
            await withCheckedContinuation { continuation in
                invocationWaiters[key] = continuation
            }
        }

        func complete(_ key: String, errors: [WebContentBlockerError]) {
            continuations.removeValue(forKey: key)?.resume(
                returning: PreparedContentBlockerRuleLists(
                    ruleLists: [],
                    errors: errors
                )
            )
        }
    }

    @MainActor
    func contentBlockerTestDirectory() -> URL {
        URL.temporaryDirectory
            .appendingPathComponent("skipweb-content-blocker-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @MainActor
    func contentBlockerFixtureDirectory(from testDirectory: URL) -> URL {
        testDirectory.appendingPathComponent("fixtures", isDirectory: true)
    }

    @MainActor
    func contentBlockerStoreDirectory(from testDirectory: URL) -> URL {
        testDirectory.appendingPathComponent("store", isDirectory: true)
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
        XCTAssertTrue(config.whitelistedDomains.isEmpty)
        XCTAssertTrue(config.popupWhitelistedSourceDomains.isEmpty)
        switch config.androidMode {
        case .disabled:
            break
        case .custom:
            XCTFail("Expected Android content blocking to default to disabled mode")
        }
        XCTAssertNil(config.effectiveAndroidProvider)
    }

    // Verifies popup child configurations retain the parent's blocker settings.
    @MainActor
    func testPopupChildMirroredConfigurationPreservesAndroidBlockingMode() {
        let provider = StaticContentBlockingProvider(
            decision: AndroidRequestBlockDecision.block,
            navigationRules: [AndroidCosmeticRule(hiddenSelectors: [".ad"])]
        )
        let contentBlockers = WebContentBlockerConfiguration(
            iOSRuleListPaths: ["/tmp/rules.json"],
            whitelistedDomains: ["example.com"],
            popupWhitelistedSourceDomains: ["popup.example.com"],
            androidMode: .custom(provider)
        )
        let config = WebEngineConfiguration(contentBlockers: contentBlockers)
        let mirrored = config.popupChildMirroredConfiguration()

        XCTAssertEqual(mirrored.contentBlockers?.iOSRuleListPaths, ["/tmp/rules.json"])
        XCTAssertEqual(mirrored.contentBlockers?.whitelistedDomains, ["example.com"])
        XCTAssertEqual(mirrored.contentBlockers?.popupWhitelistedSourceDomains, ["popup.example.com"])
        guard case .custom(let mirroredProvider)? = mirrored.contentBlockers?.androidMode else {
            return XCTFail("Expected mirrored popup configuration to preserve custom Android blocking mode")
        }
        let mirroredDecision = mirroredProvider.requestDecision(
            for: AndroidBlockableRequest(
                url: URL(string: "https://example.com")!,
                method: "GET",
                isForMainFrame: true,
                hasGesture: false
            )
        )
        XCTAssertEqual(mirroredDecision, AndroidRequestBlockDecision.block)
        XCTAssertEqual(mirroredProvider.navigationCosmeticRules(for: AndroidPageContext(url: URL(string: "https://example.com")!)).count, 1)
    }

    // Verifies the compatibility contentBlockers property resolves once and is shared by children.
    @MainActor
    func testPopupChildMirroredConfigurationSharesImplicitRuntime() {
        let configuration = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(
                androidMode: .custom(StaticContentBlockingProvider())
            )
        )

        let firstChild = configuration.popupChildMirroredConfiguration()
        let secondChild = configuration.popupChildMirroredConfiguration()

        XCTAssertNotNil(firstChild.contentBlockerRuntime)
        XCTAssertTrue(firstChild.contentBlockerRuntime === secondChild.contentBlockerRuntime)
    }

    // Verifies independently created configurations can explicitly reuse one prepared runtime.
    @MainActor
    func testExplicitContentBlockerRuntimeIsPreservedByConfigurationAndPopupMirror() {
        let runtime = WebContentBlockerRuntime(
            configuration: WebContentBlockerConfiguration(
                androidMode: .custom(StaticContentBlockingProvider())
            )
        )
        let configuration = WebEngineConfiguration(contentBlockerRuntime: runtime)
        let mirrored = configuration.popupChildMirroredConfiguration()

        XCTAssertTrue(configuration.contentBlockerRuntime === runtime)
        XCTAssertTrue(mirrored.contentBlockerRuntime === runtime)
    }

    // Verifies explicit reapplication advances one shared revision without replacing the runtime.
    @MainActor
    func testContentBlockerRuntimeReapplyAdvancesRevision() async {
        let runtime = WebContentBlockerRuntime(configuration: WebContentBlockerConfiguration())

        let errors = await runtime.reapply(
            configuration: WebContentBlockerConfiguration(
                whitelistedDomains: ["example.com"]
            )
        )

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(runtime.revision, 1)
        XCTAssertEqual(runtime.configuration.whitelistedDomains, ["example.com"])
    }

    #if !SKIP
    // Verifies a superseded preparation cannot replace or return an older rule snapshot.
    @MainActor
    func testContentBlockerRuntimeDiscardsStaleIOSPreparationResult() async {
        let oldPath = "/tmp/old-rules.json"
        let newPath = "/tmp/new-rules.json"
        let oldError = WebContentBlockerError.operationTimedOut("old revision")
        let newError = WebContentBlockerError.operationTimedOut("new revision")
        let preparer = ControlledIOSContentBlockerPreparer()
        let runtime = WebContentBlockerRuntime(
            configuration: WebContentBlockerConfiguration(iOSRuleListPaths: [oldPath]),
            iosRuleListPreparer: { sourcePaths, _, _ in
                await preparer.prepare(sourcePaths: sourcePaths)
            }
        )

        let oldPreparation = Task { @MainActor in
            await runtime.prepare()
        }
        await preparer.waitUntilInvoked(oldPath)

        let reapplication = Task { @MainActor in
            await runtime.reapply(
                configuration: WebContentBlockerConfiguration(iOSRuleListPaths: [newPath])
            )
        }
        await preparer.waitUntilInvoked(newPath)

        preparer.complete(newPath, errors: [newError])
        _ = await reapplication.value
        preparer.complete(oldPath, errors: [oldError])

        let oldPreparationErrors = await oldPreparation.value
        let currentErrors = await runtime.prepare()
        XCTAssertEqual(oldPreparationErrors, [newError])
        XCTAssertEqual(currentErrors, [newError])
        XCTAssertEqual(runtime.revision, 1)
    }

    // Verifies clearing the compatibility property removes the rules from its existing runtime.
    @MainActor
    func testReapplyContentBlockersDisablesClearedCompatibilityConfiguration() async throws {
        let configuration = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(
                whitelistedDomains: ["example.com"]
            )
        )
        let engine = WebEngine(configuration: configuration)
        let runtime = try XCTUnwrap(engine.contentBlockerRuntime)

        configuration.contentBlockers = nil
        let errors = await engine.reapplyContentBlockers()

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(runtime.revision, 1)
        XCTAssertTrue(runtime.configuration.iOSRuleListPaths.isEmpty)
        XCTAssertTrue(runtime.configuration.whitelistedDomains.isEmpty)
        XCTAssertNil(runtime.configuration.effectiveAndroidProvider)
    }

    // Verifies the compatibility property can enable blockers after the engine was created.
    @MainActor
    func testReapplyContentBlockersCreatesCompatibilityRuntimeWhenEnabledLater() async throws {
        let configuration = WebEngineConfiguration()
        let engine = WebEngine(configuration: configuration)
        XCTAssertNil(engine.contentBlockerRuntime)

        configuration.contentBlockers = WebContentBlockerConfiguration(
            whitelistedDomains: ["enabled.example.com"]
        )
        let errors = await engine.reapplyContentBlockers()
        let runtime = try XCTUnwrap(engine.contentBlockerRuntime)

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(runtime.revision, 1)
        XCTAssertEqual(runtime.configuration.whitelistedDomains, ["enabled.example.com"])
        XCTAssertTrue(
            configuration.popupChildMirroredConfiguration().contentBlockerRuntime === runtime
        )
    }

    // Verifies the compatibility property cannot replace an explicitly supplied shared runtime.
    @MainActor
    func testReapplyContentBlockersKeepsExplicitRuntimeAuthoritative() async {
        let runtime = WebContentBlockerRuntime(
            configuration: WebContentBlockerConfiguration(
                whitelistedDomains: ["runtime.example.com"]
            )
        )
        let configuration = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(
                whitelistedDomains: ["compatibility.example.com"]
            ),
            contentBlockerRuntime: runtime
        )
        let engine = WebEngine(configuration: configuration)

        let errors = await engine.reapplyContentBlockers()

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(runtime.revision, 1)
        XCTAssertEqual(runtime.configuration.whitelistedDomains, ["runtime.example.com"])
    }
    #endif

    // Verifies the fixed bootstrap's native filtering retains origin, domain, URL, and frame guards.
    #if SKIP
    func testAndroidCosmeticCSSFiltersRulesBeforeReturningBootstrapCSS() throws {
        let rule = AndroidCosmeticRule(
            hiddenSelectors: [".sponsored"],
            urlFilterPattern: "/article/",
            allowedOriginRules: ["https://*.example.com"],
            ifDomainList: ["news.example.com"],
            frameScope: .mainFrameOnly
        )
        let matchingURL = try XCTUnwrap(URL(string: "https://news.example.com/article/1"))
        let nonmatchingURL = try XCTUnwrap(URL(string: "https://news.example.com/home"))

        XCTAssertEqual(
            WebEngine.androidCosmeticCSS(
                rules: [rule],
                pageURL: matchingURL,
                isMainFrame: true,
                preferredTiming: AndroidCosmeticInjectionTiming.documentStart
            ),
            [".sponsored { display: none !important; }"]
        )
        XCTAssertTrue(WebEngine.androidCosmeticCSS(
            rules: [rule],
            pageURL: matchingURL,
            isMainFrame: false,
            preferredTiming: AndroidCosmeticInjectionTiming.documentStart
        ).isEmpty)
        XCTAssertTrue(WebEngine.androidCosmeticCSS(
            rules: [rule],
            pageURL: nonmatchingURL,
            isMainFrame: true,
            preferredTiming: AndroidCosmeticInjectionTiming.documentStart
        ).isEmpty)
    }
    #endif

    // Verifies whitelist entries normalize for stable matching and cache behavior.
    func testWhitelistedDomainsNormalizeForStableBehavior() {
        let contentBlockers = WebContentBlockerConfiguration(
            whitelistedDomains: [" Example.com ", "*.Example.com", "example.com", ""]
        )

        XCTAssertEqual(contentBlockers.normalizedWhitelistedDomains, ["*.example.com", "example.com"])
    }

    // Verifies exact and wildcard whitelist rules retain WebKit-style matching semantics.
    func testWhitelistedDomainsMatchExactAndWildcardHosts() {
        let domains = WebContentBlockerConfiguration.normalizedWhitelistedDomains(
            from: ["example.com", "*.example.com"]
        )

        XCTAssertTrue(WebContentBlockerConfiguration.matchesWhitelistedDomain("example.com", in: domains))
        XCTAssertTrue(WebContentBlockerConfiguration.matchesWhitelistedDomain("news.example.com", in: domains))
        XCTAssertFalse(WebContentBlockerConfiguration.matchesWhitelistedDomain("deep.news.other.com", in: domains))
        XCTAssertFalse(WebContentBlockerConfiguration.matchesWhitelistedDomain("otherexample.com", in: domains))
    }

    // Verifies Android request blocking is bypassed for whitelisted page domains.
    func testAndroidWhitelistedDomainsBypassRequestBlocking() {
        let provider = StaticContentBlockingProvider(decision: .block)
        let contentBlockers = WebContentBlockerConfiguration(
            whitelistedDomains: ["example.com", "*.example.net"],
            androidMode: .custom(provider)
        )

        guard let effectiveProvider = contentBlockers.effectiveAndroidProvider else {
            return XCTFail("Expected effective Android provider")
        }

        let mainDocumentDecision = effectiveProvider.requestDecision(
            for: AndroidBlockableRequest(
                url: URL(string: "https://cdn.ads.net/script.js")!,
                mainDocumentURL: URL(string: "https://example.com/article")!,
                method: "GET",
                isForMainFrame: false,
                hasGesture: false
            )
        )
        XCTAssertEqual(mainDocumentDecision, AndroidRequestBlockDecision.allow)

        let mainFrameFallbackDecision = effectiveProvider.requestDecision(
            for: AndroidBlockableRequest(
                url: URL(string: "https://sub.example.net/home")!,
                method: "GET",
                isForMainFrame: true,
                hasGesture: false
            )
        )
        XCTAssertEqual(mainFrameFallbackDecision, AndroidRequestBlockDecision.allow)
    }

    // Verifies whitelist wrapping no longer suppresses cosmetics at the provider layer.
    func testAndroidWhitelistedDomainsDoNotSuppressProviderCosmeticRules() {
        let provider = StaticContentBlockingProvider(
            navigationRules: [AndroidCosmeticRule(hiddenSelectors: [".ad"])]
        )
        let contentBlockers = WebContentBlockerConfiguration(
            whitelistedDomains: ["example.com"],
            androidMode: .custom(provider)
        )

        guard let effectiveProvider = contentBlockers.effectiveAndroidProvider else {
            return XCTFail("Expected effective Android provider")
        }

        XCTAssertEqual(
            effectiveProvider.navigationCosmeticRules(for: AndroidPageContext(url: URL(string: "https://example.com/page")!)),
            [AndroidCosmeticRule(hiddenSelectors: [".ad"])]
        )
    }

    // Verifies Android non-whitelisted domains still use the underlying provider unchanged.
    func testAndroidNonWhitelistedDomainsStillUseUnderlyingProvider() {
        let rule = AndroidCosmeticRule(hiddenSelectors: [".ad"])
        let provider = StaticContentBlockingProvider(
            decision: AndroidRequestBlockDecision.block,
            navigationRules: [rule]
        )
        let contentBlockers = WebContentBlockerConfiguration(
            whitelistedDomains: ["example.com"],
            androidMode: .custom(provider)
        )

        guard let effectiveProvider = contentBlockers.effectiveAndroidProvider else {
            return XCTFail("Expected effective Android provider")
        }

        let decision = effectiveProvider.requestDecision(
            for: AndroidBlockableRequest(
                url: URL(string: "https://cdn.ads.net/script.js")!,
                mainDocumentURL: URL(string: "https://news.other.com/article")!,
                method: "GET",
                isForMainFrame: false,
                hasGesture: false
            )
        )
        XCTAssertEqual(decision, AndroidRequestBlockDecision.block)
        XCTAssertEqual(
            effectiveProvider.navigationCosmeticRules(for: AndroidPageContext(url: URL(string: "https://news.other.com/article")!)),
            [rule]
        )
    }

    // Verifies popup child configurations preserve the new app-facing navigation delegate.
    @MainActor
    func testPopupChildMirroredConfigurationPreservesNavigationDelegate() {
        let config = WebEngineConfiguration(navigationDelegate: TestNavigationDelegate())
        let mirrored = config.popupChildMirroredConfiguration()

        XCTAssertNotNil(mirrored.navigationDelegate)
    }

    // Verifies Android page context derives its host from the supplied URL by default.
    func testAndroidPageContextDefaultsHostFromURL() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://example.com/path"))
        let context = AndroidPageContext(url: pageURL)
        XCTAssertEqual(context.host, "example.com")
    }

    // Verifies Android cosmetic rules default to wildcard origins, main-frame scope, and document-start timing.
    func testAndroidCosmeticRuleDefaults() {
        let rule = AndroidCosmeticRule(hiddenSelectors: [".ad"])

        XCTAssertNil(rule.urlFilterPattern)
        XCTAssertEqual(rule.allowedOriginRules, ["*"])
        XCTAssertTrue(rule.ifDomainList.isEmpty)
        XCTAssertTrue(rule.unlessDomainList.isEmpty)
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
            ifDomainList: ["ads.example.com"],
            unlessDomainList: ["private.ads.example.com"],
            frameScope: .subframesOnly,
            preferredTiming: .documentStart
        )

        XCTAssertEqual(rule.hiddenSelectors, [
            ".ad-banner",
            "#sponsored"
        ])
        XCTAssertEqual(rule.urlFilterPattern, ".*\\/ad-frame\\.html")
        XCTAssertEqual(rule.allowedOriginRules, ["https://*.doubleclick.net"])
        XCTAssertEqual(rule.ifDomainList, ["ads.example.com"])
        XCTAssertEqual(rule.unlessDomainList, ["private.ads.example.com"])
        XCTAssertEqual(rule.frameScope, .subframesOnly)
        XCTAssertEqual(rule.preferredTiming, .documentStart)
    }

    #if SKIP
    // Verifies redirect navigation checks preserve the initiating page and Android request facts.
    func testAndroidMainFrameNavigationDecisionUsesCurrentPageContext() throws {
        let currentPageURL = try XCTUnwrap(URL(string: "https://primewire.mov/movie/example"))
        let redirectURL = try XCTUnwrap(URL(string: "https://pro.roundflow.net/redirect"))
        let provider = RecordingContentBlockingProvider(decision: .block)
        let configuration = WebContentBlockerConfiguration(androidMode: .custom(provider))
        let controller = AndroidContentBlockerController(
            config: WebEngineConfiguration(contentBlockers: configuration),
            runtime: WebContentBlockerRuntime(configuration: configuration)
        )

        let decision = controller.mainFrameNavigationDecision(
            requestURL: redirectURL,
            mainDocumentURL: currentPageURL,
            method: "GET",
            headers: ["Accept": "text/html"],
            hasGesture: false,
            isRedirect: true
        )

        XCTAssertEqual(decision, AndroidRequestBlockDecision.block)
        XCTAssertEqual(
            provider.requests,
            [
                AndroidBlockableRequest(
                    url: redirectURL,
                    mainDocumentURL: currentPageURL,
                    method: "GET",
                    headers: ["Accept": "text/html"],
                    isForMainFrame: true,
                    hasGesture: false,
                    isRedirect: true,
                    resourceTypeHint: .document
                )
            ]
        )
    }

    // Verifies schemes outside HTTP(S) never enter the content-rule provider.
    func testAndroidMainFrameNavigationDecisionAllowsNonHTTPURL() throws {
        let provider = RecordingContentBlockingProvider(decision: .block)
        let configuration = WebContentBlockerConfiguration(androidMode: .custom(provider))
        let controller = AndroidContentBlockerController(
            config: WebEngineConfiguration(contentBlockers: configuration),
            runtime: WebContentBlockerRuntime(configuration: configuration)
        )

        let decision = controller.mainFrameNavigationDecision(
            requestURL: try XCTUnwrap(URL(string: "intent://example/path")),
            mainDocumentURL: try XCTUnwrap(URL(string: "https://primewire.mov/")),
            method: "GET",
            headers: [:],
            hasGesture: true,
            isRedirect: false
        )

        XCTAssertEqual(decision, AndroidRequestBlockDecision.allow)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    // Verifies a blocked navigation can notify the host without invoking tab lifecycle behavior.
    func testAndroidWebViewClientReportsContentRuleNavigationBlock() throws {
        let blockedURL = try XCTUnwrap(URL(string: "https://pro.roundflow.net/redirect"))
        var reportedURLs: [URL] = []
        let client = WebViewClient(
            state: WebViewState(),
            onNavigationCommitted: nil,
            onNavigationFinished: nil,
            onNavigationFailed: nil,
            onContentRuleBlockedNavigation: { reportedURLs.append($0) },
            shouldOverrideUrlLoadingHandler: nil
        )

        client.contentRuleDidBlockNavigation(to: blockedURL)

        XCTAssertEqual(reportedURLs, [blockedURL])
    }

    // Verifies a main-page rule remains selected while its frame guards are evaluated against an iframe URL.
    func testAndroidDocumentStartBridgeUsesMainPageToSelectSubframeRules() throws {
        let mainPageURL = try XCTUnwrap(URL(string: "https://publisher.example/article"))
        let subframeURL = try XCTUnwrap(URL(string: "https://ads.example/frame"))
        let provider = HostScopedContentBlockingProvider(
            mainPageHost: "publisher.example",
            rule: AndroidCosmeticRule(
                hiddenSelectors: [".sponsored-frame"],
                frameScope: .allFrames
            )
        )
        let configuration = WebContentBlockerConfiguration(
            androidMode: .custom(provider)
        )
        let runtime = WebContentBlockerRuntime(configuration: configuration)
        let controller = AndroidContentBlockerController(
            config: WebEngineConfiguration(contentBlockers: configuration),
            runtime: runtime
        )

        _ = controller.documentStartCSS(frameURL: mainPageURL, isMainFrame: true)
        let subframeCSS = controller.documentStartCSS(
            frameURL: subframeURL,
            isMainFrame: false
        )

        XCTAssertEqual(
            subframeCSS,
            ".sponsored-frame { display: none !important; }"
        )
        XCTAssertEqual(provider.requestedPageURLs, [mainPageURL])
    }

    // Verifies whitelisting the main page suppresses cosmetic rules in every child frame.
    func testAndroidDocumentStartBridgeAppliesMainPageWhitelistToSubframes() throws {
        let mainPageURL = try XCTUnwrap(URL(string: "https://publisher.example/article"))
        let subframeURL = try XCTUnwrap(URL(string: "https://ads.example/frame"))
        let provider = HostScopedContentBlockingProvider(
            mainPageHost: "publisher.example",
            rule: AndroidCosmeticRule(
                hiddenSelectors: [".sponsored-frame"],
                frameScope: .allFrames
            )
        )
        let configuration = WebContentBlockerConfiguration(
            whitelistedDomains: ["publisher.example"],
            androidMode: .custom(provider)
        )
        let runtime = WebContentBlockerRuntime(configuration: configuration)
        let controller = AndroidContentBlockerController(
            config: WebEngineConfiguration(contentBlockers: configuration),
            runtime: runtime
        )

        let mainFrameCSS = controller.documentStartCSS(
            frameURL: mainPageURL,
            isMainFrame: true
        )
        let subframeCSS = controller.documentStartCSS(
            frameURL: subframeURL,
            isMainFrame: false
        )

        XCTAssertTrue(mainFrameCSS.isEmpty)
        XCTAssertTrue(subframeCSS.isEmpty)
        XCTAssertTrue(provider.requestedPageURLs.isEmpty)
    }

    // Verifies engines sharing one runtime keep independent main-page navigation snapshots.
    func testAndroidDocumentStartBridgeKeepsSharedRuntimeSnapshotsPerController() throws {
        let selectedMainPageURL = try XCTUnwrap(
            URL(string: "https://publisher.example/article")
        )
        let otherMainPageURL = try XCTUnwrap(
            URL(string: "https://other.example/article")
        )
        let subframeURL = try XCTUnwrap(URL(string: "https://ads.example/frame"))
        let provider = HostScopedContentBlockingProvider(
            mainPageHost: "publisher.example",
            rule: AndroidCosmeticRule(
                hiddenSelectors: [".sponsored-frame"],
                frameScope: .allFrames
            )
        )
        let configuration = WebContentBlockerConfiguration(
            androidMode: .custom(provider)
        )
        let runtime = WebContentBlockerRuntime(configuration: configuration)
        let selectedController = AndroidContentBlockerController(
            config: WebEngineConfiguration(contentBlockers: configuration),
            runtime: runtime
        )
        let otherController = AndroidContentBlockerController(
            config: WebEngineConfiguration(contentBlockers: configuration),
            runtime: runtime
        )

        _ = selectedController.documentStartCSS(
            frameURL: selectedMainPageURL,
            isMainFrame: true
        )
        _ = otherController.documentStartCSS(
            frameURL: otherMainPageURL,
            isMainFrame: true
        )

        XCTAssertFalse(
            selectedController.documentStartCSS(
                frameURL: subframeURL,
                isMainFrame: false
            ).isEmpty
        )
        XCTAssertTrue(
            otherController.documentStartCSS(
                frameURL: subframeURL,
                isMainFrame: false
            ).isEmpty
        )
    }

    // Verifies pre-navigation preparation is reused once, while a later same-URL navigation refreshes its rules.
    func testAndroidDocumentStartBridgeConsumesPreparedMainPageSnapshotOnce() throws {
        let mainPageURL = try XCTUnwrap(URL(string: "https://publisher.example/article"))
        let provider = HostScopedContentBlockingProvider(
            mainPageHost: "publisher.example",
            rule: AndroidCosmeticRule(hiddenSelectors: [".sponsored"])
        )
        let configuration = WebContentBlockerConfiguration(
            androidMode: .custom(provider)
        )
        let runtime = WebContentBlockerRuntime(configuration: configuration)
        let controller = AndroidContentBlockerController(
            config: WebEngineConfiguration(contentBlockers: configuration),
            runtime: runtime
        )
        let context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        let webView = PlatformWebView(context)

        controller.prepare(for: mainPageURL, in: webView)
        _ = controller.documentStartCSS(frameURL: mainPageURL, isMainFrame: true)
        XCTAssertEqual(provider.requestedPageURLs, [mainPageURL])

        _ = controller.documentStartCSS(frameURL: mainPageURL, isMainFrame: true)
        XCTAssertEqual(provider.requestedPageURLs, [mainPageURL, mainPageURL])
    }

    // Verifies assigning the deprecated engineDelegate no longer replaces the engine-owned WebViewClient.
    func testAndroidLegacyEngineDelegateDoesNotReplaceInternalWebViewClient() {
        let engine = WebEngine(
            configuration: WebEngineConfiguration(
                contentBlockers: WebContentBlockerConfiguration(
                    androidMode: .custom(StaticContentBlockingProvider())
                )
            )
        )
        let installedClient = engine.webView.webViewClient
        let legacyDelegate = WebEngineDelegate(config: engine.configuration)

        engine.engineDelegate = legacyDelegate

        XCTAssertTrue(engine.webView.webViewClient === installedClient)
        XCTAssertTrue(engine.engineDelegate === legacyDelegate)
    }

    // Verifies a caller-supplied Android WebViewClient is forwarded through the internal engine-owned client.
    func testAndroidSuppliedWebViewClientIsPreservedUnderInternalClient() throws {
        let context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        let platformWebView = PlatformWebView(context)
        let suppliedClient = android.webkit.WebViewClient()
        platformWebView.webViewClient = suppliedClient

        let engine = WebEngine(
            configuration: WebEngineConfiguration(
                contentBlockers: WebContentBlockerConfiguration(
                    androidMode: .custom(StaticContentBlockingProvider())
                )
            ),
            webView: platformWebView
        )
        let installedClient = try XCTUnwrap(engine.webView.webViewClient as? AndroidEngineWebViewClient)

        XCTAssertFalse(installedClient === suppliedClient)
        XCTAssertTrue(installedClient.embeddedNavigationClient === suppliedClient)
    }

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
                hiddenSelectors: [".primary"],
                allowedOriginRules: ["https://*.doubleclick.net"],
                frameScope: .subframesOnly,
                preferredTiming: .documentStart
            ),
            AndroidCosmeticRule(
                hiddenSelectors: [".secondary"],
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

    // Verifies document-start batching keeps unlike domain-list guards in separate rules.
    func testAndroidCosmeticPlanKeepsDocumentStartRulesSeparateWhenDomainListsDiffer() {
        let plan = WebEngine.androidCosmeticInjectionPlan(
            rules: [
                AndroidCosmeticRule(
                    hiddenSelectors: [".news"],
                    ifDomainList: ["news.example.com"],
                    frameScope: .allFrames,
                    preferredTiming: .documentStart
                ),
                AndroidCosmeticRule(
                    hiddenSelectors: [".sports"],
                    ifDomainList: ["sports.example.com"],
                    frameScope: .allFrames,
                    preferredTiming: .documentStart
                )
            ],
            pageURL: URL(string: "https://example.com")!,
            isDocumentStartSupported: true
        )

        XCTAssertEqual(plan.documentStartRules.count, 2)
        XCTAssertEqual(plan.documentStartRules[0].ifDomainList, ["news.example.com"])
        XCTAssertEqual(plan.documentStartRules[1].ifDomainList, ["sports.example.com"])
    }

    // Verifies unsupported document-start injection falls back only for main-frame rules.
    func testAndroidCosmeticPlanFallsBackOnlyForMainFrameRulesWhenUnsupported() {
        let plan = WebEngine.androidCosmeticInjectionPlan(
            rules: [
                AndroidCosmeticRule(
                    hiddenSelectors: [".main"],
                    preferredTiming: .documentStart
                ),
                AndroidCosmeticRule(
                    hiddenSelectors: [".subframe"],
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
                    hiddenSelectors: [".late"],
                    preferredTiming: .pageLifecycle
                ),
                AndroidCosmeticRule(
                    hiddenSelectors: [".ignored"],
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
                    hiddenSelectors: [".match"],
                    allowedOriginRules: ["https://*.example.com"],
                    preferredTiming: .pageLifecycle
                ),
                AndroidCosmeticRule(
                    hiddenSelectors: [".skip"],
                    allowedOriginRules: ["https://ads.example.net"],
                    preferredTiming: .pageLifecycle
                )
            ],
            pageURL: URL(string: "https://news.example.com")!,
            isDocumentStartSupported: true
        )

        XCTAssertEqual(plan.lifecycleCSS, [".match { display: none !important; }"])
    }

    // Verifies page-lifecycle fallback honors current-document domain guards before injecting into the main frame.
    func testAndroidCosmeticPlanFiltersLifecycleRulesByDomainLists() {
        let plan = WebEngine.androidCosmeticInjectionPlan(
            rules: [
                AndroidCosmeticRule(
                    hiddenSelectors: [".match"],
                    ifDomainList: ["news.example.com"],
                    preferredTiming: .pageLifecycle
                ),
                AndroidCosmeticRule(
                    hiddenSelectors: [".skip"],
                    ifDomainList: ["sports.example.com"],
                    preferredTiming: .pageLifecycle
                ),
                AndroidCosmeticRule(
                    hiddenSelectors: [".excluded"],
                    unlessDomainList: ["news.example.com"],
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
                    hiddenSelectors: [".match"],
                    allowedOriginRules: ["https://example.com"],
                    preferredTiming: .documentStart
                ),
                AndroidCosmeticRule(
                    hiddenSelectors: [".skip"],
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
                    hiddenSelectors: [".match"],
                    urlFilterPattern: ".*\\/index\\.html",
                    preferredTiming: .documentStart
                ),
                AndroidCosmeticRule(
                    hiddenSelectors: [".skip"],
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
                    hiddenSelectors: [".main"],
                    preferredTiming: .documentStart
                ),
                AndroidCosmeticRule(
                    hiddenSelectors: [".subframe"],
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

    // Verifies domain-scoped scripts bail out unless the current frame host matches the provided domain lists.
    func testAndroidContentBlockerStyleInjectionScriptAddsDomainGuards() throws {
        let script = try XCTUnwrap(
            WebEngine.androidContentBlockerStyleInjectionScript(
                cssRules: [".subframe { display: none !important; }"],
                styleID: "domain-style",
                frameScope: AndroidCosmeticFrameScope.allFrames,
                ifDomainList: ["ads.example.com"],
                unlessDomainList: ["private.ads.example.com"]
            )
        )

        XCTAssertTrue(script.contains("window.location.hostname"))
        XCTAssertTrue(script.contains("ifDomainList"))
        XCTAssertTrue(script.contains("unlessDomainList"))
        XCTAssertTrue(script.contains("ads.example.com"))
        XCTAssertTrue(script.contains("private.ads.example.com"))
    }

    // Verifies batched document-start scripts can carry multiple CSS blocks behind one injected style.
    func testAndroidContentBlockerBatchedStyleInjectionScriptCombinesMultipleRules() throws {
        let script = try XCTUnwrap(
            WebEngine.androidContentBlockerBatchedStyleInjectionScript(
                rules: [
                    AndroidCosmeticRule(
                        hiddenSelectors: [".first"],
                        frameScope: AndroidCosmeticFrameScope.allFrames
                    ),
                    AndroidCosmeticRule(
                        hiddenSelectors: [".second"],
                        frameScope: AndroidCosmeticFrameScope.allFrames,
                        urlFilterPattern: ".*\\/subframe\\.html",
                        ifDomainList: ["ads.example.com"]
                    )
                ],
                styleID: "batched-style"
            )
        )

        XCTAssertTrue(script.contains("var rules = ["))
        XCTAssertTrue(script.contains("\"hiddenSelectors\":[\".first\"]"))
        XCTAssertTrue(script.contains("\"hiddenSelectors\":[\".second\"]"))
        XCTAssertTrue(script.contains("var compactedCSS = compactHiddenSelectors(collectedSelectors)"))
        XCTAssertTrue(script.contains("window.__skipWebCosmeticStyles.replace(styleId, compactedCSS.join"))
        XCTAssertTrue(script.contains("groupedDisplayNoneCSS"))
        XCTAssertTrue(script.contains("compactHiddenSelectors"))
        XCTAssertTrue(script.contains("batched-style"))
    }

    // Verifies batched document-start scripts retain per-rule frame, URL, and host guards.
    func testAndroidContentBlockerBatchedStyleInjectionScriptRetainsRuleSpecificGuards() throws {
        let script = try XCTUnwrap(
            WebEngine.androidContentBlockerBatchedStyleInjectionScript(
                rules: [
                    AndroidCosmeticRule(
                        hiddenSelectors: [".subframe"],
                        frameScope: AndroidCosmeticFrameScope.subframesOnly,
                        urlFilterPattern: ".*\\/subframe\\.html",
                        ifDomainList: ["ads.example.com"],
                        unlessDomainList: ["private.ads.example.com"]
                    )
                ],
                styleID: "batched-guards"
            )
        )

        XCTAssertTrue(script.contains("frameMatches"))
        XCTAssertTrue(script.contains("subframesOnly"))
        XCTAssertTrue(script.contains("new RegExp"))
        XCTAssertTrue(script.contains("ads.example.com"))
        XCTAssertTrue(script.contains("private.ads.example.com"))
    }

    // Verifies batched scripts merge compatible display-none rules with the same batching limits as the store reducer.
    func testAndroidContentBlockerBatchedStyleInjectionScriptCompactsDisplayNoneCSS() throws {
        let script = try XCTUnwrap(
            WebEngine.androidContentBlockerBatchedStyleInjectionScript(
                rules: [
                    AndroidCosmeticRule(
                        hiddenSelectors: [
                            ".first",
                            ".second",
                            ".first"
                        ],
                        frameScope: AndroidCosmeticFrameScope.allFrames
                    )
                ],
                styleID: "batched-compact"
            )
        )

        XCTAssertTrue(script.contains("maximumSelectorsPerGroupedRule = 128"))
        XCTAssertTrue(script.contains("maximumSelectorCharactersPerGroupedRule = 16384"))
        XCTAssertTrue(script.contains("return groupedDisplayNoneCSS(uniqueSelectors)"))
        XCTAssertTrue(script.contains("display: none !important;"))
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
    func testIOSContentBlockerRuleListsCompileAndReusePersistentCache() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let ruleFile = fixtureDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules())

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let firstConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )
        _ = await firstConfig.makeWebViewConfiguration()
        XCTAssertTrue(firstConfig.contentBlockerSetupErrors.isEmpty)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.compiledIdentifiers.count, 1)
        let firstIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)

        WebContentBlockerDebug.resetDiagnostics()

        let secondConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )
        _ = await secondConfig.makeWebViewConfiguration()
        XCTAssertTrue(secondConfig.contentBlockerSetupErrors.isEmpty)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.cacheHitIdentifiers, [firstIdentifier])
    }

    // Verifies apps can prewarm iOS rule-list compilation without constructing WebKit controller objects.
    @MainActor
    func testIOSContentBlockersCanBePreparedWithoutWebViewConfiguration() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let ruleFile = fixtureDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules())

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let config = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )

        let errors = await config.iOSPrepareContentBlockers()

        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(config.contentBlockerSetupErrors.isEmpty)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.compiledIdentifiers.count, 1)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.installedRuleListCount, 0)
    }

    // Verifies iOS whitelist rules are appended as ignore-previous-rules exemptions.
    @MainActor
    func testIOSWhitelistedDomainsAppendIgnorePreviousRules() throws {
        let augmentedContent = WebContentBlockerDebug.augmentedRuleListContent(
            validContentBlockerRules(),
            whitelistedDomains: [" Example.com ", "*.Example.com"]
        )
        let data = try XCTUnwrap(augmentedContent.data(using: .utf8))
        let jsonObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let appendedRule = try XCTUnwrap(jsonObject.last)
        let trigger = try XCTUnwrap(appendedRule["trigger"] as? [String: Any])
        let action = try XCTUnwrap(appendedRule["action"] as? [String: Any])

        XCTAssertEqual(appendedRule["comment"] as? String, "user-injected domain exemptions (whitelisted domains)")
        XCTAssertEqual(trigger["url-filter"] as? String, ".*")
        XCTAssertEqual(trigger["if-domain"] as? [String], ["*.example.com", "example.com"])
        XCTAssertEqual(action["type"] as? String, "ignore-previous-rules")
    }

    // Verifies popup-only iOS whitelist rules append as popup-scoped ignore-previous-rules exemptions.
    @MainActor
    func testIOSPopupWhitelistedSourceDomainsAppendPopupIgnorePreviousRules() throws {
        let augmentedContent = WebContentBlockerDebug.augmentedRuleListContent(
            validContentBlockerRules(),
            whitelistedDomains: [],
            popupWhitelistedSourceDomains: [" Example.com "]
        )
        let data = try XCTUnwrap(augmentedContent.data(using: .utf8))
        let jsonObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let appendedRule = try XCTUnwrap(jsonObject.last)
        let trigger = try XCTUnwrap(appendedRule["trigger"] as? [String: Any])
        let action = try XCTUnwrap(appendedRule["action"] as? [String: Any])

        XCTAssertEqual(appendedRule["comment"] as? String, "user-injected popup exemptions (allowed source domains)")
        XCTAssertEqual(trigger["url-filter"] as? String, ".*")
        XCTAssertEqual(trigger["resource-type"] as? [String], ["popup"])
        XCTAssertEqual(
            trigger["if-top-url"] as? [String],
            [
                "http://*.example.com/*",
                "http://example.com/*",
                "https://*.example.com/*",
                "https://example.com/*",
            ]
        )
        XCTAssertNil(trigger["if-domain"])
        XCTAssertEqual(action["type"] as? String, "ignore-previous-rules")
    }

    // Verifies caller-supplied WKWebView instances receive configured blocker rule lists.
    @MainActor
    func testIOSContentBlockersInstallIntoSuppliedWKWebView() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let ruleFile = fixtureDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules())

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
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
        _ = await engine.awaitContentBlockerSetup()

        XCTAssertTrue(engine.contentBlockerSetupErrors.isEmpty)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.installedRuleListCount, 1)
    }

    // Verifies the public cache-clear API removes persisted rule lists so the next load recompiles from source.
    @MainActor
    func testIOSContentBlockerCacheCanBeClearedExplicitly() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let ruleFile = fixtureDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules())

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
        defer {
            try? WebEngineConfiguration.iOSClearContentBlockerCache()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebEngineConfiguration.iOSClearContentBlockerCache()
        WebContentBlockerDebug.resetDiagnostics()

        let initialConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )
        _ = await initialConfig.makeWebViewConfiguration()
        XCTAssertTrue(initialConfig.contentBlockerSetupErrors.isEmpty)
        let compiledIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)

        try WebEngineConfiguration.iOSClearContentBlockerCache()
        WebContentBlockerDebug.resetDiagnostics()

        let reloadedConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )
        _ = await reloadedConfig.makeWebViewConfiguration()
        XCTAssertTrue(reloadedConfig.contentBlockerSetupErrors.isEmpty)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.cacheHitIdentifiers, [])
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.compiledIdentifiers, [compiledIdentifier])
    }

    // Verifies changing the whitelist invalidates the cached iOS compiled identifier.
    @MainActor
    func testIOSWhitelistedDomainsInvalidateCachedIdentifierWhenChanged() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let ruleFile = fixtureDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules())

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let firstConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(
                iOSRuleListPaths: [ruleFile.path],
                whitelistedDomains: ["example.com"]
            )
        )
        _ = await firstConfig.makeWebViewConfiguration()
        let firstIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)

        WebContentBlockerDebug.resetDiagnostics()

        let secondConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(
                iOSRuleListPaths: [ruleFile.path],
                whitelistedDomains: ["other.example.com"]
            )
        )
        _ = await secondConfig.makeWebViewConfiguration()
        XCTAssertTrue(secondConfig.contentBlockerSetupErrors.isEmpty)
        let secondIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)

        XCTAssertNotEqual(firstIdentifier, secondIdentifier)
        XCTAssertTrue(WebContentBlockerDebug.diagnostics.prunedIdentifiers.contains(firstIdentifier))
    }

    // Verifies normalized iOS whitelist entries reuse the persistent cache across semantically identical inputs.
    @MainActor
    func testIOSWhitelistedDomainsNormalizeBeforeCacheLookup() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let ruleFile = fixtureDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules())

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let firstConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(
                iOSRuleListPaths: [ruleFile.path],
                whitelistedDomains: [" Example.com ", "example.com", "*.Example.com"]
            )
        )
        _ = await firstConfig.makeWebViewConfiguration()
        let firstIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)

        WebContentBlockerDebug.resetDiagnostics()

        let secondConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(
                iOSRuleListPaths: [ruleFile.path],
                whitelistedDomains: ["*.example.com", "example.com"]
            )
        )
        _ = await secondConfig.makeWebViewConfiguration()
        XCTAssertTrue(secondConfig.contentBlockerSetupErrors.isEmpty)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.cacheHitIdentifiers, [firstIdentifier])
    }

    // Verifies popup-only iOS whitelist entries participate in the compiled rule-list identifier.
    @MainActor
    func testIOSPopupWhitelistedSourceDomainsChangeInvalidateCachedIdentifier() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let ruleFile = fixtureDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules())

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let firstConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(
                iOSRuleListPaths: [ruleFile.path],
                popupWhitelistedSourceDomains: ["example.com"]
            )
        )
        _ = await firstConfig.makeWebViewConfiguration()
        let firstIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)

        WebContentBlockerDebug.resetDiagnostics()

        let secondConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(
                iOSRuleListPaths: [ruleFile.path],
                popupWhitelistedSourceDomains: ["other.example.com"]
            )
        )
        _ = await secondConfig.makeWebViewConfiguration()
        XCTAssertTrue(secondConfig.contentBlockerSetupErrors.isEmpty)
        let secondIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)

        XCTAssertNotEqual(firstIdentifier, secondIdentifier)
        XCTAssertTrue(WebContentBlockerDebug.diagnostics.prunedIdentifiers.contains(firstIdentifier))
    }

    // Verifies normalized popup-only iOS whitelist entries reuse the persistent cache across semantically identical inputs.
    @MainActor
    func testIOSPopupWhitelistedSourceDomainsNormalizeBeforeCacheLookup() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let ruleFile = fixtureDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules())

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let firstConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(
                iOSRuleListPaths: [ruleFile.path],
                popupWhitelistedSourceDomains: [" Example.com ", "example.com"]
            )
        )
        _ = await firstConfig.makeWebViewConfiguration()
        let firstIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)

        WebContentBlockerDebug.resetDiagnostics()

        let secondConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(
                iOSRuleListPaths: [ruleFile.path],
                popupWhitelistedSourceDomains: ["example.com"]
            )
        )
        _ = await secondConfig.makeWebViewConfiguration()
        XCTAssertTrue(secondConfig.contentBlockerSetupErrors.isEmpty)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.cacheHitIdentifiers, [firstIdentifier])
    }

    // Verifies changing an iOS rule file invalidates the previous compiled identifier and prunes it.
    @MainActor
    func testIOSContentBlockerRuleListChangesInvalidateCachedIdentifier() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let ruleFile = fixtureDirectory.appendingPathComponent("rules.json")
        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules(filter: ".*ads-v1.*"))

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let firstConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )
        _ = await firstConfig.makeWebViewConfiguration()
        let firstIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)

        try writeContentBlockerRuleFile(at: ruleFile, contents: validContentBlockerRules(filter: ".*ads-v2.*"))
        WebContentBlockerDebug.resetDiagnostics()

        let secondConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [ruleFile.path])
        )
        _ = await secondConfig.makeWebViewConfiguration()
        XCTAssertTrue(secondConfig.contentBlockerSetupErrors.isEmpty)
        let secondIdentifier = try XCTUnwrap(WebContentBlockerDebug.diagnostics.compiledIdentifiers.first)
        XCTAssertNotEqual(firstIdentifier, secondIdentifier)
        XCTAssertTrue(WebContentBlockerDebug.diagnostics.prunedIdentifiers.contains(firstIdentifier))
    }

    // Verifies removing a rule file from configuration prunes its stale cached identifier.
    @MainActor
    func testIOSContentBlockerRemovingRuleFilePrunesStaleIdentifier() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let firstRuleFile = fixtureDirectory.appendingPathComponent("rules-1.json")
        let secondRuleFile = fixtureDirectory.appendingPathComponent("rules-2.json")
        try writeContentBlockerRuleFile(at: firstRuleFile, contents: validContentBlockerRules(filter: ".*ads-one.*"))
        try writeContentBlockerRuleFile(at: secondRuleFile, contents: validContentBlockerRules(filter: ".*ads-two.*"))

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let initialConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [firstRuleFile.path, secondRuleFile.path])
        )
        _ = await initialConfig.makeWebViewConfiguration()
        let compiledIdentifiers = WebContentBlockerDebug.diagnostics.compiledIdentifiers
        XCTAssertEqual(compiledIdentifiers.count, 2)
      
        guard compiledIdentifiers.count >= 2 else {
          return
        }
        let removedIdentifier = compiledIdentifiers[1]

        WebContentBlockerDebug.resetDiagnostics()

        let prunedConfig = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [firstRuleFile.path])
        )
        _ = await prunedConfig.makeWebViewConfiguration()

        XCTAssertTrue(prunedConfig.contentBlockerSetupErrors.isEmpty)
        XCTAssertTrue(WebContentBlockerDebug.diagnostics.prunedIdentifiers.contains(removedIdentifier))
    }

    // Verifies invalid iOS rule files surface setup errors without aborting configuration creation.
    @MainActor
    func testIOSContentBlockerSetupErrorsAreRecordedWithoutFailingConfiguration() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let invalidRuleFile = fixtureDirectory.appendingPathComponent("invalid-rules.json")
        try writeContentBlockerRuleFile(at: invalidRuleFile, contents: "[{\"trigger\":{},\"action\":{\"type\":\"block\"}}]")

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let config = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [invalidRuleFile.path])
        )
        _ = await config.makeWebViewConfiguration()

        XCTAssertEqual(config.contentBlockerSetupErrors.count, 1)
        guard case .compilationFailed(let path, _) = try XCTUnwrap(config.contentBlockerSetupErrors.first) else {
            return XCTFail("Expected a compilationFailed error")
        }
        XCTAssertEqual(path, invalidRuleFile.path)
    }

    // Verifies an iOS rule file that contains an empty array is treated as a no-op instead of a compilation failure.
    @MainActor
    func testIOSEmptyRuleListIsIgnored() async throws {
        let testDirectory = contentBlockerTestDirectory()
        let fixtureDirectory = contentBlockerFixtureDirectory(from: testDirectory)
        let storeDirectory = contentBlockerStoreDirectory(from: testDirectory)
        let emptyRuleFile = fixtureDirectory.appendingPathComponent("empty-rules.json")
        try writeContentBlockerRuleFile(at: emptyRuleFile, contents: "[]")

        WebContentBlockerDebug.setBaseDirectoryOverride(storeDirectory)
        defer {
            try? WebContentBlockerDebug.clearPersistentState()
            WebContentBlockerDebug.setBaseDirectoryOverride(nil)
        }
        try? WebContentBlockerDebug.clearPersistentState()
        WebContentBlockerDebug.resetDiagnostics()

        let config = WebEngineConfiguration(
            contentBlockers: WebContentBlockerConfiguration(iOSRuleListPaths: [emptyRuleFile.path])
        )
        _ = await config.makeWebViewConfiguration()

        XCTAssertTrue(config.contentBlockerSetupErrors.isEmpty)
        XCTAssertTrue(WebContentBlockerDebug.diagnostics.compiledIdentifiers.isEmpty)
        XCTAssertEqual(WebContentBlockerDebug.diagnostics.installedRuleListCount, 0)
    }
    #endif
    #endif
}
