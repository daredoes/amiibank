import AmiiboKit
import Foundation
import Observation

struct Amiibo: Identifiable, Hashable {
    let url: URL
    let dump: Dump
    let info: AmiiboInfo?
    var id: URL { url }
    var name: String { info?.name ?? url.deletingPathExtension().lastPathComponent }
}

/// Last scan of the N2 Elite, so the N2 tab shows something before the next tap.
struct N2Snapshot: Codable, Equatable {
    var activeBank: Int
    var bankCount: Int
    /// Amiibo ID per bank, nil when empty.
    var banks: [UInt64?]

    var filled: Int { banks.compactMap { $0 }.count }
    var firstEmpty: Int? { banks.firstIndex { $0 == nil } ?? (banks.count < N2Elite.maxBanks ? banks.count : nil) }
}

/// App state kept beside the collection: write counters, favorite games and the N2 snapshot.
struct Meta: Codable {
    var writes: [UInt64: Int] = [:]
    var useWriteCounter = true
    var favoriteGames: Set<String> = []
    var n2: N2Snapshot?

    /// Combines app state from several devices, newest first: highest write count, every favorite,
    /// and the newest N2 scan and counter setting.
    static func merge(_ all: [Meta]) -> Meta {
        guard var out = all.first else { return Meta() }
        for m in all.dropFirst() {
            out.writes.merge(m.writes, uniquingKeysWith: max)
            out.favoriteGames.formUnion(m.favoriteGames)
            out.n2 = out.n2 ?? m.n2
        }
        return out
    }
}

/// The collection is a folder of .bin files in Documents, so it also shows up in the Files app.
@Observable
final class Library {
    private(set) var items: [Amiibo] = []
    private(set) var keys: AmiiboKeys?
    private(set) var db: AmiiboDatabase?
    private(set) var meta = Meta()

    let folder: URL
    private let support = URL.applicationSupportDirectory
    private var keyURL: URL { support.appending(path: "key_retail.bin") }
    private var metaURL: URL { support.appending(path: "meta.json") }
    private var dbFolder: URL { support.appending(path: "db", directoryHint: .isDirectory) }

    init() {
        folder = URL.documentsDirectory.appending(path: "Library", directoryHint: .isDirectory)
        for dir in [folder, dbFolder] { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        keys = (try? Data(contentsOf: keyURL)).flatMap { try? AmiiboKeys($0) }
        meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) } ?? Meta()
        db = loadDatabase()
        reload()
    }

    // MARK: Collection

    var ownedIDs: Set<UInt64> { Set(items.map(\.dump.amiiboID)) }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        items = urls.filter { $0.pathExtension.lowercased() == "bin" }
            .compactMap { url in
                guard let dump = (try? Data(contentsOf: url)).flatMap({ try? Dump($0) }) else { return nil }
                return Amiibo(url: url, dump: dump, info: db?.info(dump.amiiboID))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Imports single dumps and combined 572-byte-stride backups. Returns how many new amiibo were added.
    @discardableResult
    func importFiles(_ urls: [URL]) throws -> Int {
        var added = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            if data.count == 160, (try? importKey(data)) != nil { continue }
            added += try importData(data, name: url.deletingPathExtension().lastPathComponent)
        }
        return added
    }

    /// Adds a single dump or a combined backup, skipping amiibo already in the collection.
    @discardableResult
    func importData(_ data: Data, name: String) throws -> Int {
        var known = ownedIDs
        var added = 0
        let isBundle = data.count > Dump.bundleStride && data.count % Dump.bundleStride == 0
        let dumps = isBundle ? try Dump.split(bundle: data) : [try Dump(data)]
        for dump in dumps where known.insert(dump.amiiboID).inserted {
            try save(dump, named: db?.info(dump.amiiboID)?.name ?? (isBundle ? dump.amiiboIDHex : name))
            added += 1
        }
        reload()
        return added
    }

    func save(_ dump: Dump, named base: String) throws {
        let safe = base.replacingOccurrences(of: "/", with: "-")
        var url = folder.appending(path: "\(safe).bin")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(safe) \(n).bin")
            n += 1
        }
        try dump.data.write(to: url, options: .atomic)
    }

    func delete(_ amiibo: Amiibo) throws {
        try FileManager.default.removeItem(at: amiibo.url)
        reload()
    }

    /// The whole collection as one combined backup.
    var backupData: Data { Dump.bundle(items.map(\.dump)) }

    /// Writes the combined backup to a temporary file for sharing.
    func exportBackup() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "amiibank-\(items.count).bin")
        try backupData.write(to: url, options: .atomic)
        return url
    }

    func amiibo(_ id: UInt64) -> Amiibo? { items.first { $0.dump.amiiboID == id } }

    // MARK: Keys

    func importKey(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try importKey(Data(contentsOf: url))
    }

    private func importKey(_ data: Data) throws {
        keys = try AmiiboKeys(data)
        try data.write(to: keyURL, options: [.atomic, .completeFileProtection])
    }

    // MARK: Meta

    func writes(_ id: UInt64) -> Int { meta.writes[id] ?? 0 }

    func recordWrite(_ id: UInt64) {
        guard meta.useWriteCounter else { return }
        meta.writes[id, default: 0] += 1
        saveMeta()
    }

    func setWrites(_ id: UInt64, to n: Int) {
        meta.writes[id] = n > 0 ? n : nil
        saveMeta()
    }

    func resetWrites() {
        meta.writes = [:]
        saveMeta()
    }

    func setUseWriteCounter(_ on: Bool) {
        meta.useWriteCounter = on
        saveMeta()
    }

    func toggleFavorite(_ game: Game) {
        if !meta.favoriteGames.insert(game.id).inserted { meta.favoriteGames.remove(game.id) }
        saveMeta()
    }

    func setN2(_ snapshot: N2Snapshot?) {
        meta.n2 = snapshot
        saveMeta()
    }

    func metaData() throws -> Data { try JSONEncoder().encode(meta) }

    /// Merges saved app state into this device's, keeping this device's N2 scan when it has one.
    func restoreMeta(_ data: Data) throws {
        meta = Meta.merge([meta, try JSONDecoder().decode(Meta.self, from: data)])
        saveMeta()
    }

    private func saveMeta() {
        try? JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }

    // MARK: Database

    /// Downloaded copy if present and valid, else the snapshot bundled with the app.
    private func loadDatabase() -> AmiiboDatabase? {
        for base in [dbFolder, Bundle.main.resourceURL].compactMap({ $0 }) {
            if let a = try? Data(contentsOf: base.appending(path: "amiibo.json")),
               let g = try? Data(contentsOf: base.appending(path: "games_info.json")),
               let db = try? AmiiboDatabase(amiiboJSON: a, gamesJSON: g) { return db }
        }
        return nil
    }

    /// Fetches the latest AmiiboAPI files; keeps the current catalog if the download doesn't parse.
    func reloadDatabase() async throws {
        async let a = URLSession.shared.data(from: AmiiboDatabase.amiiboURL).0
        async let g = URLSession.shared.data(from: AmiiboDatabase.gamesURL).0
        let (amiiboJSON, gamesJSON) = try await (a, g)
        let fresh = try AmiiboDatabase(amiiboJSON: amiiboJSON, gamesJSON: gamesJSON)
        try amiiboJSON.write(to: dbFolder.appending(path: "amiibo.json"), options: .atomic)
        try gamesJSON.write(to: dbFolder.appending(path: "games_info.json"), options: .atomic)
        db = fresh
        reload()
    }
}
