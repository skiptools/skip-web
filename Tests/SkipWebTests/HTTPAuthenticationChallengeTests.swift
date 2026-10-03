// Copyright 2026 Skip
// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import SkipWeb

#if !SKIP_BRIDGE
final class HTTPAuthenticationChallengeTests: XCTestCase {
    @MainActor func testResponseAndResolutionAreSingleUse() {
        var responses = 0
        var resolutions = 0
        let challenge = WebHTTPAuthenticationChallenge(host: "example.test", realm: nil, isRetry: false) { username, password in
            XCTAssertEqual(username, "alice")
            XCTAssertEqual(password, "secret")
            responses += 1
        }
        challenge.onResolved = { resolutions += 1 }
        challenge.useCredential(username: "alice", password: "secret")
        challenge.cancel()
        challenge.useCredential(username: "other", password: "other")
        XCTAssertTrue(challenge.isResolved)
        XCTAssertEqual(responses, 1)
        XCTAssertEqual(resolutions, 1)
    }

    @MainActor func testCancellationInvalidatesLateCredentials() {
        var responses = 0
        let challenge = WebHTTPAuthenticationChallenge(host: "example.test", realm: "Members", isRetry: true) { username, password in
            XCTAssertNil(username)
            XCTAssertNil(password)
            responses += 1
        }
        challenge.cancel()
        challenge.useCredential(username: "alice", password: "secret")
        XCTAssertEqual(responses, 1)
        XCTAssertTrue(challenge.isRetry)
    }

    @MainActor func testCancellationAlsoCancelsQueuedPeersAndSuppressesNewRequests() {
        let requests = WebHTTPAuthenticationRequests()
        var cancellations = 0
        let first = requests.makeRequest(host: "example.test", realm: nil, protectionSpace: "one", isRetry: false) { user, _ in
            XCTAssertNil(user)
            cancellations += 1
        }
        let peer = requests.makeRequest(host: "example.test", realm: nil, protectionSpace: "one", isRetry: false) { user, _ in
            XCTAssertNil(user)
            cancellations += 1
        }
        let other = requests.makeRequest(host: "example.test", realm: "Other", protectionSpace: "two", isRetry: false) { _, _ in }
        first?.cancel()
        XCTAssertTrue(peer?.isResolved == true)
        XCTAssertFalse(other?.isResolved == true)
        XCTAssertNil(requests.makeRequest(host: "example.test", realm: nil, protectionSpace: "one", isRetry: false) { _, _ in
            cancellations += 1
        })
        XCTAssertEqual(cancellations, 3)
        requests.beginNavigation()
        XCTAssertTrue(other?.isResolved == true)
        XCTAssertNotNil(requests.makeRequest(host: "example.test", realm: nil, protectionSpace: "one", isRetry: false) { _, _ in })
    }

}
#endif

#if os(iOS) && !SKIP_BRIDGE
@MainActor
final class HTTPAuthenticationEngineTests: XCTestCase {
    func testCancellationSuppressesSpaceUntilNextNavigation() {
        let configuration = WebEngineConfiguration()
        var prompts = 0
        var cancellations = 0
        configuration.httpAuthenticationHandler = { _, request in
            prompts += 1
            request.cancel()
        }
        let engine = WebEngine(configuration: configuration)
        for _ in 0..<2 {
            engine.receiveHTTPAuthentication(host: "example.test", realm: "Members", protectionSpace: "space", isRetry: false) { user, _ in
                if user == nil { cancellations += 1 }
            }
        }
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(cancellations, 2)
        engine.beginHTTPAuthenticationNavigation()
        engine.receiveHTTPAuthentication(host: "example.test", realm: "Members", protectionSpace: "space", isRetry: false) { _, _ in }
        XCTAssertEqual(prompts, 2)
    }

    func testStopInvalidatesOutstandingRequest() {
        let configuration = WebEngineConfiguration()
        var pending: WebHTTPAuthenticationChallenge?
        configuration.httpAuthenticationHandler = { _, request in pending = request }
        let engine = WebEngine(configuration: configuration)
        var responses = 0
        engine.receiveHTTPAuthentication(host: "example.test", realm: nil, protectionSpace: "space", isRetry: false) { user, _ in
            XCTAssertNil(user)
            responses += 1
        }
        engine.stopLoading()
        pending?.useCredential(username: "late", password: "late")
        XCTAssertEqual(responses, 1)
        XCTAssertTrue(pending?.isResolved == true)
    }

    func testPopupMirrorsHandlerButReportsChildEngine() {
        let configuration = WebEngineConfiguration()
        var ownerID: String?
        configuration.httpAuthenticationHandler = { engine, request in
            ownerID = engine.httpAuthenticationIdentity
            request.cancel()
        }
        let parent = WebEngine(configuration: configuration)
        let child = WebEngine(configuration: configuration.popupChildMirroredConfiguration())
        child.receiveHTTPAuthentication(host: "example.test", realm: nil, protectionSpace: "space", isRetry: false) { _, _ in }
        XCTAssertEqual(ownerID, child.httpAuthenticationIdentity)
        XCTAssertNotEqual(ownerID, parent.httpAuthenticationIdentity)
    }
}
#endif
