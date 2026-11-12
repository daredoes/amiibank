// Swift port of amiitool's nfc3d code.
// Original: https://github.com/socram8888/amiitool
// (c) 2015-2017 Marcos Del Sol Vives, (c) 2016 javiMaD, (c) 2016 Michael Armbruster. MIT License (see LICENSE).

import CommonCrypto
import CryptoKit
import Foundation

/// One half of a retail key file: 80 bytes.
public struct MasterKey: Sendable {
    let hmacKey: Data
    let typeString: Data
    let magicBytes: Data
    let xorPad: Data

    init(_ raw: Data) throws {
        let b = [UInt8](raw)
        guard b.count == 80, b[31] <= 16 else { throw AmiiboKeys.Error.malformed }
        let magicSize = Int(b[31])
        hmacKey = Data(b[0 ..< 16])
        let type = b[16 ..< 30]
        // The seed takes the type string up to and including its NUL.
        typeString = Data(type.firstIndex(of: 0).map { b[16 ... $0] } ?? type)
        magicBytes = Data(b[32 ..< 32 + magicSize])
        xorPad = Data(b[48 ..< 80])
    }
}

/// The user-supplied retail key file (`key_retail.bin`, 160 bytes). Never bundled with the app.
public struct AmiiboKeys: Sendable {
    public enum Error: Swift.Error { case malformed }

    let data: MasterKey
    let tag: MasterKey

    public init(_ raw: Data) throws {
        let bytes = Data(raw)
        guard bytes.count == 160 else { throw Error.malformed }
        data = try MasterKey(bytes.prefix(80))
        tag = try MasterKey(bytes.suffix(80))
    }
}

/// Decrypts, verifies and re-signs amiibo dumps.
public enum AmiiboCrypto {
    public enum Error: Swift.Error, Equatable { case signatureMismatch }

    static let internalSize = 520

    struct DerivedKeys {
        let aesKey: Data
        let aesIV: Data
        let hmacKey: Data
    }

    /// A decrypted dump in internal layout, plus whether both signatures matched.
    public struct Plain: Sendable {
        public let bytes: Data
        public let isValid: Bool
    }

    public static func unpack(_ dump: Dump, keys: AmiiboKeys) -> Plain {
        let intl = tagToInternal([UInt8](dump.data))
        let dataKeys = derive(keys.data, intl)
        let tagKeys = derive(keys.tag, intl)
        var plain = cipher(dataKeys, intl)
        plain.replaceSubrange(0x1B4 ..< 0x1D4, with: hmac(tagKeys.hmacKey, plain[0x1D4 ..< 0x208]))
        plain.replaceSubrange(0x008 ..< 0x028, with: hmac(dataKeys.hmacKey, plain[0x029 ..< 0x208]))
        let dataOK: Bool = plain[0x008 ..< 0x028].elementsEqual(intl[0x008 ..< 0x028])
        let tagOK: Bool = plain[0x1B4 ..< 0x1D4].elementsEqual(intl[0x1B4 ..< 0x1D4])
        return Plain(bytes: Data(plain), isValid: dataOK && tagOK)
    }

    /// Encrypts and signs an internal-layout plaintext. Pages past 0x81 are copied from `template`.
    public static func pack(_ plain: Data, keys: AmiiboKeys, template: Dump) throws -> Dump {
        let p = [UInt8](plain)
        let tagKeys = derive(keys.tag, p)
        let dataKeys = derive(keys.data, p)
        let tagHMAC = hmac(tagKeys.hmacKey, p[0x1D4 ..< 0x208])
        let dataHMAC = hmac(dataKeys.hmacKey, Array(p[0x029 ..< 0x1B4]) + tagHMAC + p[0x1D4 ..< 0x208])
        var c = cipher(dataKeys, p)
        c.replaceSubrange(0x1B4 ..< 0x1D4, with: tagHMAC)
        c.replaceSubrange(0x008 ..< 0x028, with: dataHMAC)
        var tag = [UInt8](template.data)
        internalToTag(c, into: &tag)
        return try Dump(Data(tag))
    }

