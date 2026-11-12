import AmiiboKit
import CoreNFC
import Foundation

enum TagError: LocalizedError {
    case unavailable, notMiFare, notNTAG215, notBlank, noKeys, nack(UInt8?), badReply, n2Full

    var errorDescription: String? {
        switch self {
        case .unavailable: "This iPhone can't read NFC tags."
        case .notMiFare: "That isn't an NTAG tag."
        case .notNTAG215: "That tag isn't an NTAG215."
        case .notBlank: "That tag is already locked. Use a blank NTAG215."
        case .noKeys: "Import your key_retail.bin in Settings first."
        case .nack(let b): "The tag refused a write (reply \(b.map { String(format: "0x%02X", $0) } ?? "empty"))."
        case .badReply: "The tag sent an unexpected reply."
        case .n2Full: "All 200 N2 slots are full."
        }
    }
}

/// Runs one job against the first ISO 14443 tag presented, then closes the NFC sheet.
final class TagReader: NSObject, NFCTagReaderSessionDelegate {
    typealias Job = (NFCMiFareTag, NFCTagReaderSession) async throws -> String

    private var job: Job?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: NFCTagReaderSession?

    func run(prompt: String, _ job: @escaping Job) async throws {
        guard NFCTagReaderSession.readingAvailable else { throw TagError.unavailable }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.job = job
            continuation = c
            session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: nil)
            session?.alertMessage = prompt
            session?.begin()
        }
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        finish(.failure(error))
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first, case .miFare(let tag) = first, let job else {
            session.invalidate(errorMessage: TagError.notMiFare.localizedDescription)
            return
        }
        Task {
            do {
                try await session.connect(to: first)
                let message = try await job(tag, session)
                session.alertMessage = message
                finish(.success(()))
                session.invalidate()
            } catch {
                finish(.failure(error))
                session.invalidate(errorMessage: error.localizedDescription)
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        job = nil
    }
}

extension NFCMiFareTag {
    func send(_ packet: Data) async throws -> Data {
        try await sendMiFareCommand(commandPacket: packet)
    }

    /// Sends a write and requires the 4-bit ACK.
    func sendExpectingAck(_ packet: Data) async throws {
        let reply = try await send(packet)
        guard reply.first == NTAG215.ack else { throw TagError.nack(reply.first) }
    }
}

enum TagJobs {
    /// Re-signs `dump` for a blank NTAG215's UID and writes it, locking the tag at the end.
    static func writeNTAG215(_ dump: Dump, keys: AmiiboKeys) -> TagReader.Job {
        { tag, session in
            guard NTAG215.isNTAG215(version: try await tag.send(NTAG215.getVersion())) else { throw TagError.notNTAG215 }
            let head = try await tag.send(Data([0x30, 0x00])) // READ pages 0-3
            guard head.count >= 12, NTAG215.isBlank(page2: head[8 ..< 12]) else { throw TagError.notBlank }
            let bound = try AmiiboCrypto.rebind(dump, toUID: tag.identifier, keys: keys)
            let plan = NTAG215.writePlan(for: bound)
            for (i, w) in plan.enumerated() {
                if i % 16 == 0 { session.alertMessage = "Writing… \(i * 100 / plan.count)%" }
                try await tag.sendExpectingAck(NTAG215.write(w))
            }
            return "Done. Tag written."
        }
    }

    static func n2Info(_ tag: NFCMiFareTag) async throws -> N2Elite.Info {
        guard let info = N2Elite.parseInfo(try await tag.send(N2Elite.getInfo())) else { throw TagError.badReply }
        return info
    }

    /// Reads bank count, active bank and every bank's amiibo ID.
    static func n2Scan(_ tag: NFCMiFareTag, session: NFCTagReaderSession) async throws -> N2Snapshot {
        let info = try await n2Info(tag)
        var banks: [UInt64?] = []
        for i in 0 ..< info.bankCount {
            session.alertMessage = "Reading slot \(i + 1) of \(info.bankCount)…"
            let id = try await tag.send(N2Elite.readID(bank: i))
            banks.append(N2Elite.isEmpty(id: id) ? nil : id.reduce(0) { $0 << 8 | UInt64($1) })
        }
        return N2Snapshot(activeBank: info.activeBank, bankCount: info.bankCount, banks: banks)
    }

    /// Writes `dump` into the first empty slot, growing the bank count when the slot is past the end.
    static func n2Add(_ tag: NFCMiFareTag, session: NFCTagReaderSession, dump: Dump) async throws -> N2Snapshot {
        var snap = try await n2Scan(tag, session: session)
        guard let slot = snap.firstEmpty else { throw TagError.n2Full }
        try await n2WriteBank(tag, session: session, dump: dump, bank: slot)
        if slot >= snap.bankCount {
            try await tag.sendExpectingAck(N2Elite.setBankCount(slot + 1))
            snap.bankCount = slot + 1
            snap.banks.append(dump.amiiboID)
        } else {
            snap.banks[slot] = dump.amiiboID
        }
        return snap
    }

    /// Writes each dump not already on the N2 into empty slots until `deadline`, then grows the bank count once.
    /// `progress` gets the snapshot after every slot so a cut-off session keeps what it finished.
    static func n2AddMany(_ tag: NFCMiFareTag, session: NFCTagReaderSession, dumps: [Dump], deadline: Date,
                          progress: @escaping (N2Snapshot, UInt64) -> Void) async throws -> N2Snapshot {
        var snap = try await n2Scan(tag, session: session)
        let startCount = snap.bankCount
        for (i, dump) in dumps.enumerated() where !snap.banks.contains(dump.amiiboID) {
            guard Date() < deadline else { break }
            guard let slot = snap.firstEmpty else { throw TagError.n2Full }
            session.alertMessage = "Loading \(i + 1) of \(dumps.count) into slot \(slot + 1)…"
            try await n2WriteBank(tag, session: session, dump: dump, bank: slot)
            if slot < snap.banks.count { snap.banks[slot] = dump.amiiboID } else { snap.banks.append(dump.amiiboID) }
            progress(snap, dump.amiiboID)
        }
        if snap.banks.count > startCount {
            try await tag.sendExpectingAck(N2Elite.setBankCount(snap.banks.count))
            snap.bankCount = snap.banks.count
        }
        return snap
    }

    /// Re-signs the amiibo in `bank` for a new UID. The library copy is untouched.
    static func n2Randomize(_ tag: NFCMiFareTag, session: NFCTagReaderSession, bank: Int, uid: Data, keys: AmiiboKeys) async throws {
        let dump = try await n2ReadBank(tag, bank: bank)
        try await n2WriteBank(tag, session: session, dump: try AmiiboCrypto.rebind(dump, toUID: uid, keys: keys), bank: bank)
    }

    static func n2ReadBank(_ tag: NFCMiFareTag, bank: Int) async throws -> Dump {
        var data = Data()
        for (start, end) in N2Elite.dumpChunks {
            data += try await tag.send(N2Elite.fastRead(bank: bank, from: start, to: end))
        }
        return try Dump(data)
    }

    static func n2WriteBank(_ tag: NFCMiFareTag, session: NFCTagReaderSession, dump: Dump, bank: Int) async throws {
        let plan = N2Elite.writePlan(dump, bank: bank)
        _ = try await tag.send(plan[0]) // PWD_AUTH answers 0x8080, not an ACK
        for (i, packet) in plan.dropFirst().enumerated() {
            if i % 16 == 0 { session.alertMessage = "Writing bank \(bank + 1)… \(i * 100 / plan.count)%" }
            try await tag.sendExpectingAck(packet)
        }
    }
}
