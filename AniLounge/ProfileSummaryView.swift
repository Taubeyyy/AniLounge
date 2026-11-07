import SwiftUI
import AniCore

/// A dismissible peek at the active profile; the full profile lives in its own tab.
struct ProfileSummaryView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let openProfile: () -> Void

    private var watchedTime: String {
        let minutes = Int(library.active.watchedSeconds / 60)
        return minutes >= 60 ? "\(minutes / 60) Std" : "\(minutes) Min"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: library.profile.avatar)
                    .font(.title2.weight(.semibold)).foregroundColor(.white)
                    .frame(width: 48, height: 48).background(Theme.accentGradient).clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.profile.name).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("Dein Anime-Moment").font(.caption).foregroundColor(Theme.muted)
                }
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44).background(Theme.panel).clipShape(Circle())
                }
                .buttonStyle(LoungePressStyle())
                .accessibilityLabel("Profilübersicht schließen")
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                             count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        stat(watchedTime, title: "geschaut", icon: "clock")
                        stat("\(library.active.finishedEpisodes)", title: "Folgen gesehen", icon: "play.rectangle")
                        stat("\(library.favorites.filter { library.status(for: $0) == .completed }.count)",
                             title: "Anime fertig", icon: "checkmark.seal")
                        stat("\(library.favorites.count)", title: "auf deiner Liste", icon: "bookmark")
                    }
                    Button(action: openProfile) {
                        HStack {
                            Text("Zum Profil")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.subheadline.bold()).padding(.horizontal, 18).frame(minHeight: 50)
                        .background(Theme.accentGradient).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(LoungePressStyle())
                    .accessibilityHint("Schließt die Übersicht und wechselt zum Profil-Tab")
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .foregroundColor(.white).background(Theme.background)
    }

    private func stat(_ value: String, title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).font(.subheadline).foregroundColor(Theme.accentSoft).accessibilityHidden(true)
                Text(value).font(.title2.weight(.heavy)).fixedSize(horizontal: false, vertical: true)
            }
            Text(title).font(.caption).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14).glassCard(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}
