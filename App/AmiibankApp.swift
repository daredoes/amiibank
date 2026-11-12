import SwiftUI

@main
struct AmiibankApp: App {
    @State private var library: Library
    @State private var actions: Actions
    @State private var gameCenter = GameCenterSync()

    init() {
        // Amiibo art comes from AmiiboAPI on first view, then from this cache.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        let library = Library()
        _library = State(initialValue: library)
        _actions = State(initialValue: Actions(library: library))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(actions)
                .environment(gameCenter)
                .task { gameCenter.signIn() }
                .tint(Theme.accent)
                .fontDesign(.rounded)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Environment(Actions.self) private var actions

    var body: some View {
        @Bindable var actions = actions
        TabView {
            Tab("Collection", systemImage: "house") { CollectionView() }
            Tab("N2", systemImage: "dot.radiowaves.left.and.right") { N2View() }
            Tab("Games", systemImage: "gamecontroller") { GamesView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        .alert(actions.message ?? "", isPresented: Binding { actions.message != nil } set: { if !$0 { actions.message = nil } }) {}
    }
}

enum Theme {
    static let accent = Color(red: 1.0, green: 0.36, blue: 0.22)
    static let card = Color(white: 0.18)
}
