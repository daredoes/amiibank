import AmiiboKit
import SwiftUI

struct N2View: View {
    @Environment(Library.self) private var library
    @Environment(Actions.self) private var actions
    @State private var adding = false
    @State private var replacing: Int?
    @State private var countSheet = false
    @State private var newCount = 1

    private var snap: N2Snapshot? { library.meta.n2 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 20) {
                        Button { actions.scanN2() } label: {
                            Image(systemName: "dot.radiowaves.left.and.right").font(.title)
                                .frame(width: 72, height: 72).background(Theme.card, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Scan N2")
                        CountHeader(count: snap?.filled ?? 0, total: N2Elite.maxBanks, caption: "\(N2Elite.maxBanks) slots")
                    }
                    if let snap {
                        activeCard(snap)
                        slots(snap)
                    } else {
                        ContentUnavailableView("No N2 scanned yet", systemImage: "dot.radiowaves.left.and.right",
                                               description: Text("Tap the antenna, then hold the N2 to the top of your iPhone."))
                    }
                }
                .padding()
            }
            .navigationTitle("N2 Elite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Slots") { newCount = snap?.bankCount ?? 1; countSheet = true }.disabled(snap == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $adding) { CollectionPicker(title: "Add to N2") { actions.addToN2($0) } }
            .sheet(item: Binding { replacing.map(Slot.init) } set: { replacing = $0?.id }) { slot in
                CollectionPicker(title: "Replace slot \(slot.id + 1)") { actions.writeBank($0, bank: slot.id) }
            }
            .sheet(isPresented: $countSheet) { countEditor }
        }
    }

    private struct Slot: Identifiable { let id: Int }

    private func activeCard(_ snap: N2Snapshot) -> some View {
        let id = snap.activeBank < snap.banks.count ? snap.banks[snap.activeBank] : nil
        let info = id.flatMap { library.db?.info($0) }
        return HStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("ACTIVE AMIIBO").font(.caption.bold()).foregroundStyle(.secondary)
                Text("SLOT \(snap.activeBank + 1)").font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 4).background(.white.opacity(0.15), in: .capsule)
                Text(info?.name ?? (id == nil ? "Empty" : "Unknown")).font(.title2.weight(.semibold))
                if let info { Text(info.amiiboSeries).foregroundStyle(.secondary) }
            }
            Spacer()
            AmiiboArt(url: info?.imageURL, size: 110)
        }
        .padding()
        .background(Theme.accent.opacity(0.25), in: .rect(cornerRadius: 12))
    }

    private func slots(_ snap: N2Snapshot) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: 4), spacing: 24) {
            ForEach(Array(snap.banks.enumerated()), id: \.offset) { index, id in
                let info = id.flatMap { library.db?.info($0) }
                AmiiboTile(name: id == nil ? "Empty" : (info?.name ?? "Unknown"), url: info?.imageURL, badge: "\(index + 1)", dimmed: id == nil)
                    .contextMenu { menu(index, filled: id != nil) }
            }
        }
    }

    @ViewBuilder
    private func menu(_ bank: Int, filled: Bool) -> some View {
        Button("Make active", systemImage: "star") { actions.selectBank(bank) }
        Button(filled ? "Replace…" : "Write…", systemImage: "arrow.triangle.2.circlepath") { replacing = bank }
        if filled {
            Button("Save to collection", systemImage: "square.and.arrow.down") { actions.saveBank(bank) }
            if library.keys != nil {
                Button("Randomize serial", systemImage: "shuffle") { actions.randomizeSerial(bank: bank, uid: Actions.randomUID()) }
            }
        }
    }

    private var countEditor: some View {
        VStack(spacing: 20) {
            Text("Active slots").font(.title2.weight(.semibold)).padding(.top, 24)
            Text("The N2 button cycles through this many slots.").foregroundStyle(.secondary)
            Stepper("\(newCount) slots", value: $newCount, in: 1 ... N2Elite.maxBanks).padding(.horizontal)
            SheetButtons(clear: { countSheet = false }, save: { countSheet = false; actions.setBankCount(newCount) })
        }
        .padding()
        .presentationDetents([.medium])
    }
}
