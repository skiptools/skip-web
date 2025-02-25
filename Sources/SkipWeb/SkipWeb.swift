// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import SwiftUI
import OSLog

let logger: Logger = Logger(subsystem: "SkipWeb", category: "WebView")

extension URL {
    #if !SKIP
    public func normalizedHost(stripWWWSubdomainOnly: Bool = false) -> String? {
        // Use components.host instead of self.host since the former correctly preserves
        // brackets for IPv6 hosts, whereas the latter strips them.
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false), var host = components.host, host != "" else {
            return nil
        }

        let textToReplace = stripWWWSubdomainOnly ? "^(www)\\." : "^(www|mobile|m)\\."

        #if !SKIP
        if let range = host.range(of: textToReplace, options: .regularExpression) {
            host.replaceSubrange(range, with: "")
        }
        #endif

        return host
    }

    /// Returns the base domain from a given hostname. The base domain name is defined as the public domain suffix with the base private domain attached to the front. For example, for the URL www.bbc.co.uk, the base domain would be bbc.co.uk. The base domain includes the public suffix (co.uk) + one level down (bbc).
    public var baseDomain: String? {
        //guard !isIPv6, let host = host else { return nil }
        guard let host = host else { return nil }

        // If this is just a hostname and not a FQDN, use the entire hostname.
        if !host.contains(".") {
            return host
        }
        return nil

    }

    public var domainURL: URL {
        if let normalized = self.normalizedHost() {
            // Use URLComponents instead of URL since the former correctly preserves
            // brackets for IPv6 hosts, whereas the latter escapes them.
            var components = URLComponents()
            components.scheme = self.scheme
            #if !SKIP // TODO: This API is not yet available in Skip
            components.port = self.port
            #endif
            components.host = normalized
            return components.url ?? self
        }

        return self
    }
    #endif
}
#endif

