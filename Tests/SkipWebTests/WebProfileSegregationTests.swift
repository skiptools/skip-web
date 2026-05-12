// Copyright 2024–2026 Skip
// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import SkipWeb

// SKIP INSERT: @androidx.test.annotation.UiThreadTest
final class WebProfileSegregationTests: XCTestCase {
    /// Verifies profile validation accepts real identifiers and rejects reserved or blank names.
    func testWebProfileValidationRules() {
        XCTAssertNil(WebProfilePolicy.validationError(for: WebProfile.default))
        XCTAssertNil(WebProfilePolicy.validationError(for: WebProfile.ephemeral))
        XCTAssertNil(WebProfilePolicy.validationError(for: WebProfile.named("profile-a")))
        XCTAssertEqual(WebProfilePolicy.validationError(for: WebProfile.named(" ")), WebProfileError.invalidProfileName)
        XCTAssertEqual(WebProfilePolicy.validationError(for: WebProfile.named("default")), WebProfileError.invalidProfileName)
    }

    /// Verifies Android profile support decisions match the default, ephemeral, named, and invalid cases.
    func testAndroidProfileSupportMatrix() {
        XCTAssertNil(WebProfilePolicy.androidSupportError(for: WebProfile.default, isMultiProfileFeatureSupported: false))
        XCTAssertEqual(
            WebProfilePolicy.androidSupportError(for: WebProfile.ephemeral, isMultiProfileFeatureSupported: false),
            WebProfileError.unsupportedOnAndroid
        )
        XCTAssertNil(WebProfilePolicy.androidSupportError(for: WebProfile.ephemeral, isMultiProfileFeatureSupported: true))
        XCTAssertEqual(
            WebProfilePolicy.androidSupportError(for: WebProfile.named("android-profile"), isMultiProfileFeatureSupported: false),
            WebProfileError.unsupportedOnAndroid
        )
        XCTAssertNil(
            WebProfilePolicy.androidSupportError(for: WebProfile.named("android-profile"), isMultiProfileFeatureSupported: true)
        )
        XCTAssertEqual(
            WebProfilePolicy.androidSupportError(for: WebProfile.named(" "), isMultiProfileFeatureSupported: true),
            WebProfileError.invalidProfileName
        )
    }

    #if SKIP || os(iOS) // These tests create WebEngine/PlatformWebView instances backed by iOS WKWebView/WKWebsiteDataStore APIs or Android WebView; native macOS SwiftPM cannot exercise those runtime APIs.

