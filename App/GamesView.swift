import AmiiboKit
import SwiftUI

struct GamesView: View {
    @Environment(Library.self) private var library
    @State private var platform = Platform.nintendoSwitch
    @State private var search = ""

    private var games: [Game] {
        let all = (library.db?.games(on: platform) ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        let fav = library.meta.favoriteGames
        return all.filter { fav.contains($0.id) } + all.filter { !fav.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Platform", selection: $platform) {
                    ForEach(Platform.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                ForEach(games) { game in
                    NavigationLink(value: game) {
                        let have = game.amiiboIDs.intersection(library.ownedIDs).count
                        HStack {
                            VStack(alignment: .leading) {
                                Text(game.name)
                                Text("\(have) of \(game.amiiboIDs.count) amiibo").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if library.meta.favoriteGames.contains(game.id) { Image(systemName: "heart.fill").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Games")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Game.self) { GameDetailView(game: $0) }
        }
    }
}

struct GameDetailView: View {
    let game: Game
    @Environment(Library.self) private var library
    @Environment(Actions.self) private var actions
    @State private var selecting = false
    @State private var selected: Set<UInt64> = []

    private var slotted: Set<UInt64> { Set(library.meta.n2?.banks.compactMap { $0 } ?? []) }
    private var ownedUses: [GameUse] { game.uses.filter { library.amiibo($0.amiibo) != nil } }
    private var freeSlots: Int { N2Elite.maxBanks - (library.meta.n2?.filled ?? 0) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    Text(game.name).font(.title.weight(.semibold)).multilineTextAlignment(.center)
                    Text("\(game.platform.rawValue) · you own \(ownedUses.count) of \(game.uses.count)").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if selecting {
                Section {
                    ForEach(ownedUses, id: \.amiibo) { use in
                        Button { toggle(use.amiibo) } label: {
                            HStack {
                                Image(systemName: selected.contains(use.amiibo) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(use.amiibo) ? Theme.accent : .secondary)
                                row(use, info: library.db?.info(use.amiibo), owned: true)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(slotted.contains(use.amiibo))
                    }
                } header: {
                    HStack {
                        Text("\(selected.count) selected")
                        Spacer()
                        Button("All") { selected = Set(ownedUses.map(\.amiibo)).subtracting(slotted) }
                        Button("None") { selected = [] }
                    }
                } footer: {
                    if library.meta.n2 == nil {
                        Text("Scan your N2 first so amiibo already on it are skipped.")
                    } else if selected.count > freeSlots {
                        Text("Only \(freeSlots) slots are free. The first \(freeSlots) will load.")
                    }
                }
            } else {
                ForEach(game.uses, id: \.amiibo) { use in
                    let info = library.db?.info(use.amiibo)
                    let owned = library.amiibo(use.amiibo)
                    if let dest = owned.map(Detail.owned) ?? info.map(Detail.missing) {
                        NavigationLink(value: dest) { row(use, info: info, owned: owned != nil) }
                    } else {
                        row(use, info: info, owned: false)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                Button {
                    let picks = ownedUses.filter { selected.contains($0.amiibo) }.compactMap { library.amiibo($0.amiibo) }
                    selecting = false
                    actions.loadOntoN2(Array(picks.prefix(freeSlots)))
                } label: {
                    Text("Load \(min(selected.count, freeSlots)) onto N2").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selected.isEmpty || freeSlots == 0)
                .padding()
            }
        }
        .navigationDestination(for: Detail.self) { AmiiboDetailView(detail: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Done" : "Load to N2") {
                    if !selecting { selected = Set(ownedUses.map(\.amiibo)).subtracting(slotted) }
                    selecting.toggle()
                }
                .disabled(ownedUses.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { library.toggleFavorite(game) } label: {
                    Image(systemName: library.meta.favoriteGames.contains(game.id) ? "heart.fill" : "heart")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ id: UInt64) {
        if !selected.insert(id).inserted { selected.remove(id) }
    }

    private func row(_ use: GameUse, info: AmiiboInfo?, owned: Bool) -> some View {
        HStack(spacing: 16) {
            AmiiboArt(url: info?.imageURL, size: 56).opacity(owned ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 4) {
                Text(info?.name ?? String(format: "%016llx", use.amiibo)).font(.headline)
                if slotted.contains(use.amiibo) {
                    Text("On N2").font(.caption.bold()).foregroundStyle(Theme.accent)
                }
                Text(use.usage).font(.subheadline).foregroundStyle(.secondary).lineLimit(selecting ? 1 : nil)
            }
            Spacer()
            if owned && !selecting { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
        }
    }
}
