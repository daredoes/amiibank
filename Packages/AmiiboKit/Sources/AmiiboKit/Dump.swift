import Foundation

/// An NTAG215 memory image: 135 pages of 4 bytes.
public struct Dump: Hashable, Sendable {
    public static let size = 540
    /// Size of one entry in a combined backup file (540 bytes plus 32 bytes of signature data).
    public static let bundleStride = 572

    public enum Error: Swift.Error, Equatable {
        case badSize(Int)
        case badUID
    }

    public let data: Data

    /// Accepts 532-byte (no config pages), 540-byte and 572-byte dumps.
    public init(_ raw: Data) throws {
        let bytes = Data(raw)
        switch bytes.count {
        case 532: data = bytes + Data(repeating: 0, count: 8)
        case 540...Self.bundleStride: data = bytes.prefix(Self.size)
        default: throw Error.badSize(bytes.count)
        }
    }

    /// Splits a combined backup made of back-to-back 572-byte entries.
    public static func split(bundle: Data) throws -> [Dump] {
        let bytes = Data(bundle)
        guard bytes.count % bundleStride == 0, !bytes.isEmpty else { throw Error.badSize(bytes.count) }
        return try stride(from: 0, to: bytes.count, by: bundleStride).map {
            try Dump(bytes[$0 ..< $0 + bundleStride])
        }
    }

    /// Joins dumps into one combined backup, the inverse of `split(bundle:)`. Padding bytes are zero.
    public static func bundle(_ dumps: [Dump]) -> Data {
        dumps.reduce(into: Data()) { $0 += $1.data + Data(count: bundleStride - size) }
    }

    /// Unions combined backups by amiibo ID. For an ID in several backups, the copy from the earliest backup wins.
    public static func mergeBundles(_ bundles: [Data]) throws -> Data {
        var seen = Set<UInt64>()
        let dumps = try bundles.flatMap { $0.isEmpty ? [] : try split(bundle: $0) }.filter { seen.insert($0.amiiboID).inserted }
        return bundle(dumps)
    }

    /// The 7-byte UID, skipping the BCC0 check byte at offset 3.
    public var uid: Data { data[0 ..< 3] + data[4 ..< 8] }

    /// The 8-byte amiibo identifier at pages 0x15-0x16, stored unencrypted.
    public var amiiboID: UInt64 { data[0x54 ..< 0x5C].reduce(0) { $0 << 8 | UInt64($1) } }

    public var amiiboIDHex: String { String(format: "%016llx", amiiboID) }

    public func page(_ index: Int) -> Data { data[index * 4 ..< index * 4 + 4] }

    /// Returns a copy whose UID pages hold `uid` with both check bytes recomputed. Does not re-sign.
    public func replacingUID(_ uid: Data) throws -> Dump {
        let u = [UInt8](uid)
        guard u.count == 7 else { throw Error.badUID }
        var bytes = [UInt8](data)
        bytes.replaceSubrange(0 ..< 9, with: [u[0], u[1], u[2], 0x88 ^ u[0] ^ u[1] ^ u[2],
                                              u[3], u[4], u[5], u[6], u[3] ^ u[4] ^ u[5] ^ u[6]])
        return try Dump(Data(bytes))
    }
}
