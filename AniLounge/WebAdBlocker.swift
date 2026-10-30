import WebKit
import AniCore

@MainActor enum WebAdBlocker {
    private static var pending: Task<WKContentRuleList?, Never>?
    static func rules() async -> WKContentRuleList? {
        if let pending { return await pending.value }
        let task = Task<WKContentRuleList?, Never> { @MainActor in
            let store = WKContentRuleListStore.default()!
            let cached: WKContentRuleList? = await withCheckedContinuation { continuation in
                store.lookUpContentRuleList(forIdentifier: AdBlockRules.identifier) { list, _ in continuation.resume(returning: list) }
            }
            if let cached { return cached }
            guard let json = try? AdBlockRules.encoded() else { return nil }
            return await withCheckedContinuation { continuation in
                store.compileContentRuleList(forIdentifier: AdBlockRules.identifier, encodedContentRuleList: json) { list, _ in continuation.resume(returning: list) }
            }
        }
        pending = task
        let result = await task.value
        if result == nil { pending = nil }
        return result
    }
}