    /// Re-signs `dump` for a tag with a different 7-byte UID. Fails if the original signatures don't verify.
    public static func rebind(_ dump: Dump, toUID uid: Data, keys: AmiiboKeys) throws -> Dump {
        let plain = unpack(dump, keys: keys)
        guard plain.isValid else { throw Error.signatureMismatch }
        let moved = try dump.replacingUID(uid)
        var p = [UInt8](plain.bytes)
        // Internal layout keeps tag bytes 0x00-0x07 at 0x1D4 and BCC1 + internal byte at 0x000.
        p.replaceSubrange(0x1D4 ..< 0x1DC, with: moved.data[0 ..< 8])
        p.replaceSubrange(0x000 ..< 0x002, with: moved.data[8 ..< 10])
        return try pack(Data(p), keys: keys, template: moved)
    }

    // MARK: - amiitool internals

    static func tagToInternal(_ tag: [UInt8]) -> [UInt8] {
        var i = [UInt8](repeating: 0, count: internalSize)
        for (dst, src, len) in layout { i.replaceSubrange(dst ..< dst + len, with: tag[src ..< src + len]) }
        return i
    }

    static func internalToTag(_ intl: [UInt8], into tag: inout [UInt8]) {
        for (src, dst, len) in layout { tag.replaceSubrange(dst ..< dst + len, with: intl[src ..< src + len]) }
    }

    /// (internal offset, tag offset, length)
    static let layout: [(Int, Int, Int)] = [
        (0x000, 0x008, 0x008), (0x008, 0x080, 0x020), (0x028, 0x010, 0x024), (0x04C, 0x0A0, 0x168),
        (0x1B4, 0x034, 0x020), (0x1D4, 0x000, 0x008), (0x1DC, 0x054, 0x02C),
    ]

    static func seed(_ intl: [UInt8]) -> [UInt8] {
        Array(intl[0x029 ..< 0x02B]) + [UInt8](repeating: 0, count: 14)
            + intl[0x1D4 ..< 0x1DC] + intl[0x1D4 ..< 0x1DC] + intl[0x1E8 ..< 0x208]
    }

    static func derive(_ key: MasterKey, _ intl: [UInt8]) -> DerivedKeys {
        let base = seed(intl)
        let prepared = [UInt8](key.typeString) + base[0 ..< 16 - key.magicBytes.count] + key.magicBytes
            + base[16 ..< 32] + zip(base[32 ..< 64], key.xorPad).map { $0 ^ $1 }
        let out = drbg(key.hmacKey, prepared, count: 48)
        return DerivedKeys(aesKey: Data(out[0 ..< 16]), aesIV: Data(out[16 ..< 32]), hmacKey: Data(out[32 ..< 48]))
    }

    /// HMAC-SHA256 counter DRBG: each block is HMAC(key, BE16(counter) || seed).
    static func drbg(_ key: Data, _ seed: [UInt8], count: Int) -> [UInt8] {
        var out: [UInt8] = []
        var counter: UInt16 = 0
        while out.count < count {
            out += hmac(key, [UInt8(counter >> 8), UInt8(counter & 0xFF)] + seed)
            counter += 1
        }
        return Array(out.prefix(count))
    }

    static func hmac<D: Sequence>(_ key: Data, _ message: D) -> [UInt8] where D.Element == UInt8 {
        Array(HMAC<SHA256>.authenticationCode(for: Array(message), using: SymmetricKey(data: key)))
    }

    /// AES-128-CTR over internal 0x02C..<0x1B4; copies the plaintext header and tag-signed region.
    static func cipher(_ keys: DerivedKeys, _ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: internalSize)
        let body = Array(input[0x02C ..< 0x1B4])
        out.replaceSubrange(0x02C ..< 0x1B4, with: aesCTR(key: keys.aesKey, iv: keys.aesIV, body))
        out.replaceSubrange(0x000 ..< 0x008, with: input[0x000 ..< 0x008])
        out.replaceSubrange(0x028 ..< 0x02C, with: input[0x028 ..< 0x02C])
        out.replaceSubrange(0x1D4 ..< 0x208, with: input[0x1D4 ..< 0x208])
        return out
    }

    static func aesCTR(key: Data, iv: Data, _ input: [UInt8]) -> [UInt8] {
        var cryptor: CCCryptorRef?
        var out = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let created = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        precondition(created == kCCSuccess, "AES-CTR setup failed: \(created)")
        defer { CCCryptorRelease(cryptor) }
        let status = CCCryptorUpdate(cryptor, input, input.count, &out, out.count, &moved)
        precondition(status == kCCSuccess && moved == input.count, "AES-CTR failed: \(status)")
        return out
    }
}
