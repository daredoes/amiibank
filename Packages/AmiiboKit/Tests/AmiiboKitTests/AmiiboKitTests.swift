import Foundation
import Testing
@testable import AmiiboKit

/// Deterministic fake key material with the real file's shape. Not a Nintendo key.
func fakeKeys() throws -> AmiiboKeys {
    func half(_ type: String, magic: Int, salt: UInt8) -> [UInt8] {
        var b = (0 ..< 80).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(salt)) }
        let t = Array(type.utf8) + [0]
        b.replaceSubrange(16 ..< 16 + t.count, with: t)
        b[31] = UInt8(magic)
        return b
    }
    return try AmiiboKeys(Data(half("unfixed infos", magic: 14, salt: 1) + half("locked secret", magic: 16, salt: 9)))
}

func fakeDump(_ seed: UInt8 = 3) throws -> Dump {
    let bytes = (0 ..< Dump.size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }
    return try Dump(Data(bytes)).replacingUID(Data([0x04, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))
}

@Test func dumpSizes() throws {
    #expect(try Dump(Data(count: 532)).data.count == 540)
    #expect(try Dump(Data(count: 572)).data.count == 540)
    #expect(throws: Dump.Error.badSize(100)) { try Dump(Data(count: 100)) }
}

@Test func uidAndCheckBytes() throws {
    let d = try fakeDump()
    #expect(d.uid == Data([0x04, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))
    #expect(d.data[3] == 0x88 ^ 0x04 ^ 0x11 ^ 0x22)
    #expect(d.data[8] == 0x33 ^ 0x44 ^ 0x55 ^ 0x66)
}

@Test func splitBundle() throws {
    let a = try fakeDump(1), b = try fakeDump(2)
    let pad = Data(count: Dump.bundleStride - Dump.size)
    let parts = try Dump.split(bundle: a.data + pad + b.data + pad)
    #expect(parts == [a, b])
    #expect(try Dump.split(bundle: Dump.bundle(parts)) == parts)
    #expect(throws: Dump.Error.self) { try Dump.split(bundle: Data(count: 573)) }
}

@Test func mergeKeepsAdditionsFromEverySave() throws {
    func withID(_ id: UInt8, seed: UInt8) throws -> Dump {
        var b = [UInt8](try fakeDump(seed).data)
        b.replaceSubrange(0x54 ..< 0x5C, with: [0, 0, 0, 0, 0, 0, 0, id])
        return try Dump(Data(b))
    }
    let common = try withID(1, seed: 1), x = try withID(2, seed: 2), y = try withID(3, seed: 3)
    let commonOlder = try withID(1, seed: 9)
    let merged = try Dump.split(bundle: Dump.mergeBundles([Dump.bundle([common, x]), Dump.bundle([commonOlder, y]), Data()]))
    #expect(merged == [common, x, y])
}

@Test func packThenUnpackVerifies() throws {
    let keys = try fakeKeys()
    let raw = try fakeDump()
    #expect(!AmiiboCrypto.unpack(raw, keys: keys).isValid)
    let signed = try AmiiboCrypto.pack(AmiiboCrypto.unpack(raw, keys: keys).bytes, keys: keys, template: raw)
    let plain = AmiiboCrypto.unpack(signed, keys: keys)
    #expect(plain.isValid)
    #expect(signed.amiiboID == raw.amiiboID)
    // Re-packing a verified dump reproduces it byte for byte.
    #expect(try AmiiboCrypto.pack(plain.bytes, keys: keys, template: signed) == signed)
}

@Test func rebindMovesUIDAndKeepsSignatureValid() throws {
    let keys = try fakeKeys()
    let raw = try fakeDump()
    let signed = try AmiiboCrypto.pack(AmiiboCrypto.unpack(raw, keys: keys).bytes, keys: keys, template: raw)
    let uid = Data([0x04, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6])
    let moved = try AmiiboCrypto.rebind(signed, toUID: uid, keys: keys)
    #expect(moved.uid == uid)
    #expect(AmiiboCrypto.unpack(moved, keys: keys).isValid)
    #expect(moved.amiiboID == signed.amiiboID)
    #expect(throws: AmiiboCrypto.Error.signatureMismatch) { try AmiiboCrypto.rebind(raw, toUID: uid, keys: keys) }
}

@Test func ntagWritePlan() throws {
    let d = try fakeDump()
    let plan = NTAG215.writePlan(for: d)
    #expect(plan.count == 127 + 6)
    #expect(plan.first == .init(page: 3, bytes: d.page(3)))
    #expect(plan.map(\.page).suffix(4) == [2, 130, 131, 132])
    // UID 04 11 22 33 44 55 66 → AA^11^33, 55^22^44, AA^33^55, 55^44^66
    let expected: [UInt8] = [0x88, 0x33, 0xCC, 0x77]
    #expect(NTAG215.password(uid: d.uid) == Data(expected))
    #expect(NTAG215.isNTAG215(version: Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x11, 0x03])))
    #expect(NTAG215.isBlank(page2: Data([0x5F, 0x48, 0x00, 0x00])))
    #expect(!NTAG215.isBlank(page2: Data([0x5F, 0x48, 0x0F, 0xE0])))
}

@Test func n2Commands() throws {
    // Bytes match the traced Android app session on YobiWiki.
    #expect(N2Elite.readID(bank: 1) == Data([0x3B, 0x15, 0x16, 0x01]))
    #expect(N2Elite.setBankCount(200) == Data([0xA9, 0xC8]))
    #expect(N2Elite.write(bank: 0, page: 0x84, bytes: Data([1, 2, 3, 4])) == Data([0xA5, 0x84, 0x00, 1, 2, 3, 4]))
    #expect(N2Elite.parseInfo(Data([0x01, 0x10, 0x01, 0x03])) == .init(activeBank: 1, bankCount: 16))
    #expect(N2Elite.isEmpty(id: Data(repeating: 0xFF, count: 8)))
    let plan = N2Elite.writePlan(try fakeDump(), bank: 5)
    #expect(plan.count == 136 && plan[0] == N2Elite.passwordAuth() && plan[1].prefix(3) == Data([0xA5, 0x00, 0x05]))
}

/// Opt-in check against real data you own:
/// AMIIBANK_KEY=/path/key_retail.bin AMIIBANK_DUMP=/path/amiibo.bin swift test
@Test(.enabled(if: ProcessInfo.processInfo.environment["AMIIBANK_KEY"] != nil))
func realKeyVerifiesRealDump() throws {
    let env = ProcessInfo.processInfo.environment
    let keys = try AmiiboKeys(Data(contentsOf: URL(fileURLWithPath: env["AMIIBANK_KEY"]!)))
    let dump = try Dump(Data(contentsOf: URL(fileURLWithPath: env["AMIIBANK_DUMP"]!)))
    let plain = AmiiboCrypto.unpack(dump, keys: keys)
    #expect(plain.isValid)
    #expect(try AmiiboCrypto.pack(plain.bytes, keys: keys, template: dump).data.prefix(520) == dump.data.prefix(520))
    let moved = try AmiiboCrypto.rebind(dump, toUID: Data([0x04, 1, 2, 3, 4, 5, 6]), keys: keys)
    #expect(AmiiboCrypto.unpack(moved, keys: keys).isValid)
}

@Test func databaseDecodesIDFieldsAndGames() throws {
    let amiibo = Data("""
    {"amiibos":{"0x0438000103000502":{"name":"Sandy","release":{"na":"2016-12-02","jp":"2016-11-03","eu":null}}},
     "amiibo_series":{"0x05":"Animal Crossing"},"game_series":{"0x043":"Animal Crossing"},
     "types":{"0x01":"Card"},"characters":{"0x0438":"Sandy"}}
    """.utf8)
    let games = Data("""
    {"amiibos":{"0x0438000103000502":{"gamesSwitch":[{"gameName":"New Horizons","gameID":[],"amiiboUsage":[{"Usage":"Invite","write":false}]}],"games3DS":[],"gamesWiiU":[]}}}
    """.utf8)
    let db = try AmiiboDatabase(amiiboJSON: amiibo, gamesJSON: games)
    let sandy = try #require(db.info(0x0438_0001_0300_0502))
    #expect(sandy.type == "Card" && sandy.amiiboSeries == "Animal Crossing" && sandy.gameSeries == "Animal Crossing")
    #expect(sandy.release == "2016-11-03")
    #expect(sandy.imageURL.lastPathComponent == "icon_04380001-03000502.png")
    #expect(db.games(on: .nintendoSwitch).map(\.name) == ["New Horizons"])
    #expect(db.games(using: sandy.id).first?.uses.first?.usage == "Invite")
}
