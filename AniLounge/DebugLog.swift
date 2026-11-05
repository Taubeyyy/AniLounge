import SwiftUI

/// In-app diagnostics: what the player and hoster pages did, to share when something fails.
@MainActor final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published private(set) var lines: [String] = []
    private let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    func add(_ area: String, _ text: String) {
        lines.append("\(formatter.string(from: Date())) [\(area)] \(text)")
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }
    func clear() { lines.removeAll() }
    var text: String { "AniLounge \(AppInfo.version) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\n" + lines.joined(separator: "\n") }
}
struct DebugLogView: View {
    @ObservedObject private var log = DebugLog.shared
    var body: some View {
        LoungeScroll(title: "Diagnose", largeTitle: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Starte eine Folge, warte bis sie hängt, und teile dann dieses Protokoll.").font(.subheadline).foregroundColor(Theme.muted)
                if log.lines.isEmpty {
                    Text("Noch keine Einträge.").font(.footnote).foregroundColor(Theme.muted).padding(.top, 20)
                }
                ForEach(Array(log.lines.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.85)).textSelection(.enabled)
                }
            }.padding(.horizontal, 20)
        } leading: {
            BackButton()
        } trailing: {
            HStack(spacing: 10) {
                Button { log.clear() } label: { CircleIcon(systemName: "trash") }.buttonStyle(LoungePressStyle()).accessibilityLabel("Leeren")
                ShareLink(item: log.text) { CircleIcon(systemName: "square.and.arrow.up") }.accessibilityLabel("Teilen")
            }
        }
    }
}
