import Foundation

/// Command bytes and the write plan for blank NTAG215 tags.
public enum NTAG215 {
    public struct PageWrite: Equatable, Sendable {
        public let page: UInt8
        public let bytes: Data
    }

    public static func getVersion() -> Data { Data([0x60]) }
    public static func fastRead(from start: UInt8, to end: UInt8) -> Data { Data([0x3A, start, end]) }
    public static func write(_ w: PageWrite) -> Data { Data([0xA2, w.page]) + w.bytes }

    /// GET_VERSION reply for an NTAG215: vendor NXP, type NTAG, storage 0x11.
    public static func isNTAG215(version: Data) -> Bool {
        let v = [UInt8](version)
        return v.count == 8 && v[1] == 0x04 && v[2] == 0x04 && v[6] == 0x11
    }

    /// A blank tag has no static lock bits set (page 2, bytes 2-3).
    public static func isBlank(page2: Data) -> Bool {
        let p = [UInt8](page2)
        return p.count >= 4 && p[2] == 0 && p[3] == 0
    }

    /// The password a Switch uses for a tag with this 7-byte UID.
    public static func password(uid: Data) -> Data {
        let u = [UInt8](uid)
        let mask: [UInt8] = [0xAA, 0x55, 0xAA, 0x55]
        return Data((0 ..< 4).map { i -> UInt8 in mask[i] ^ u[i + 1] ^ u[i + 3] })
    }

    /// Ordered writes that turn a blank tag into `dump`. The dump must already be bound to the tag's UID.
    /// Lock and config pages come last because they make the tag read-only.
    public static func writePlan(for dump: Dump) -> [PageWrite] {
        let d = [UInt8](dump.data)
        var plan = (3 ..< 130).map { PageWrite(page: UInt8($0), bytes: dump.page($0)) }
        plan += [
            PageWrite(page: 134, bytes: Data([0x80, 0x80, 0x00, 0x00])), // PACK
            PageWrite(page: 133, bytes: password(uid: dump.uid)), // PWD
            PageWrite(page: 2, bytes: Data([d[8], d[9], 0x0F, 0xE0])), // static lock
            PageWrite(page: 130, bytes: Data([0x01, 0x00, 0x0F, 0x00])), // dynamic lock
            PageWrite(page: 131, bytes: Data([0x00, 0x00, 0x00, 0x04])), // CFG0: AUTH0 = page 4
            PageWrite(page: 132, bytes: Data([0x5F, 0x00, 0x00, 0x00])), // CFG1
        ]
        return plan
    }

    /// Reply byte for a successful write.
    public static let ack: UInt8 = 0x0A
}
