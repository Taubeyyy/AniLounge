import SwiftUI
import UIKit
import AniCore

/// Home screen quick actions (long-press the app icon): continue the last series or search.
@MainActor final class QuickActions: ObservableObject {
    static let shared = QuickActions()
    static let continueType = "app.anilounge.continue"
    static let searchType = "app.anilounge.search"
    static let calendarType = "app.anilounge.calendar"
    @Published var pending: String?
    /// Keeps the "Weiterschauen" action pointing at the newest series.
    static func refresh(continueTitle: String?) {
        var items: [UIApplicationShortcutItem] = []
        if let continueTitle {
            items.append(UIApplicationShortcutItem(type: continueType, localizedTitle: "Weiterschauen", localizedSubtitle: continueTitle,
                                                   icon: UIApplicationShortcutIcon(systemImageName: "play.fill"), userInfo: nil))
        }
        items.append(UIApplicationShortcutItem(type: calendarType, localizedTitle: "Simulcast-Kalender", localizedSubtitle: nil,
                                               icon: UIApplicationShortcutIcon(systemImageName: "calendar"), userInfo: nil))
        items.append(UIApplicationShortcutItem(type: searchType, localizedTitle: "Suchen", localizedSubtitle: nil,
                                               icon: UIApplicationShortcutIcon(systemImageName: "magnifyingglass"), userInfo: nil))
        UIApplication.shared.shortcutItems = items
    }
}
/// Receives quick actions while the app is already running.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        let type = shortcutItem.type
        Task { @MainActor in QuickActions.shared.pending = type }
        completionHandler(true)
    }
}
