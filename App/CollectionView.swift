import AmiiboKit
import SwiftUI

struct Filters: Equatable {
    var set: String?
    var series: String?
    var type: String?
    var game: Game?

    func matches(_ info: AmiiboInfo?) -> Bool {
        guard set != nil || series != nil || type != nil || game != nil else { return true }
        guard let info else { return false }
        return (set == nil || info.gameSeries == set) && (series == nil || info.amiiboSeries == series)
            && (type == nil || info.type == type) && (game == nil || game!.amiiboIDs.contains(info.id))
    }
}

struct CollectionView: View {
    @Environment(Library.self) private var library
    @Environment(Actions.self) private var actions
    @State private var filters = Filters()
    @State private var search = ""
    @State private var importing = false
    @State private var showOwned = true
    @State private var showMissing = false
    @State private var sheet: Sheet?
    @State private var editing: Amiibo?
    @State private var writesText = ""

    enum Sheet: String, Identifiable {
        case set, series, type, game
        var id: String { rawValue }
    }

    private let columns = Array(repeating: GridItem(.flexible(), alignment: .top), count: 4)

    private var owned: [Amiibo] {
        library.items.filter { filters.matches($0.info) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    private var missing: [AmiiboInfo] {
        let have = library.ownedIDs
        return (library.db?.amiibo.values.map { $0 } ?? [])
            .filter { !have.contains($0.id) && filters.matches($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CountHeader(count: library.ownedIDs.count, total: library.db?.amiibo.count ?? 0,
                                caption: "\(library.db?.amiibo.count ?? 0) worldwide")
                    filterBar
                    section("MY COLLECTION", count: owned.count, open: $showOwned) {
                        ForEach(owned) { a in
                            NavigationLink(value: Detail.owned(a)) {
                                AmiiboTile(name: a.name, url: a.info?.imageURL, badge: library.badge(a.dump.amiiboID))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: a) }
                        }
                    }
                    section("MISSING", count: missing.count, open: $showMissing) {
                        ForEach(missing) { info in
                            NavigationLink(value: Detail.missing(info)) {
                                AmiiboTile(name: info.name, url: info.imageURL, dimmed: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Collection")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Detail.self) { AmiiboDetailView(detail: $0) }
            .searchable(text: $search)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                do { actions.message = "Added \(try library.importFiles(result.get())) new amiibo." }
                catch { actions.message = error.localizedDescription }
            }
            .sheet(item: $sheet) { filterSheet($0) }
            .alert("Number of writes", isPresented: Binding { editing != nil } set: { if !$0 { editing = nil } }) {
                TextField("0", text: $writesText).keyboardType(.numberPad)
                Button("Save") { if let e = editing { library.setWrites(e.dump.amiiboID, to: Int(writesText) ?? 0) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                chip("Set", filters.set, .set)
                chip("Series", filters.series, .series)
                chip("Game", filters.game?.name, .game)
                chip("Type", filters.type, .type)
            }
        }
    }

    private func chip(_ label: String, _ value: String?, _ kind: Sheet) -> some View {
        Button { sheet = kind } label: {
            HStack(spacing: 4) {
                Text(value ?? label).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.bold())
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(value == nil ? Theme.card : Theme.accent.opacity(0.3), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func unique(_ key: (AmiiboInfo) -> String) -> [String] {
        Set((library.db?.amiibo.values.map { $0 } ?? []).map(key)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @ViewBuilder
    private func filterSheet(_ kind: Sheet) -> some View {
        switch kind {
        case .set: FilterSheet(title: "Refine set", options: unique(\.gameSeries), selection: $filters.set)
        case .series: FilterSheet(title: "Refine series", options: unique(\.amiiboSeries), selection: $filters.series)
        case .type: FilterSheet(title: "Refine type", options: unique(\.type), selection: $filters.type)
        case .game: GameFilterSheet(selection: $filters.game)
        }
    }

    private func section<Content: View>(_ title: String, count: Int, open: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { withAnimation { open.wrappedValue.toggle() } } label: {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text("\(count) amiibo").foregroundStyle(.secondary)
                    Image(systemName: open.wrappedValue ? "chevron.up" : "chevron.down").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if open.wrappedValue {
                LazyVGrid(columns: columns, spacing: 24, content: content)
            }
        }
    }

    @ViewBuilder
    private func menu(for a: Amiibo) -> some View {
        Button("Write to blank tag", systemImage: "wave.3.right") { actions.writeNTAG(a) }
        Button("Add to N2", systemImage: "plus.circle") { actions.addToN2(a) }
        Button("Update number of writes", systemImage: "number") {
            writesText = "\(library.writes(a.dump.amiiboID))"
            editing = a
        }
        ShareLink(item: a.url)
        Button("Delete", systemImage: "trash", role: .destructive) { try? library.delete(a) }
    }
}

enum Detail: Hashable {
    case owned(Amiibo)
    case missing(AmiiboInfo)
}

struct GameFilterSheet: View {
    @Binding var selection: Game?
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var platform = Platform.nintendoSwitch
    @State private var draft: Game?

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Platform", selection: $platform) {
                    ForEach(Platform.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                List(library.db?.games(on: platform) ?? []) { game in
                    Button { draft = game } label: {
                        HStack {
                            Text(game.name)
                            Spacer()
                            if draft == game { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                SheetButtons(clear: { selection = nil; dismiss() }, save: { selection = draft; dismiss() }).padding()
            }
            .navigationTitle("Refine game")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            draft = selection
            platform = selection?.platform ?? .nintendoSwitch
        }
    }
}

struct AmiiboDetailView: View {
    let detail: Detail
    @Environment(Library.self) private var library
    @Environment(Actions.self) private var actions
    @State private var bank = 1

    private var amiibo: Amiibo? { if case .owned(let a) = detail { a } else { nil } }

    /// What the last N2 scan saw in `bank`.
    private func slotContent(_ bank: Int) -> AmiiboInfo? {
        guard let banks = library.meta.n2?.banks, bank < banks.count, let id = banks[bank] else { return nil }
        return library.db?.info(id)
    }

    private func slotLabel(_ bank: Int, _ info: AmiiboInfo?) -> String {
        guard let banks = library.meta.n2?.banks else { return "Scan the N2 to see slots" }
        if let info { return info.name }
        return bank < banks.count && banks[bank] != nil ? "Unknown amiibo" : "Empty"
    }
    private var info: AmiiboInfo? {
        switch detail {
        case .owned(let a): a.info
        case .missing(let i): i
        }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    AmiiboArt(url: info?.imageURL, size: 200)
                    Text(info?.name ?? amiibo?.name ?? "Unknown").font(.title.weight(.semibold))
                    if let info { Text("\(info.amiiboSeries) · \(info.type)").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if let amiibo {
                Section {
                    Button("Write to blank tag", systemImage: "wave.3.right") { actions.writeNTAG(amiibo) }
                        .disabled(library.keys == nil)
                    Button("Add to N2", systemImage: "plus.circle") { actions.addToN2(amiibo) }
                    Stepper(value: $bank, in: 1 ... N2Elite.maxBanks) {
                        let current = slotContent(bank - 1)
                        HStack(spacing: 12) {
                            AmiiboArt(url: current?.imageURL, size: 44).opacity(current == nil ? 0.3 : 1)
                            VStack(alignment: .leading) {
                                Text("N2 slot \(bank)")
                                Text(slotLabel(bank - 1, current)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Write to N2 slot \(bank)", systemImage: "square.and.arrow.down.on.square") { actions.writeBank(amiibo, bank: bank - 1) }
                    ShareLink(item: amiibo.url)
                } footer: {
                    Text(library.keys == nil ? "Writing blank tags needs your key file (Settings)." : "A blank tag can be written once; it locks afterwards.")
                }
            }
            Section("Details") {
                if let info {
                    LabeledContent("Set", value: info.gameSeries)
                    LabeledContent("Character", value: info.character)
                    if let r = info.release { LabeledContent("Released", value: r) }
                }
                if let amiibo {
                    LabeledContent("Writes", value: "\(library.writes(amiibo.dump.amiiboID))")
                    LabeledContent("UID", value: amiibo.dump.uid.map { String(format: "%02X", $0) }.joined(separator: " "))
                    if let keys = library.keys {
                        LabeledContent("Signature", value: AmiiboCrypto.unpack(amiibo.dump, keys: keys).isValid ? "Valid" : "Invalid")
                    }
                }
                LabeledContent("ID", value: info?.idHex ?? amiibo?.dump.amiiboIDHex ?? "")
            }
            if let info, let games = library.db?.games(using: info.id), !games.isEmpty {
                Section("Used in") {
                    ForEach(games) { game in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(game.name).font(.headline)
                            Text(game.platform.rawValue).font(.caption).foregroundStyle(.secondary)
                            Text(game.uses.first { $0.amiibo == info.id }?.usage ?? "").font(.subheadline)
                        }
                    }
                }
            }
        }
        .navigationTitle(info?.name ?? amiibo?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }
}
