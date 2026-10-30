import Foundation

/// Small bundled list. Video CDNs and player libraries are intentionally excluded.
public enum AdBlockRules {
    public static let identifier = "AniLounge.AdBlock.v1"
    public static let domains = ["doubleclick.net", "googlesyndication.com", "googleadservices.com", "popads.net", "popcash.net", "adsterra.com", "exoclick.com", "trafficjunky.net", "propellerads.com", "adnxs.com"]
    public static func blocks(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    public static func encoded() throws -> String {
        let rules: [[String: Any]] = domains.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return ["trigger": ["url-filter": "^https?://([^/]+\\.)?" + escaped + "[:/]"], "action": ["type": "block"]]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
    }
}
