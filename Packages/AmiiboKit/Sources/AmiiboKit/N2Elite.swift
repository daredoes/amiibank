import Foundation

/// N2 Elite / Amiiqo commands, sent over ISO 14443-3A like NTAG commands.
/// Protocol source: Proxmark3 traces at https://wiki.yobi.be/index.php/N2_Elite
public enum N2Elite {
    public static let maxBanks = 200
    public static let pagesPerBank = 135

    public struct Info: Equatable, Sendable {
        public let activeBank: Int
        public let bankCount: Int
    }

    /// Reply to GET_INFO: [active bank, bank count, button pressed, ?]. Older units may reply with 2 bytes.
    public static func parseInfo(_ reply: Data) -> Info? {
        let r = [UInt8](reply)
        guard r.count >= 2 else { return nil }
        return Info(activeBank: Int(r[0]), bankCount: Int(r[1]))
    }

    public static func getInfo() -> Data { Data([0x55]) }
    public static func getID() -> Data { Data([0x43]) }
    /// The N2 accepts any password and always answers 0x8080.
    public static func passwordAuth() -> Data { Data([0x1B, 0xFF, 0xFF, 0xFF, 0xFF]) }

    public static func setBankCount(_ n: Int) -> Data {
        precondition((1 ... maxBanks).contains(n))
        return Data([0xA9, UInt8(n)])
    }

    public static func selectBank(_ bank: Int) -> Data { Data([0xA7, bankByte(bank)]) }

    /// Inclusive page range from one bank; the bank needn't be active.
    public static func fastRead(bank: Int, from start: UInt8, to end: UInt8) -> Data {
        Data([0x3B, start, end, bankByte(bank)])
    }

    public static func write(bank: Int, page: UInt8, bytes: Data) -> Data {
        precondition(bytes.count == 4)
        return Data([0xA5, page, bankByte(bank)]) + bytes
    }

    /// Reads the 8-byte amiibo ID of a bank (pages 0x15-0x16).
    public static func readID(bank: Int) -> Data { fastRead(bank: bank, from: 0x15, to: 0x16) }

    /// Page ranges that together read a full 540-byte bank, sized to stay under reader frame limits.
    public static let dumpChunks: [(UInt8, UInt8)] = [(0x00, 0x1F), (0x20, 0x3F), (0x40, 0x5F), (0x60, 0x7F), (0x80, 0x86)]

    /// Every page of `dump` as N2 writes into `bank`, password first.
    public static func writePlan(_ dump: Dump, bank: Int) -> [Data] {
        [passwordAuth()] + (0 ..< pagesPerBank).map { write(bank: bank, page: UInt8($0), bytes: dump.page($0)) }
    }

    /// A bank whose ID pages are all 0xFF or all 0x00 holds nothing.
    public static func isEmpty(id: Data) -> Bool { id.allSatisfy { $0 == 0xFF } || id.allSatisfy { $0 == 0 } }

    static func bankByte(_ bank: Int) -> UInt8 {
        precondition((0 ..< maxBanks).contains(bank))
        return UInt8(bank)
    }
}
