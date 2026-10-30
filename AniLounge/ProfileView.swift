import SwiftUI
import AniCore

struct ProfileView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var editing = false
    @State private var creating = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(spacing: 14) {
                    Image(systemName: library.profile.avatar).font(.system(size: 44)).foregroundColor(.white)
                        .frame(width: 100, height: 100).background(Theme.accent.gradient).clipShape(RoundedRectangle(cornerRadius: 32))
                        .shadow(color: Theme.accent.opacity(0.3), radius: 24, y: 12)
                    Text(library.profile.name).font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("DEIN ANIME-ABEND").font(.caption2.bold()).tracking(3).foregroundColor(Theme.accent)
                    Button("Profil gestalten") { editing = true }.font(.subheadline.bold()).padding(.horizontal, 22).padding(.vertical, 12).loungeCard()
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
                HStack(spacing: 10) {
                    metric(library.favorites.count, "Watchlist", "bookmark.fill")
                    metric(library.watched.count, "Gesehen", "checkmark.circle.fill")
                    metric(library.continueWatching.count, "Begonnen", "play.fill")
                }
                Text("Wer schaut heute?").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 14) {
                    ForEach(library.snapshot.profiles, id: \.profile.id) { item in
                        Button { library.selectProfile(item.profile.id) } label: {
                            VStack(spacing: 12) {
                                Image(systemName: item.profile.avatar).font(.title).foregroundColor(Theme.accent)
                                Text(item.profile.name).font(.headline).foregroundColor(.white).lineLimit(2)
                                Text(item.profile.id == library.profile.id ? "Aktiv" : "Profil wechseln").font(.caption).foregroundColor(.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 24).loungeCard()
                                .overlay(RoundedRectangle(cornerRadius: 22).stroke(item.profile.id == library.profile.id ? Theme.accent : .clear))
                        }.buttonStyle(LoungePressStyle())
                    }
                    if library.snapshot.profiles.count < 6 {
                        Button { creating = true } label: {
                            VStack(spacing: 12) { Image(systemName: "plus").font(.title); Text("Neues Profil").font(.headline) }
                                .frame(maxWidth: .infinity, minHeight: 130).loungeCard()
                        }.buttonStyle(LoungePressStyle())
                    }
                }
                Label("Auf diesem Gerät", systemImage: "iphone").font(.subheadline.bold())
                Text("Jedes Profil hat seine eigene Watchlist und seinen Fortschritt. Ohne Passwort oder Cloud-Synchronisation. Browser-Anmeldungen werden gemeinsam genutzt.")
                    .font(.footnote).foregroundColor(.secondary).lineSpacing(4)
            }.padding(22)
        }.background(Theme.background).navigationTitle("Deine Lounge").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $editing) { ProfileEditor(isNew: false).environmentObject(library) }
            .sheet(isPresented: $creating) { ProfileEditor(isNew: true).environmentObject(library) }
    }
    private func metric(_ count: Int, _ title: String, _ icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(Theme.accent)
            Text("\(count)").font(.title2.bold())
            Text(title).font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 20).loungeCard()
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

