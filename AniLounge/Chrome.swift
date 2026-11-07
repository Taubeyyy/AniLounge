import SwiftUI
import UIKit
import AniCore

// MARK: Custom navigation chrome
/// The system bar is hidden on every screen; keep the edge swipe to go back.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
/// Scroll screen with a top bar that is transparent over artwork and turns solid once scrolled.
/// Only crossing the threshold updates state, so scrolling does not re-render the content.
struct LoungeScroll<Content: View, Leading: View, Trailing: View>: View {
    let title: String
    var largeTitle = false
    var underBar = false
    var threshold: CGFloat = 40
    let content: Content
    let leading: Leading
    let trailing: Trailing
    @State private var scrolled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(title: String, largeTitle: Bool = false, underBar: Bool = false, threshold: CGFloat = 40,
         @ViewBuilder content: () -> Content, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.largeTitle = largeTitle; self.underBar = underBar; self.threshold = threshold
        self.content = content(); self.leading = leading(); self.trailing = trailing()
    }
    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    GeometryReader { Color.clear.preference(key: ScrollOffsetKey.self, value: -$0.frame(in: .named("lounge.scroll")).minY) }.frame(height: 0)
                    if !underBar { Color.clear.frame(height: 50) }
                    if largeTitle {
                        Text(title).font(.largeTitle.weight(.heavy)).tracking(-0.8).padding(.horizontal, 20).padding(.bottom, 10)
                            .accessibilityAddTraits(.isHeader)
                    }
                    content
                }.padding(.bottom, 24)
            }
            .coordinateSpace(name: "lounge.scroll")
            .ignoresSafeArea(edges: underBar ? .top : [])
            .onPreferenceChange(ScrollOffsetKey.self) { offset in
                let passed = offset > threshold
                if passed != scrolled { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scrolled = passed } }
            }
            LoungeTopBar(solid: scrolled, title: title, leading: { leading }, trailing: { trailing })
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
extension LoungeScroll where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, largeTitle: Bool = false, underBar: Bool = false, threshold: CGFloat = 40, @ViewBuilder content: () -> Content) {
        self.init(title: title, largeTitle: largeTitle, underBar: underBar, threshold: threshold, content: content, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}
extension LoungeScroll where Trailing == EmptyView {
    init(title: String, largeTitle: Bool = false, underBar: Bool = false, threshold: CGFloat = 40,
         @ViewBuilder content: () -> Content, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, largeTitle: largeTitle, underBar: underBar, threshold: threshold, content: content, leading: leading, trailing: { EmptyView() })
    }
}
struct LoungeTopBar<Leading: View, Trailing: View>: View {
    let solid: Bool
    let title: String
    let leading: Leading
    let trailing: Trailing
    init(solid: Bool, title: String = "", @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.solid = solid; self.title = title; self.leading = leading(); self.trailing = trailing()
    }
    var body: some View {
        ZStack {
            Text(title).font(.headline).lineLimit(1).padding(.horizontal, 64).opacity(solid ? 1 : 0)
            HStack(spacing: 10) { leading; Spacer(minLength: 0); trailing }
        }
        .frame(height: 50).padding(.horizontal, 16)
        .background {
            ZStack {
                LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0)], startPoint: .top, endPoint: .bottom).opacity(solid ? 0 : 1)
                Rectangle().fill(.ultraThinMaterial).overlay(Theme.background.opacity(0.6))
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 0.5) }
                    .opacity(solid ? 1 : 0)
            }.ignoresSafeArea(edges: .top).allowsHitTesting(false)
        }
    }
}
struct CircleIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
            .frame(width: 38, height: 38).background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(.white.opacity(0.12)))
            .frame(width: 48, height: 48).contentShape(Rectangle())
    }
}
struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: { CircleIcon(systemName: "chevron.left") }.buttonStyle(LoungePressStyle()).accessibilityLabel("Zurück")
    }
}
struct LoungeLogo: View {
    var body: some View {
        HStack(spacing: 1) {
            Text("ANI").foregroundColor(Theme.accentSoft)
            Text("LOUNGE").foregroundColor(.white)
        }.font(.system(size: 21, weight: .black, design: .rounded)).tracking(-0.6).shadow(color: .black.opacity(0.4), radius: 6)
            .accessibilityElement(children: .ignore).accessibilityLabel("AniLounge")
    }
}
/// Landscape artwork: AniWorld's wide backdrop, falling back to the poster.
struct WideArtwork: View {
    let anime: Anime
    @State private var resolved: (id: String, url: URL?)?
    var body: some View {
        ZStack {
            if let backdrop = AniClient.shared.cachedBackdrop(for: anime) ?? (resolved?.id == anime.id ? resolved?.url : nil) { Artwork(url: backdrop) }
            else if resolved?.id == anime.id || AniClient.shared.cachedCover(for: anime) != nil {
                // No wide picture: a soft blurred backdrop with the sharp poster on top, instead of
                // stretching a small portrait poster until it turns into pixels.
                ZStack {
                    AnimeArtwork(anime: anime).blur(radius: 24).opacity(0.55)
                    AnimeArtwork(anime: anime).aspectRatio(2 / 3, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).shadow(color: .black.opacity(0.4), radius: 10).padding(.vertical, 10)
                }.clipped()
            }
            else { Theme.panel.shimmer() }
        }.task(id: anime.id) {
            let backdrop = await AniClient.shared.backdrop(for: anime)
            guard !Task.isCancelled else { return }
            resolved = (anime.id, backdrop)
        }
    }
}
enum LanguageLabel {
    /// "Mit deutschem Untertitel" becomes "DE-Sub", "Deutsch/German" becomes "DE".
    static func short(_ language: String) -> String {
        let value = language.lowercased()
        if value.contains("untertitel") || value.contains("sub") {
            if value.contains("engl") { return "EN-Sub" }
            return value.contains("deutsch") || value.contains("german") ? "DE-Sub" : "Sub"
        }
        if value.contains("deutsch") || value.contains("german") { return "DE" }
        if value.contains("engl") { return "EN" }
        if value.contains("japan") { return "JP" }
        return String(language.prefix(8))
    }
}
struct LanguageChips: View {
    let languages: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Set(languages.map(LanguageLabel.short))).sorted(), id: \.self) { label in
                Text(label).font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.25))).foregroundColor(Theme.muted)
            }
        }
    }
}
/// A slim bottom sheet in the app's style, used instead of system menus.
extension View {
    func loungeSheet<Sheet: View>(isPresented: Binding<Bool>, height: CGFloat, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        sheet(isPresented: isPresented) {
            ScrollView { content().padding(.top, 18).padding(.bottom, 24) }
                .presentationDetents([.height(height), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.background)
                .presentationCornerRadius(28)
                .preferredColorScheme(.dark)
        }
    }
}
struct SheetRow: View {
    let title: String
    let icon: String
    var detail: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 36, height: 36).background(Theme.panelHigh).clipShape(RoundedRectangle(cornerRadius: 10))
                Text(title).font(.body.weight(.semibold))
                Spacer()
                if let detail { Text(detail).font(.subheadline).foregroundColor(Theme.muted) }
            }.padding(.horizontal, 20).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(LoungePressStyle()).foregroundColor(role == .destructive ? .red : .white)
    }
}
struct SheetToggle: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 36, height: 36).background(Theme.panelHigh).clipShape(RoundedRectangle(cornerRadius: 10))
                Text(title).font(.body.weight(.semibold))
            }
        }.tint(Theme.accent).padding(.horizontal, 20).padding(.vertical, 7)
    }
}

