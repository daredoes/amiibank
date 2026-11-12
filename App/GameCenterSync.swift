import AmiiboKit
import GameKit
import Observation
import UIKit

/// Backs the collection up as Game Center saved games: one combined backup plus app state.
/// Saves only ever grow: backups merge with what's already saved, and conflicting copies are unioned.
@Observable
final class GameCenterSync {
    enum State: Equatable { case signedOut, signingIn, ready, failed(String) }

    private(set) var state = State.signedOut
    private(set) var lastSave: Date?
    private(set) var busy = false

    static let collectionSave = "collection"
    static let metaSave = "meta"

    func signIn() {
        guard state != .ready else { return }
        state = .signingIn
        GKLocalPlayer.local.authenticateHandler = { [weak self] controller, error in
            guard let self else { return }
            if let controller {
                Self.topController()?.present(controller, animated: true)
            } else if GKLocalPlayer.local.isAuthenticated {
                state = .ready
                Task { await self.refreshLastSave() }
            } else {
                state = .failed(error?.localizedDescription ?? "Game Center isn't signed in.")
            }
        }
    }

    /// Saves this device's collection merged with the saved one. Returns how many amiibo the save now holds.
    func backUp(_ library: Library) async throws -> Int {
        busy = true
        defer { busy = false }
        let saves = try await GKLocalPlayer.local.fetchSavedGames()
        let remote = try await merged(Self.collectionSave, in: saves, by: Dump.mergeBundles)
        let collection = try Dump.mergeBundles([library.backupData, remote ?? Data()])
        let remoteMeta = try await merged(Self.metaSave, in: saves, by: Self.mergeMeta)
        let meta = try Self.mergeMeta([library.metaData(), remoteMeta].compactMap { $0 })
        try await GKLocalPlayer.local.saveGameData(collection, withName: Self.collectionSave)
        try await GKLocalPlayer.local.saveGameData(meta, withName: Self.metaSave)
        await refreshLastSave()
        return collection.count / Dump.bundleStride
    }

    /// Adds saved amiibo missing here and merges app state. Returns how many amiibo were new.
    func restore(into library: Library) async throws -> Int {
        busy = true
        defer { busy = false }
        let saves = try await GKLocalPlayer.local.fetchSavedGames()
        var added = 0
        if let data = try await merged(Self.collectionSave, in: saves, by: Dump.mergeBundles), !data.isEmpty {
            added = try library.importData(data, name: "backup")
        }
        if let data = try await merged(Self.metaSave, in: saves, by: Self.mergeMeta) {
            try library.restoreMeta(data)
        }
        return added
    }

    /// Loads every copy of a save, newest first, and merges them. When devices saved separately,
    /// the conflict is resolved with the merged data so no device's additions are lost.
    private func merged(_ name: String, in saves: [GKSavedGame], by merge: ([Data]) throws -> Data) async throws -> Data? {
        let copies = saves.filter { $0.name == name }.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        guard !copies.isEmpty else { return nil }
        var datas: [Data] = []
        for copy in copies { datas.append(try await copy.loadData()) }
        let data = try merge(datas)
        if copies.count > 1 {
            _ = try await GKLocalPlayer.local.resolveConflictingSavedGames(copies, with: data)
        }
        return data
    }

    private static func mergeMeta(_ datas: [Data]) throws -> Data {
        try JSONEncoder().encode(Meta.merge(datas.compactMap { try? JSONDecoder().decode(Meta.self, from: $0) }))
    }

    private func refreshLastSave() async {
        let saves = (try? await GKLocalPlayer.local.fetchSavedGames()) ?? []
        lastSave = saves.filter { $0.name == Self.collectionSave }.compactMap(\.modificationDate).max()
    }

    private static func topController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        var top = root
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
