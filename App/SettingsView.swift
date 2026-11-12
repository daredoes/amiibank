import SwiftUI

struct SettingsView: View {
    enum Page: String, CaseIterable { case faq = "FAQ", settings = "Settings", about = "About" }

    @State private var page = Page.settings

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Page", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding()
                switch page {
                case .faq: FAQView()
                case .settings: PreferencesView()
                case .about: AboutView()
                }
            }
            .navigationTitle(page.rawValue)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct PreferencesView: View {
    @Environment(Library.self) private var library
    @Environment(Actions.self) private var actions
    @Environment(GameCenterSync.self) private var gameCenter
    @State private var importingKey = false
    @State private var reloading = false
    @State private var backup: URL?

    var body: some View {
        Form {
            Section {
                Toggle("Use write counter", isOn: Binding { library.meta.useWriteCounter } set: { library.setUseWriteCounter($0) })
                Button("Reset all write counters", role: .destructive) { library.resetWrites() }
            } footer: {
                Text("Each write to a tag or N2 slot adds one to that amiibo's counter, shown on its tile.")
            }
            Section {
                switch gameCenter.state {
                case .ready:
                    Button("Back up to Game Center") { gc { "Saved \(try await gameCenter.backUp(library)) amiibo to Game Center." } }
                    Button("Restore from Game Center") { gc { "Restored. \(try await gameCenter.restore(into: library)) new amiibo." } }
                case .signingIn:
                    Text("Signing in to Game Center…").foregroundStyle(.secondary)
                case .signedOut, .failed:
                    Button("Sign in to Game Center") { gameCenter.signIn() }
                }
            } header: {
                Text("Game Center")
            } footer: {
                switch gameCenter.state {
                case .failed: Text("Game Center isn't signed in on this iPhone. Sign in under Settings › Game Center, then come back to back up your collection.")
                default:
                    Text(gameCenter.lastSave.map { "Last saved \($0.formatted(.relative(presentation: .named)))." } ?? "Saves your collection, write counters and favorites to your Game Center account. Restore adds missing amiibo; it never deletes. Your key file is not included.")
                }
            }
            .disabled(gameCenter.busy)
            Section {
                LabeledContent("Key file", value: library.keys == nil ? "Not imported" : "Loaded")
                Button("Import key_retail.bin") { importingKey = true }
            } footer: {
                Text("Needed to write blank tags and randomize N2 serials. It stays on this iPhone.")
            }
            Section {
                Button {
                    do { backup = try library.exportBackup() } catch { actions.message = error.localizedDescription }
                } label: { Text("Export collection backup") }
                if let backup { ShareLink("Share \(backup.lastPathComponent)", item: backup) }
                Button(reloading ? "Reloading…" : "Reload amiibo data") { reload() }.disabled(reloading)
            } footer: {
                Text("\(library.db?.amiibo.count ?? 0) amiibo and \(library.db?.games.count ?? 0) games in the catalog. Reload fetches the latest from AmiiboAPI.")
            }
        }
        .fileImporter(isPresented: $importingKey, allowedContentTypes: [.data]) { result in
            do { try library.importKey(from: result.get()); actions.message = "Key loaded." }
            catch { actions.message = "That isn't a valid key file." }
        }
    }

    private func gc(_ work: @escaping () async throws -> String) {
        Task {
            do { actions.message = try await work() } catch { actions.message = "Game Center: \(error.localizedDescription)" }
        }
    }

    private func reload() {
        reloading = true
        Task {
            do { try await library.reloadDatabase(); actions.message = "Amiibo data updated." }
            catch { actions.message = "Couldn't update: \(error.localizedDescription)" }
            reloading = false
        }
    }
}

private struct FAQView: View {
    private let entries: [(String, String)] = [
        ("How do I enable writing?",
         "Import your own key_retail.bin in Settings. Amiibank never ships or downloads keys. With a key loaded you can write blank NTAG215 tags and randomize N2 serials."),
        ("How do I import many files at once?",
         "Tap + on the Collection tab, then choose Select in the file picker and pick as many .bin files as you like. A combined backup (one file with many amiibo) also works. Google Drive and other services show up once you enable them in the Files app under Browse, then the ... menu, then Edit."),
        ("Can I rewrite a blank tag?",
         "No. An NTAG215 locks after it's written, so each tag holds one amiibo for good. Use an N2 slot when you want to swap amiibo."),
        ("What does Randomize serial do?",
         "It gives the amiibo in an N2 slot a new serial, so games that limit one use per amiibo per day treat it as a different figure. Only the N2 copy changes; your library file stays as it was."),
        ("How do write counters work?",
         "Each write to a tag or N2 slot adds one. Long-press an amiibo and choose Update number of writes to change it, or reset all counters in Settings."),
        ("How do I clear my collection?",
         "Delete amiibo with a long press, or remove files from On My iPhone › Amiibank › Library in the Files app."),
        ("Which iPhones work?",
         "Any iPhone that can read NFC tags in apps (iPhone 7 and later). Hold the tag at the top back of the phone and keep it still until the sheet says Done."),
        ("Does Amiibank send my data anywhere?",
         "No. Your library, keys and counters stay on this iPhone. The app only goes online to fetch amiibo pictures and, when you ask, the latest catalog from AmiiboAPI."),
    ]

    var body: some View {
        List(entries, id: \.0) { q, a in
            VStack(alignment: .leading, spacing: 8) {
                Text(q).font(.headline)
                Text(a).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct AboutView: View {
    var body: some View {
        List {
            Section {
                Text("Amiibank is free and open source under the MIT license. Not affiliated with Nintendo.")
            }
            Section("Built on") {
                Link("amiitool: amiibo crypto (MIT)", destination: URL(string: "https://github.com/socram8888/amiitool")!)
                Link("AmiiboAPI: catalog and pictures (MIT)", destination: URL(string: "https://github.com/N3evin/AmiiboAPI")!)
                Link("YobiWiki: N2 Elite protocol notes", destination: URL(string: "https://wiki.yobi.be/index.php/N2_Elite")!)
            }
        }
    }
}
