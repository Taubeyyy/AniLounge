import Foundation

public enum SourceSelection: Equatable, Sendable {
    case selected(StreamHost)
    case requiresLanguageChoice(preferred: String)
    case unavailable
}

/// Provider categories describe editions, not independently selectable subtitle tracks.
public enum PlaybackLanguage {
    public static func key(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["de", "deutsch", "german"].contains(text) { return "de" }
        if ["en", "englisch", "english"].contains(text) { return "en" }
        if ["jp", "japanisch", "japanese"].contains(text) { return "jp" }
        if text.contains("sub") || text.contains("untertitel") {
            if text == "de-sub" || text.contains("deutsch") || text.contains("german") { return "de-sub" }
            if text == "en-sub" || text.contains("engl") { return "en-sub" }
        }
        return text
    }
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        !key(lhs).isEmpty && key(lhs) == key(rhs)
    }
}
