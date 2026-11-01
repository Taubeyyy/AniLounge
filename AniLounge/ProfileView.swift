import SwiftUI
import AniCore

struct ProfileView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var editing = false
    @State private var creating = false
    @State private var showingInfo = false
    private var hoursLabel: String {
        let minutes = Int(library.active.watchedSeconds / 60)
        return minutes >= 60 ? "\(minutes / 60) Std \(minutes % 60) Min" : "\(minutes) Min"
    }
    var body: some View {
        LoungeScroll(title: "Ich", largeTitle: false) {
            VStack(alignment: .leading, spacing: 26) {
                // Header with the active profile, like the account page of streaming apps.
                HStack(spacing: 16) {
                    Image(systemName: library.profile.avatar).font(.system(size: 30, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 72, height: 72).background(Theme.accentGradient).clipShape(RoundedRectangle(cornerRadius: 22))
                        .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(library.profile.name).font(.system(size: 26, weight: .heavy, design: .rounded)).lineLimit(1)
                        Button { editing = true } label: { Label("Profil bearbeiten", systemImage: "pencil").font(.caption.bold()) }
                            .foregroundColor(Theme.accentSoft)
                    }
                    Spacer(minLength: 0)
                }.padding(.top, 8)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Profil wechseln").font(.caption.bold()).tracking(1.2).foregroundColor(Theme.muted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(library.snapshot.profiles, id: \.profile.id) { item in
                                let active = item.profile.id == library.profile.id
                                Button {
                                    guard !active else { return }
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    library.selectProfile(item.profile.id)
                                } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: item.profile.avatar).font(.title2.weight(.semibold))
                                            .frame(width: 62, height: 62)
                                            .background(active ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.panelHigh))
                                            .clipShape(RoundedRectangle(cornerRadius: 18))
                                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(active ? Color.white.opacity(0.8) : Theme.stroke, lineWidth: active ? 2 : 1))
                                        Text(item.profile.name).font(.caption.weight(.semibold)).lineLimit(1).frame(width: 72)
                                    }
                                }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                            }
                            if library.snapshot.profiles.count < 6 {
                                Button { creating = true } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: "plus").font(.title2.weight(.semibold)).frame(width: 62, height: 62)
                                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundColor(Theme.muted))
                                        Text("Neu").font(.caption.weight(.semibold)).frame(width: 72)
                                    }
                                }.buttonStyle(LoungePressStyle()).foregroundColor(Theme.muted)
                            }
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: hoursLabel, title: "Geschaut", icon: "clock.fill")
                    StatTile(value: "\(library.active.finishedEpisodes)", title: "Folgen gesehen", icon: "checkmark.circle.fill")
                    StatTile(value: "\(library.continueWatching.count)", title: "Gerade dabei", icon: "play.fill")
                    StatTile(value: "\(library.favorites.count)", title: "Watchlist", icon: "bookmark.fill")
                }
                VStack(spacing: 0) {
                    NavigationLink { HistoryView() } label: { MenuRow(title: "Verlauf", icon: "clock.arrow.circlepath", detail: library.history.isEmpty ? nil : "\(library.history.count)") }
                    Divider().overlay(Theme.stroke).padding(.leading, 58)
                    NavigationLink { SettingsView() } label: { MenuRow(title: "Einstellungen", icon: "gearshape.fill") }
                    Divider().overlay(Theme.stroke).padding(.leading, 58)
                    Button { showingInfo = true } label: { MenuRow(title: "Über AniLounge", icon: "info.circle.fill", detail: AppInfo.version) }
                }.background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke))
                    .buttonStyle(LoungePressStyle()).foregroundColor(.white)
                Text("Profile, Watchlists und Fortschritt bleiben auf diesem Gerät. Ohne Passwort oder Cloud-Synchronisation.")
                    .font(.caption).foregroundColor(Theme.muted).lineSpacing(3)
            }.padding(.horizontal, 20)
        }
            .sheet(isPresented: $showingInfo) { InfoView() }
            .sheet(isPresented: $editing) { ProfileEditor(isNew: false).environmentObject(library) }
            .sheet(isPresented: $creating) { ProfileEditor(isNew: true).environmentObject(library) }
    }
}
private struct StatTile: View {
    let value: String
    let title: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.subheadline).foregroundColor(Theme.accentSoft)
            Text(value).font(.system(.title3, design: .rounded).bold()).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundColor(Theme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke))
    }
}
private struct MenuRow: View {
    let title: String
    let icon: String
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).frame(width: 30, height: 30)
                .background(Theme.panelHigh).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if let detail { Text(detail).font(.footnote).foregroundColor(Theme.muted) }
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundColor(Theme.muted)
        }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
    }
}
private struct ProfileEditor: View {
    let isNew: Bool
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var avatar = "sparkles"
    private let avatars = ["sparkles", "flame.fill", "moon.stars.fill", "bolt.fill", "leaf.fill", "pawprint.fill"]
    private var valid: Bool { (1...24).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) }
    var body: some View {
        NavigationStack {
            ScrollView {
              VStack(alignment: .leading, spacing: 24) {
                Section("Name") { TextField("Dein Profilname", text: $name).textInputAutocapitalization(.words) }
                Section("Profilbild") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 16) {
                        ForEach(avatars, id: \.self) { symbol in
                            Button { avatar = symbol } label: {
                                Image(systemName: symbol).font(.title).frame(width: 60, height: 60)
                                    .background(avatar == symbol ? Theme.accent : Theme.panel).foregroundColor(.white).cornerRadius(12)
                            }.buttonStyle(.plain).accessibilityLabel(symbol).accessibilityAddTraits(avatar == symbol ? .isSelected : [])
                        }
                    }.padding(.vertical, 8)
                }
                Text("Deine Watchlist und dein Fortschritt bleiben auf diesem Gerät.").font(.footnote).foregroundColor(.secondary)
              }.padding(24)
            }.background(Theme.background).navigationTitle(isNew ? "Neues Profil" : "Profil bearbeiten")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Speichern") {
                            if isNew { library.addProfile(name: name, avatar: avatar) }
                            else { library.editProfile(name: name, avatar: avatar) }
                            dismiss()
                        }.disabled(!valid)
                    }
                }
                .onAppear { if !isNew { name = library.profile.name; avatar = library.profile.avatar } }
        }
    }
}
struct ProgressEditor: View {
    let anime: Anime
    let episode: Episode
    let profileID: UUID
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = "0"
    @State private var seconds = "0"
    @State private var completed = false
    @State private var initialDuration: Double?
    private var position: Double? {
        guard let m = Int(minutes), let s = Int(seconds), m >= 0, m <= 1440, (0...59).contains(s) else { return nil }
        let total = Double(m * 60 + s)
        guard total <= 86400, initialDuration == nil || total <= initialDuration! else { return nil }
        return total
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(anime.title).font(.headline); Text("Folge \(episode.number) · \(episode.title)").font(.subheadline) }
                Section("Bis hier geschaut") {
                    HStack { Text("Minuten"); Spacer(); TextField("0", text: $minutes).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90) }
                    HStack { Text("Sekunden"); Spacer(); TextField("0", text: $seconds).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90) }
                    Toggle("Folge vollständig gesehen", isOn: $completed)
                    if let duration = initialDuration { Text("Gesamtlänge: \(EpisodeProgress.format(duration))").font(.caption).foregroundColor(.secondary) }
                    if position == nil { Text("Bitte eine gültige Zeit innerhalb der Folge eingeben.").font(.caption).foregroundColor(.orange) }
                }
                Section {
                    Text("Bei unterstützten Videos wird deine Position automatisch gespeichert. Hier kannst du sie ergänzen oder korrigieren.")
                }.font(.footnote).foregroundColor(.secondary)
            }.navigationTitle("Fortschritt")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Speichern") {
                            guard let value = position else { return }
                            library.saveProgress(episode, anime: anime, seconds: completed ? (initialDuration ?? value) : value,
                                                 duration: initialDuration, completed: completed, profileID: profileID)
                            dismiss()
                        }.disabled(position == nil)
                    }
                }.onAppear {
                    if let old = library.progress(for: episode, profileID: profileID) {
                        minutes = String(Int(old.seconds) / 60); seconds = String(Int(old.seconds) % 60)
                        completed = old.completed; initialDuration = old.duration
                    }
                }
        }
    }
}