    /// Confirms navigator loading surfaces invalid profile errors from its backing engine.
    @MainActor
    func testNavigatorLoadOrThrowPropagatesInvalidProfileError() async throws {
        if isRobolectric {
            throw XCTSkip("WebEngine-backed navigator tests require instrumented Android context")
        }
        let navigator = WebViewNavigator()
        navigator.webEngine = await makeCookieTestEngine(profile: .named(" "))
        let requestURL = try XCTUnwrap(URL(string: "https://invalid-profile.example.com/path"))

        do {
            try await navigator.loadOrThrow(url: requestURL)
            XCTFail("Expected navigator loadOrThrow to fail for invalid profile")
        } catch let error as WebProfileError {
            XCTAssertEqual(error, .invalidProfileName)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    #if !SKIP
    /// Ensures cookies written in one iOS named profile stay invisible to a different profile.
    @MainActor
    func testIOSNamedProfileIsolatesCookiesAcrossDifferentProfiles() async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let profileA: WebProfile = .named("ios_profile_a_\(suffix)")
        let profileB: WebProfile = .named("ios_profile_b_\(suffix)")
        let engineA = await makeCookieTestEngine(profile: profileA)
        let engineB = await makeCookieTestEngine(profile: profileB)
        await engineA.clearCookies()
        await engineB.clearCookies()

        let requestURL = try XCTUnwrap(URL(string: "https://ios-profiles.example.com/path"))
        let cookieName = "ios_profile_cookie_\(suffix)"
        try await engineA.setCookie(WebCookie(name: cookieName, value: "one"), requestURL: requestURL)

        let expectedPair = "\(cookieName)=one"
        let headerA = await awaitCookieHeaderContains(
            expectedPair,
            for: engineA,
            url: requestURL,
            shouldContain: true,
            timeoutNanoseconds: 5_000_000_000
        )
        let headerB = await engineB.cookieHeader(for: requestURL)
        XCTAssertTrue(
            headerA?.contains(expectedPair) == true,
            "Expected cookie in profile A header. headerA=\(String(describing: headerA)) headerB=\(String(describing: headerB))"
        )
        XCTAssertFalse(
            headerB?.contains(expectedPair) == true,
            "Cookie leaked into profile B header. headerA=\(String(describing: headerA)) headerB=\(String(describing: headerB))"
        )

        await engineA.clearCookies()
        await engineB.clearCookies()
    }

    /// Ensures engines using the same iOS named profile share a single cookie store.
    @MainActor
    func testIOSNamedProfileSharesCookiesAcrossEnginesWithSameIdentifier() async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sharedProfile: WebProfile = .named("ios_profile_shared_\(suffix)")
        let engineA = await makeCookieTestEngine(profile: sharedProfile)
        let engineB = await makeCookieTestEngine(profile: sharedProfile)
        await engineA.clearCookies()
        await engineB.clearCookies()

        let requestURL = try XCTUnwrap(URL(string: "https://ios-profiles.example.com/shared"))
        let cookieName = "ios_shared_cookie_\(suffix)"
        try await engineA.setCookie(WebCookie(name: cookieName, value: "two"), requestURL: requestURL)

        let expectedPair = "\(cookieName)=two"
        let headerB = await awaitCookieHeaderContains(
            expectedPair,
            for: engineB,
            url: requestURL,
            shouldContain: true,
            timeoutNanoseconds: 5_000_000_000
        )
        XCTAssertTrue(
            headerB?.contains(expectedPair) == true,
            "Expected shared profile cookie in engine B header. headerB=\(String(describing: headerB))"
        )

        await engineA.clearCookies()
        await engineB.clearCookies()
    }
    #endif