// MARK: Toasts
/// Short confirmations for actions anywhere in the app ("Zur Watchlist hinzugefügt").
@MainActor final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    struct Toast: Equatable { let id = UUID(); let text: String; let icon: String }
    @Published private(set) var current: Toast?
    func show(_ text: String, icon: String = "checkmark.circle.fill") {
        let toast = Toast(text: text, icon: icon)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { current = toast }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if current?.id == toast.id { withAnimation(.easeOut(duration: 0.25)) { current = nil } }
        }
    }
}
struct ToastHost: View {
    @ObservedObject private var center = ToastCenter.shared
    var body: some View {
        ZStack {
            if let toast = center.current {
                Label(toast.text, systemImage: toast.icon).font(.subheadline.bold()).foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(.ultraThinMaterial).background(Theme.panelHigh.opacity(0.6)).clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.12))).shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                    .padding(.top, 6).transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id).accessibilityAddTraits(.isStaticText)
            }
        }.allowsHitTesting(false)
    }
}

/// Opening animation in the style of the app icon: the play mark settles, the progress bar
/// fills, the name appears, then everything fades into the app. Short, and skipped with
/// "Bewegung reduzieren".
struct LaunchOverlay: View {
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mark = false
    @State private var progress: CGFloat = 0
    @State private var name = false
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.36, green: 0.18, blue: 0.67), Color(red: 0.06, green: 0.035, blue: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(spacing: 26) {
                Image(systemName: "play.fill").font(.system(size: 64, weight: .bold)).foregroundColor(.white)
                    .scaleEffect(mark ? 1 : 0.6).opacity(mark ? 1 : 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(red: 0.27, green: 0.17, blue: 0.47)).frame(width: 120, height: 8)
                    Capsule().fill(Color(red: 0.78, green: 0.65, blue: 1)).frame(width: 120 * progress, height: 8)
                }
                LoungeLogo().opacity(name ? 1 : 0).offset(y: name ? 0 : 8)
            }
        }
        .accessibilityHidden(true)
        .task {
            guard !reduceMotion else { done(); return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { mark = true }
            withAnimation(.easeInOut(duration: 0.7).delay(0.15)) { progress = 1 }
            withAnimation(.easeOut(duration: 0.35).delay(0.35)) { name = true }
            try? await Task.sleep(nanoseconds: 1_050_000_000)
            withAnimation(.easeInOut(duration: 0.35)) { done() }
        }
    }
}
