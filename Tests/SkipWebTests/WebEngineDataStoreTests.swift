// Copyright 2026-2026 Skip
// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import SkipWeb

#if SKIP || os(iOS)
// Keep these async tests separate from SkipWebTests' Android UiThreadTest annotation.
// Its blocking runTest wrapper would prevent the main looper from delivering cookie callbacks.
// SKIP INSERT: @org.junit.runner.RunWith(androidx.test.ext.junit.runners.AndroidJUnit4::class)
final class WebEngineDataStoreTests: XCTestCase {
    #if SKIP
    // Block only the instrumentation thread; WebView work and callbacks use the real main looper.
    /* SKIP INSERT:
    private fun runDataStoreTest(body: suspend () -> Unit) {
        org.junit.Assume.assumeFalse("Requires instrumented Android WebView", isRobolectric)
        org.junit.Assert.assertNotEquals(android.os.Looper.getMainLooper(), android.os.Looper.myLooper())
        kotlinx.coroutines.runBlocking {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { body() }
        }
    }

    @Test
    fun testAndroidRemoveDataThrowsForNonDistantPastModifiedSince() = runDataStoreTest { checkAndroidRemoveDataThrowsForNonDistantPastModifiedSince() }

    @Test
    fun testRemoveDataAllowsDistantPastForEmptyTypes() = runDataStoreTest { checkRemoveDataAllowsDistantPastForEmptyTypes() }

    @Test
    fun testSetCookieWithRequestURLFallbackAndReadHeader() = runDataStoreTest { checkSetCookieWithRequestURLFallbackAndReadHeader() }

    @Test
    fun testSecureCookieNotReturnedForHTTP() = runDataStoreTest { checkSecureCookieNotReturnedForHTTP() }

    @Test
    fun testClearCookiesRemovesStoredCookies() = runDataStoreTest { checkClearCookiesRemovesStoredCookies() }

    @Test
    fun testApplySetCookieHeadersRoundTrip() = runDataStoreTest { checkApplySetCookieHeadersRoundTrip() }

    */
    #else
    @MainActor
    func testRemoveDataAllowsDistantPastForEmptyTypes() async throws {
        try await checkRemoveDataAllowsDistantPastForEmptyTypes()
    }

    @MainActor
    func testSetCookieWithRequestURLFallbackAndReadHeader() async throws {
        try await checkSetCookieWithRequestURLFallbackAndReadHeader()
    }

    @MainActor
    func testSecureCookieNotReturnedForHTTP() async throws {
        try await checkSecureCookieNotReturnedForHTTP()
    }

    @MainActor
    func testClearCookiesRemovesStoredCookies() async throws {
        try await checkClearCookiesRemovesStoredCookies()
    }

    @MainActor
    func testApplySetCookieHeadersRoundTrip() async throws {
        try await checkApplySetCookieHeadersRoundTrip()
    }

    #endif

    #if SKIP
    @MainActor
    private func checkAndroidRemoveDataThrowsForNonDistantPastModifiedSince() async throws {
        if isRobolectric {
            throw XCTSkip("WebEngine-backed data removal tests require instrumented Android context")
        }
        let engine = await makeCookieTestEngine()
        let types: Set<WebSiteDataType> = [.cookies]
        do {
            try await engine.removeData(ofTypes: types, modifiedSince: Date())
            XCTFail("Expected removeData to throw for non-distantPast modifiedSince on Android")
        } catch let error as WebDataRemovalError {
            XCTAssertEqual(error, .unsupportedModifiedSinceOnAndroid)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    #endif

    @MainActor
    private func checkRemoveDataAllowsDistantPastForEmptyTypes() async throws {
        if isRobolectric {
            throw XCTSkip("WebEngine-backed data removal tests require instrumented Android context")
        }
        let engine = await makeCookieTestEngine()
        try await engine.removeData(ofTypes: [], modifiedSince: .distantPast)
    }

    @MainActor
    private func checkSetCookieWithRequestURLFallbackAndReadHeader() async throws {
        if isRobolectric {
            throw XCTSkip("cookie store is not reliable in Robolectric")
        }

        let engine = await makeCookieTestEngine()
        await engine.clearCookies()

        let requestURL = try XCTUnwrap(URL(string: "https://cookies.example.com/path"))
        let cookieName = "skip_cookie_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let cookie = WebCookie(name: cookieName, value: "value")

        try await engine.setCookie(cookie, requestURL: requestURL)
        let header = await engine.cookieHeader(for: requestURL)
        XCTAssertTrue(header?.contains("\(cookieName)=value") == true)

        await engine.clearCookies()
    }

    @MainActor
    private func checkSecureCookieNotReturnedForHTTP() async throws {
        if isRobolectric {
            throw XCTSkip("cookie store is not reliable in Robolectric")
        }

        let engine = await makeCookieTestEngine()
        await engine.clearCookies()

        let cookieName = "secure_cookie_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let secureCookie = WebCookie(name: cookieName, value: "1", isSecure: true)
        let httpsURL = try XCTUnwrap(URL(string: "https://secure.example.com/resource"))
        let httpURL = try XCTUnwrap(URL(string: "http://secure.example.com/resource"))

        try await engine.setCookie(secureCookie, requestURL: httpsURL)
        let secureHeader = await engine.cookieHeader(for: httpsURL)
        let insecureHeader = await engine.cookieHeader(for: httpURL)

        XCTAssertTrue(secureHeader?.contains("\(cookieName)=1") == true)
        XCTAssertFalse(insecureHeader?.contains("\(cookieName)=1") == true)

        await engine.clearCookies()
    }

    @MainActor
    private func checkClearCookiesRemovesStoredCookies() async throws {
        if isRobolectric {
            throw XCTSkip("cookie store is not reliable in Robolectric")
        }

        let engine = await makeCookieTestEngine()
        await engine.clearCookies()

        let requestURL = try XCTUnwrap(URL(string: "https://cleanup.example.com/"))
        let cookieName = "clear_cookie_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let cookie = WebCookie(name: cookieName, value: "to-delete")

        try await engine.setCookie(cookie, requestURL: requestURL)
        let headerBeforeClear = await engine.cookieHeader(for: requestURL)
        XCTAssertTrue(headerBeforeClear?.contains("\(cookieName)=to-delete") == true)

        await engine.clearCookies()
        let headerAfterClear = await engine.cookieHeader(for: requestURL)
        XCTAssertFalse(headerAfterClear?.contains("\(cookieName)=to-delete") == true)
    }

    @MainActor
    private func checkApplySetCookieHeadersRoundTrip() async throws {
        if isRobolectric {
            throw XCTSkip("cookie store is not reliable in Robolectric")
        }

        let engine = await makeCookieTestEngine()
        await engine.clearCookies()

        let responseURL = try XCTUnwrap(URL(string: "https://headers.example.com/media/master.m3u8"))
        let cookieName = "header_cookie_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try await engine.applySetCookieHeaders(
            [
                "\(cookieName)=ok; Path=/; HttpOnly",
                "not-a-cookie-header"
            ],
            for: responseURL
        )

        let header = await engine.cookieHeader(for: responseURL)
        XCTAssertTrue(header?.contains("\(cookieName)=ok") == true)

        await engine.clearCookies()
    }

}
#endif