    #if SKIP
    /// Confirms inheriting an invalid Android child profile fails before any cookie write can proceed.
    @MainActor
    func testAndroidChildProfileInheritanceRejectsInvalidProfile() async throws {
        if isRobolectric {
            throw XCTSkip("Android profile inheritance tests require instrumented Android context")
        }
        let child = await makeCookieTestEngine(profile: .default)
        let profileError = child.inheritAndroidProfile(from: WebProfile.named(" "))
        XCTAssertEqual(profileError, WebProfileError.invalidProfileName)

        let requestURL = try XCTUnwrap(URL(string: "https://android-profile.example.com/path"))
        do {
            try await child.setCookie(WebCookie(name: "session", value: "1"), requestURL: requestURL)
            XCTFail("Expected inherited invalid profile to block cookie operations")
        } catch let error as WebProfileError {
            XCTAssertEqual(error, WebProfileError.invalidProfileName)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// Checks inherited Android child profiles report support exactly as the runtime capability matrix does.
    @MainActor
    func testAndroidChildProfileInheritanceMatchesSupportMatrix() async throws {
        if isRobolectric {
            throw XCTSkip("WebView feature probes are unavailable in Robolectric")
        }
        let child = await makeCookieTestEngine(profile: .default)
        let profileError = child.inheritAndroidProfile(from: WebProfile.named("android-profile-inherited"))
        if WebEngine.isAndroidMultiProfileSupported() {
            XCTAssertNil(profileError)
        } else {
            XCTAssertEqual(profileError, WebProfileError.unsupportedOnAndroid)
        }
    }

    /// Ensures Android named profiles reject cookie operations when the runtime lacks multi-profile support.
    @MainActor
    func testAndroidNamedProfileThrowsWhenUnsupported() async throws {
        if isRobolectric {
            throw XCTSkip("WebView feature probes are unavailable in Robolectric")
        }
        if WebEngine.isAndroidMultiProfileSupported() {
            throw XCTSkip("device WebView runtime supports multi-profile")
        }
        let engine = await makeCookieTestEngine(profile: .named("android-profile"))
        let requestURL = try XCTUnwrap(URL(string: "https://android-profile.example.com/path"))
        do {
            try await engine.setCookie(WebCookie(name: "session", value: "1"), requestURL: requestURL)
            XCTFail("Expected named profile operations to throw when multi-profile is unsupported")
        } catch let error as WebProfileError {
            XCTAssertEqual(error, WebProfileError.unsupportedOnAndroid)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// Ensures Android ephemeral profiles reject cookie operations instead of sharing the default store when multi-profile is unsupported.
    @MainActor
    func testAndroidEphemeralProfileThrowsWhenUnsupported() async throws {
        if isRobolectric {
            throw XCTSkip("WebView feature probes are unavailable in Robolectric")
        }
        if WebEngine.isAndroidMultiProfileSupported() {
            throw XCTSkip("device WebView runtime supports multi-profile")
        }
        let engine = await makeCookieTestEngine(profile: .ephemeral)
        let requestURL = try XCTUnwrap(URL(string: "https://android-ephemeral.example.com/path"))
        do {
            try await engine.setCookie(WebCookie(name: "session", value: "1"), requestURL: requestURL)
            XCTFail("Expected ephemeral profile operations to throw when multi-profile is unsupported")
        } catch let error as WebProfileError {
            XCTAssertEqual(error, WebProfileError.unsupportedOnAndroid)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// Verifies distinct Android named profiles keep cookie state isolated when multi-profile support exists.
    @MainActor
    func testAndroidNamedProfilesIsolateCookiesWhenSupported() async throws {
        if isRobolectric {
            throw XCTSkip("cookie/profile store tests are not reliable in Robolectric")
        }
        if !WebEngine.isAndroidMultiProfileSupported() {
            throw XCTSkip("device WebView runtime does not support multi-profile")
        }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let engineA = await makeCookieTestEngine(profile: .named("android_profile_a_\(suffix)"))
        let engineB = await makeCookieTestEngine(profile: .named("android_profile_b_\(suffix)"))
        await engineA.clearCookies()
        await engineB.clearCookies()

        let requestURL = try XCTUnwrap(URL(string: "https://android-profile.example.com/path"))
        let cookieName = "android_profile_cookie_\(suffix)"
        try await engineA.setCookie(WebCookie(name: cookieName, value: "1"), requestURL: requestURL)
        let headerA = await engineA.cookieHeader(for: requestURL)
        let headerB = await engineB.cookieHeader(for: requestURL)
        XCTAssertTrue(headerA?.contains("\(cookieName)=1") == true)
        XCTAssertFalse(headerB?.contains("\(cookieName)=1") == true)

        await engineA.clearCookies()
        await engineB.clearCookies()
    }

    /// Verifies Android ephemeral profiles use isolated generated stores when multi-profile support exists.
    @MainActor
    func testAndroidEphemeralProfilesIsolateCookiesWhenSupported() async throws {
        if isRobolectric {
            throw XCTSkip("cookie/profile store tests are not reliable in Robolectric")
        }
        if !WebEngine.isAndroidMultiProfileSupported() {
            throw XCTSkip("device WebView runtime does not support multi-profile")
        }

        let engineA = await makeCookieTestEngine(profile: .ephemeral)
        let engineB = await makeCookieTestEngine(profile: .ephemeral)
        await engineA.clearCookies()
        await engineB.clearCookies()

        let requestURL = try XCTUnwrap(URL(string: "https://android-ephemeral.example.com/path"))
        let cookieName = "android_ephemeral_cookie_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try await engineA.setCookie(WebCookie(name: cookieName, value: "1"), requestURL: requestURL)
        let headerA = await engineA.cookieHeader(for: requestURL)
        let headerB = await engineB.cookieHeader(for: requestURL)
        XCTAssertTrue(headerA?.contains("\(cookieName)=1") == true)
        XCTAssertFalse(headerB?.contains("\(cookieName)=1") == true)

        await engineA.clearCookies()
        await engineB.clearCookies()
    }
    #endif

    #endif
}
