import SwiftUI
import AniCore

struct ProfileView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var editing = false
    @State private var creating = false
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: library.profile.avatar).font(.system(size: 42)).foregroundColor(Theme.accent)
                        .frame(width: 90, height: 90).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 24))
                    Text(library.profile.name).font(.title.bold())
                    Text("Lokales Profil · auf diesem Gerät").font(.caption).foregroundColor(.secondary)
                    Button("Profil bearbeiten") { editing = true }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
            }.listRowBackground(Color.clear)
            Section("Deine Sammlung") {
                Label("\(library.favorites.count) Anime auf deiner Watchlist", systemImage: "bookmark.fill")
                Label("\(library.watched.count) Folgen gesehen", systemImage: "checkmark.circle.fill")
                Label("\(library.continueWatching.count) Anime zum Weiterschauen", systemImage: "play.circle.fill")
            }
            Section("Profil wechseln") {
                ForEach(library.snapshot.profiles, id: \.profile.id) { item in
                    Button { library.selectProfile(item.profile.id) } label: {
                        HStack {
                            Image(systemName: item.profile.avatar).foregroundColor(Theme.accent).frame(width: 28)
                            Text(item.profile.name).foregroundColor(.primary)
                            Spacer()
                            if item.profile.id == library.profile.id { Image(systemName: "checkmark").foregroundColor(Theme.accent) }
                        }.padding(.vertical, 5)
                    }
                }
                if library.snapshot.profiles.count < 6 {
                    Button { creating = true } label: { Label("Profil hinzufügen", systemImage: "plus") }
                }
            }
            Section {
                Text("Jedes Profil hat eine eigene Watchlist und einen eigenen Fortschritt. Profile sind keine passwortgeschützten Konten und werden nicht zwischen Geräten synchronisiert.")
                Text("Die Anmeldung auf Videowebseiten gehört zum Browser und kann von allen lokalen Profilen genutzt werden.")
            }.font(.footnote).foregroundColor(.secondary)
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Profil")
            .sheet(isPresented: $editing) { ProfileEditor(isNew: false).environmentObject(library) }
            .sheet(isPresented: $creating) { ProfileEditor(isNew: true).environmentObject(library) }
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
            Form {
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
            }.navigationTitle(isNew ? "Neues Profil" : "Profil bearbeiten")
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
