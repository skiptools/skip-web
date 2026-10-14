// Copyright 2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if !SKIP_BRIDGE
import Foundation

/// One HTTP authentication request. Responses are single-use and must be made on the UI thread.
@MainActor
public final class WebHTTPAuthenticationChallenge {
    /// Identity of this individual request, including a fresh identity for a retry.
    public let id: String = UUID().uuidString
    /// The server requesting credentials; this may differ from the top-level page host.
    public let host: String
    /// The server's optional authentication realm.
    public let realm: String?
    /// Whether the server rejected credentials for this request.
    public let isRetry: Bool
    /// Whether the request has already been answered or invalidated by navigation.
    public private(set) var isResolved = false
    /// Called after resolution, including cancellation caused by navigation or engine teardown.
    public var onResolved: (() -> Void)?
    let protectionSpace: String
    private var respond: ((String?, String?) -> Void)?

    // SKIP @nobridge
    init(host: String, realm: String?, isRetry: Bool, protectionSpace: String = "", respond: @escaping (String?, String?) -> Void) {
        self.host = host
        self.realm = realm
        self.isRetry = isRetry
        self.protectionSpace = protectionSpace
        self.respond = respond
    }

    /// Answers this challenge without adding credentials to a persistent password store.
    public func useCredential(username: String, password: String) {
        resolve(username: username, password: password)
    }

    /// Cancels this request. Repeated responses, including late UI submissions, do nothing.
    public func cancel() {
        resolve(username: nil, password: nil)
    }

    private func resolve(username: String?, password: String?) {
        guard !isResolved else { return }
        isResolved = true
        let response = respond
        respond = nil
        let resolved = onResolved
        onResolved = nil
        response?(username, password)
        resolved?()
    }
}
/// Tracks pending responses and cancellation suppression for one engine's current navigation.
@MainActor
final class WebHTTPAuthenticationRequests {
    private var requests: [WebHTTPAuthenticationChallenge] = []
    private var cancelledSpaces: Set<String> = []

    func beginNavigation() {
        cancelAll()
        cancelledSpaces.removeAll()
    }

    func cancelAll() {
        let pending = requests
        requests.removeAll()
        for request in pending { request.cancel() }
    }

    /// Cancelling one prompt also cancels already-queued peers for that protection space.
    func makeRequest(host: String, realm: String?, protectionSpace: String, isRetry: Bool,
                     respond: @escaping (String?, String?) -> Void) -> WebHTTPAuthenticationChallenge? {
        guard !cancelledSpaces.contains(protectionSpace) else {
            respond(nil, nil)
            return nil
        }
        requests.removeAll { $0.isResolved }
        let request = WebHTTPAuthenticationChallenge(host: host, realm: realm, isRetry: isRetry,
                                                     protectionSpace: protectionSpace) { [weak self] username, password in
            if username == nil, let self, !self.cancelledSpaces.contains(protectionSpace) {
                self.cancelledSpaces.insert(protectionSpace)
                let peers = self.requests.filter { $0.protectionSpace == protectionSpace }
                for peer in peers { peer.cancel() }
            }
            respond(username, password)
        }
        requests.append(request)
        return request
    }
}
#endif
