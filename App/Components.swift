import AmiiboKit
import SwiftUI

struct AmiiboArt: View {
    let url: URL?
    var size: CGFloat = 80

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "questionmark.square.dashed").font(.title).foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
    }
}

/// Grid cell: art, name, and an optional count badge in the corner.
struct AmiiboTile: View {
    let name: String
    let url: URL?
    var badge: String?
    var dimmed = false

    var body: some View {
        VStack(spacing: 6) {
            AmiiboArt(url: url)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge).font(.caption2.bold()).padding(5)
                            .background(Theme.card, in: .circle)
                            .offset(x: 8, y: -8)
                    }
                }
            Text(name).font(.subheadline).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .opacity(dimmed ? 0.35 : 1)
    }
}

/// "853 amiibo" over a bar out of a total, like a fill gauge.
struct CountHeader: View {
    let count: Int
    let total: Int
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(count) amiibo").font(.largeTitle.weight(.semibold))
            ProgressView(value: Double(min(count, total)), total: Double(max(total, 1)))
            Text(caption).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// Wheel picker in a sheet with Clear and Save, used for the collection filters.
struct FilterSheet: View {
    let title: String
    let options: [String]
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(.title2.weight(.semibold)).padding(.top, 24)
            Picker(title, selection: $draft) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.wheel)
            SheetButtons(clear: { selection = nil; dismiss() }, save: { selection = draft; dismiss() })
        }
        .padding()
        .presentationDetents([.medium])
        .onAppear { draft = selection ?? options.first ?? "" }
    }
}

struct SheetButtons: View {
    let clear: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: clear) { Text("CLEAR").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
            Button(action: save) { Text("SAVE").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .fontWeight(.semibold)
    }
}

/// Searchable grid of the collection for choosing what to write somewhere.
struct CollectionPicker: View {
    let title: String
    let pick: (Amiibo) -> Void
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 20) {
                    ForEach(library.items.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { a in
                        Button { dismiss(); pick(a) } label: {
                            AmiiboTile(name: a.name, url: a.info?.imageURL, badge: library.badge(a.dump.amiiboID))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .searchable(text: $search)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

extension Library {
    /// Write count shown on tiles when the counter is on and non-zero.
    func badge(_ id: UInt64) -> String? {
        let n = writes(id)
        return meta.useWriteCounter && n > 0 ? "\(n)" : nil
    }
}
