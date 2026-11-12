import Foundation

/// Catalog facts for one amiibo, decoded from AmiiboAPI's `amiibo.json`.
public struct AmiiboInfo: Identifiable, Hashable, Sendable {
    public let id: UInt64
    public let name: String
    public let character: String
    public let gameSeries: String
    public let amiiboSeries: String
    public let type: String
    /// Earliest regional release date, `yyyy-mm-dd`.
    public let release: String?

    public var idHex: String { String(format: "%016llx", id) }

    public var imageURL: URL {
        let h = idHex
        return URL(string: "https://raw.githubusercontent.com/N3evin/AmiiboAPI/master/images/icon_\(h.prefix(8))-\(h.suffix(8)).png")!
    }
}

public enum Platform: String, CaseIterable, Identifiable, Sendable {
    case nintendoSwitch = "Switch", threeDS = "3DS", wiiU = "WiiU"
    public var id: String { rawValue }
}

public struct GameUse: Hashable, Sendable {
    public let amiibo: UInt64
    public let usage: String
}

public struct Game: Identifiable, Hashable, Sendable {
    public let name: String
    public let platform: Platform
    public let uses: [GameUse]
    public var id: String { "\(platform.rawValue)/\(name)" }
    public var amiiboIDs: Set<UInt64> { Set(uses.map(\.amiibo)) }
}

/// AmiiboAPI's two database files, joined. Series, type and character come from bit fields of the ID.
public struct AmiiboDatabase: Sendable {
    public let amiibo: [UInt64: AmiiboInfo]
    public let games: [Game]

    public static let amiiboURL = URL(string: "https://raw.githubusercontent.com/N3evin/AmiiboAPI/master/database/amiibo.json")!
    public static let gamesURL = URL(string: "https://raw.githubusercontent.com/N3evin/AmiiboAPI/master/database/games_info.json")!

    public init(amiiboJSON: Data, gamesJSON: Data) throws {
        let raw = try JSONDecoder().decode(RawAmiibo.self, from: amiiboJSON)
        var amiibo: [UInt64: AmiiboInfo] = [:]
        for (key, entry) in raw.amiibos {
            let h = key.lowercased().replacingOccurrences(of: "0x", with: "")
            guard h.count == 16, let id = UInt64(h, radix: 16) else { continue }
            let chars = Array(h)
            func field(_ r: Range<Int>) -> String { "0x" + String(chars[r]) }
            amiibo[id] = AmiiboInfo(
                id: id, name: entry.name,
                character: raw.characters[field(0 ..< 4)] ?? entry.name,
                gameSeries: raw.game_series[field(0 ..< 3)] ?? "Unknown",
                amiiboSeries: raw.amiibo_series[field(12 ..< 14)] ?? "Unknown",
                type: raw.types[field(6 ..< 8)] ?? "Unknown",
                release: entry.release?.values.compactMap { $0 }.min()
            )
        }
        self.amiibo = amiibo

        let rawGames = try JSONDecoder().decode(RawGames.self, from: gamesJSON)
        var byGame: [String: (Platform, String, [GameUse])] = [:]
        for (key, uses) in rawGames.amiibos {
            guard let id = UInt64(key.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) else { continue }
            for (platform, list) in [(Platform.nintendoSwitch, uses.gamesSwitch), (.threeDS, uses.games3DS), (.wiiU, uses.gamesWiiU)] {
                for g in list ?? [] {
                    let usage = g.amiiboUsage.map(\.Usage).joined(separator: "\n")
                    byGame["\(platform.rawValue)/\(g.gameName)", default: (platform, g.gameName, [])].2.append(GameUse(amiibo: id, usage: usage))
                }
            }
        }
        games = byGame.values
            .map { Game(name: $0.1, platform: $0.0, uses: $0.2.sorted { $0.amiibo < $1.amiibo }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func info(_ id: UInt64) -> AmiiboInfo? { amiibo[id] }

    public func games(on platform: Platform) -> [Game] { games.filter { $0.platform == platform } }

    public func games(using id: UInt64) -> [Game] { games.filter { $0.uses.contains { $0.amiibo == id } } }

    private struct RawAmiibo: Decodable {
        struct Entry: Decodable {
            let name: String
            let release: [String: String?]?
        }

        let amiibos: [String: Entry]
        let amiibo_series: [String: String]
        let game_series: [String: String]
        let types: [String: String]
        let characters: [String: String]
    }

    private struct RawGames: Decodable {
        struct Use: Decodable { let Usage: String }
        struct G: Decodable {
            let gameName: String
            let amiiboUsage: [Use]
        }

        struct Uses: Decodable {
            let gamesSwitch: [G]?
            let games3DS: [G]?
            let gamesWiiU: [G]?
        }

        let amiibos: [String: Uses]
    }
}
