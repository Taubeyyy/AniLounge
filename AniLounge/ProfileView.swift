import SwiftUI
import AniCore

struct ProfileView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var editing = false
    @State private var creating = false
    @State private var showingInfo = false
    private var hoursLabel: String {
        let minutes = Int(library.active.watchedSeconds / 60)
        return minutes >= 60 ? "\(minutes / 60) Std" : "\(minutes) Min"
    }
    var body: some View {
        LoungeScroll(title: library.profile.name, underBar: true, threshold: 220) {
            VStack(alignment: .leading, spacing: 26) {
                header
                stats.padding(.horizontal, 20)
                WeekActivity(profile: library.active).padding(.horizontal, 20)
                switcher
                VStack(spacing: 0) {
                    NavigationLink { HistoryView() } label: { MenuRow(title: "Verlauf", icon: "clock.arrow.circlepath", detail: library.history.isEmpty ? nil : "\(library.history.count)") }
                    Divider().overlay(Theme.stroke).padding(.leading, 56)
                    NavigationLink { FinishedView() } label: {
                        MenuRow(title: "Fertig geschaut", icon: "checkmark.seal", detail: "\(library.favorites.filter { library.status(for: $0) == .completed }.count)")
                    }
                    Divider().overlay(Theme.stroke).padding(.leading, 56)
                    NavigationLink { CalendarView() } label: { MenuRow(title: "Simulcast-Kalender", icon: "calendar") }
                    Divider().overlay(Theme.stroke).padding(.leading, 56)
                    NavigationLink { SettingsView() } label: { MenuRow(title: "Einstellungen", icon: "gearshape") }
                    Divider().overlay(Theme.stroke).padding(.leading, 56)
                    Button { showingInfo = true } label: { MenuRow(title: "Über AniLounge", icon: "info.circle", detail: AppInfo.version) }
                }.glassCard().buttonStyle(LoungePressStyle()).foregroundColor(.white).padding(.horizontal, 20)
                Text("Profile, Watchlists und Fortschritt bleiben auf diesem Gerät. Ohne Passwort oder Cloud-Synchronisation.")
                    .font(.caption).foregroundColor(Theme.muted).lineSpacing(3).padding(.horizontal, 20)
            }
        }
        .sheet(isPresented: $showingInfo) { InfoView() }
        .sheet(isPresented: $editing) { ProfileEditor(isNew: false).environmentObject(library) }
        .sheet(isPresented: $creating) { ProfileEditor(isNew: true).environmentObject(library) }
    }
    /// The last series watched sets the mood of the header, like a profile banner.
    private var header: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let recent = library.history.first { WideArtwork(anime: recent.anime).blur(radius: 18).opacity(0.7) }
                else { Theme.accentGradient.opacity(0.5) }
            }
            .frame(height: 300).clipped()
            LinearGradient(colors: [.black.opacity(0.3), Theme.background.opacity(0.6), Theme.background], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                Image(systemName: library.profile.avatar).font(.system(size: 40, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 96, height: 96).background(Theme.accentGradient).clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 2))
                    .shadow(color: Theme.accent.opacity(0.5), radius: 24, y: 10)
                Text(library.profile.name).font(.system(size: 28, weight: .heavy, design: .rounded)).lineLimit(1)
                Button { editing = true } label: {
                    Label("Profil bearbeiten", systemImage: "pencil").font(.footnote.bold()).padding(.horizontal, 16).frame(minHeight: 36)
                        .background(.ultraThinMaterial).clipShape(Capsule()).overlay(Capsule().stroke(Theme.stroke))
                }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
            }.padding(.bottom, 4)
        }.frame(height: 300).frame(maxWidth: .infinity)
    }
    private var stats: some View {
        HStack(spacing: 0) {
            stat(hoursLabel, "geschaut")
            Divider().overlay(Theme.stroke).frame(height: 34)
            stat("\(library.active.finishedEpisodes)", "Folgen")
            Divider().overlay(Theme.stroke).frame(height: 34)
            stat("\(library.continueWatching.count)", "dabei")
            Divider().overlay(Theme.stroke).frame(height: 34)
            stat("\(library.favorites.count)", "Watchlist")
        }.padding(.vertical, 14).glassCard()
    }
    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(.title3, design: .rounded).bold()).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption2).foregroundColor(Theme.muted)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
    private var switcher: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wer schaut?").font(.headline).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(library.snapshot.profiles, id: \.profile.id) { item in
                        let active = item.profile.id == library.profile.id
                        Button {
                            guard !active else { return }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            library.selectProfile(item.profile.id)
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: item.profile.avatar).font(.title2.weight(.semibold))
                                    .frame(width: 60, height: 60)
                                    .background(active ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.ultraThinMaterial))
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(active ? Color.white.opacity(0.8) : Theme.stroke, lineWidth: active ? 2 : 1))
                                Text(item.profile.name).font(.caption.weight(.semibold)).lineLimit(1).frame(width: 70)
                                    .foregroundColor(active ? .white : Theme.muted)
                            }
                        }.buttonStyle(LoungePressStyle()).foregroundColor(.white)
                    }
                    if library.snapshot.profiles.count < 6 {
                        Button { creating = true } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 60, height: 60)
                                    .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundColor(Theme.muted))
                                Text("Neu").font(.caption.weight(.semibold)).frame(width: 70)
                            }
                        }.buttonStyle(LoungePressStyle()).foregroundColor(Theme.muted)
                    }
                }.padding(.horizontal, 20)
            }
        }
    }
}
private struct MenuRow: View {
    let title: String
    let icon: String
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundColor(Theme.accentSoft).frame(width: 26)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if let detail { Text(detail).font(.footnote).foregroundColor(Theme.muted) }
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundColor(Theme.muted)
        }.padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle())
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

