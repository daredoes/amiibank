import AmiiboKit
import CoreNFC
import Foundation
import Observation

/// Every NFC action the UI offers. Results land in `message`, which the root view shows.
@Observable
final class Actions {
    var message: String?
    let library: Library
    @ObservationIgnored private let reader = TagReader()

    init(library: Library) { self.library = library }

    func writeNTAG(_ amiibo: Amiibo) {
        guard let keys = library.keys else { message = TagError.noKeys.localizedDescription; return }
        let job = TagJobs.writeNTAG215(amiibo.dump, keys: keys)
        run("Hold a blank NTAG215 to the top of your iPhone.", job) { [library] in library.recordWrite(amiibo.dump.amiiboID) }
    }

    func addToN2(_ amiibo: Amiibo) {
        var snap: N2Snapshot?
        run(n2Prompt, { tag, session in
            snap = try await TagJobs.n2Add(tag, session: session, dump: amiibo.dump)
            return "Added \(amiibo.name) to slot \((snap?.banks.lastIndex(of: amiibo.dump.amiiboID) ?? 0) + 1)."
        }) { [library] in
            library.setN2(snap)
            library.recordWrite(amiibo.dump.amiiboID)
        }
    }

    /// Loads every amiibo not already slotted, across as many NFC sessions as it takes.
    func loadOntoN2(_ amiibo: [Amiibo]) {
        let budget: TimeInterval = 40
        Task { @MainActor in
            var pending = amiibo.filter { a in !(library.meta.n2?.banks.contains(a.dump.amiiboID) ?? false) }
            var loaded = 0
            while !pending.isEmpty {
                let batch = pending
                let deadline = Date().addingTimeInterval(budget)
                var final: N2Snapshot?
                let prompt = loaded == 0 ? n2Prompt : "Keep holding the N2. \(pending.count) left."
                do {
                    try await reader.run(prompt: prompt) { [library] tag, session in
                        final = try await TagJobs.n2AddMany(tag, session: session, dumps: batch.map(\.dump), deadline: deadline) { snap, id in
                            Task { @MainActor in
                                library.setN2(snap)
                                library.recordWrite(id)
                            }
                        }
                        let done = batch.filter { final?.banks.contains($0.dump.amiiboID) ?? false }.count
                        return done == batch.count ? "All loaded." : "Loaded \(done). Starting the next batch…"
                    }
                } catch let e as NFCReaderError where e.code == .readerSessionInvalidationErrorUserCanceled {
                    message = loaded > 0 ? "Stopped after \(loaded) amiibo." : nil
                    return
                } catch {
                    message = "Stopped after \(loaded) amiibo: \(error.localizedDescription)"
                    return
                }
                if let final { library.setN2(final) }
                let slotted = Set(library.meta.n2?.banks.compactMap { $0 } ?? [])
                let before = pending.count
                pending.removeAll { slotted.contains($0.dump.amiiboID) }
                loaded += before - pending.count
                if before == pending.count { break }
            }
            message = "Loaded \(loaded) amiibo onto the N2."
        }
    }

    func writeBank(_ amiibo: Amiibo, bank: Int) {
        run(n2Prompt, { tag, session in
            try await TagJobs.n2WriteBank(tag, session: session, dump: amiibo.dump, bank: bank)
            return "Slot \(bank + 1) is now \(amiibo.name)."
        }) { [library] in
            if var snap = library.meta.n2, bank < snap.banks.count {
                snap.banks[bank] = amiibo.dump.amiiboID
                library.setN2(snap)
            }
            library.recordWrite(amiibo.dump.amiiboID)
        }
    }

    func scanN2() {
        var snap: N2Snapshot?
        run(n2Prompt, { tag, session in
            snap = try await TagJobs.n2Scan(tag, session: session)
            return "Read \(snap?.bankCount ?? 0) slots."
        }) { [library] in library.setN2(snap) }
    }

    func selectBank(_ bank: Int) {
        run(n2Prompt, { tag, _ in
            try await tag.sendExpectingAck(N2Elite.selectBank(bank))
            return "Slot \(bank + 1) is active."
        }) { [library] in
            if var snap = library.meta.n2 {
                snap.activeBank = bank
                library.setN2(snap)
            }
        }
    }

    /// `uid` comes from the caller so the job itself stays deterministic.
    func randomizeSerial(bank: Int, uid: Data) {
        guard let keys = library.keys else { message = TagError.noKeys.localizedDescription; return }
        run(n2Prompt, { tag, session in
            try await TagJobs.n2Randomize(tag, session: session, bank: bank, uid: uid, keys: keys)
            return "Slot \(bank + 1) has a new serial."
        })
    }

    func saveBank(_ bank: Int) {
        var dump: Dump?
        run(n2Prompt, { tag, _ in
            dump = try await TagJobs.n2ReadBank(tag, bank: bank)
            return "Slot \(bank + 1) read."
        }) { [library] in
            guard let dump else { return }
            try library.save(dump, named: library.db?.info(dump.amiiboID)?.name ?? dump.amiiboIDHex)
            library.reload()
        }
    }

    func setBankCount(_ n: Int) {
        var snap: N2Snapshot?
        run(n2Prompt, { tag, session in
            try await tag.sendExpectingAck(N2Elite.setBankCount(n))
            snap = try await TagJobs.n2Scan(tag, session: session)
            return "N2 now cycles through \(n) slots."
        }) { [library] in library.setN2(snap) }
    }

    static func randomUID() -> Data {
        Data([0x04] + (0 ..< 6).map { _ in UInt8.random(in: 0 ... 255) })
    }

    private let n2Prompt = "Hold your N2 Elite to the top of your iPhone."

    private func run(_ prompt: String, _ job: @escaping TagReader.Job, then done: @escaping () throws -> Void = {}) {
        Task { @MainActor in
            do {
                try await reader.run(prompt: prompt, job)
                try done()
            } catch let e as NFCReaderError where e.code == .readerSessionInvalidationErrorUserCanceled {
                // The user closed the NFC sheet.
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
