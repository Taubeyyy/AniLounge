
import WebKit
import AppKit

_ = NSApplication.shared
var finished = false
var succeeded = false
WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "AniLounge.CI.Rules", encodedContentRuleList: try AdBlockRules.encoded()) { rules, error in
    succeeded = rules != nil && error == nil
    if let error { print(error) }
    finished = true
}
let deadline = Date().addingTimeInterval(30)
while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
guard succeeded else { fatalError("WebKit content rules failed to compile") }
print("WebKit content rules compiled successfully")
