import SwiftUI
import UniformTypeIdentifiers

@main
enum Launcher {
    static func main() {
        #if os(macOS)
        // `Depotticker --mcp` runs the Model Context Protocol server instead of the app.
        if CommandLine.arguments.contains("--mcp") { MCPServer.runBlocking() }
        #endif
        DepottickerApp.main()
    }
}

struct DepottickerApp: App {
    @StateObject private var store = Store()
    #if canImport(Sparkle)
    @StateObject private var updater = Updater()
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("Depotticker", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 940, minHeight: 600)
                #if canImport(Sparkle)
                .task { await Snapshot.runIfRequested(store: store) }
                #endif
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Position…") { store.editor = .add }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Quotes") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                Button("Show Overview") { store.selectedSymbol = nil }
                    .keyboardShortcut("0")
            }
            CommandGroup(replacing: .help) {
                Link("Depotticker Help", destination: Links.help)
            }
            #if canImport(Sparkle)
            CheckForUpdatesCommand(updater: updater)
            #endif
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        #endif
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL

    @State private var exportDocument: CSVDocument?
    @State private var exportName = "Depotticker"
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingImport: [Portfolio]?
    @State private var importError: String?

    private var isPhone: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    private var ambientTrend: Double? {
        store.selectedSymbol.flatMap { store.dayPct($0) } ?? store.visibleTotals.day
    }

    var body: some View {
        Group {
            if isPhone { phoneLayout } else { splitLayout }
        }
        .sheet(item: $store.editor) { context in
            PositionEditor(context: context)
                .environmentObject(store)
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                      contentType: .commaSeparatedText, defaultFilename: exportName) { _ in
            exportDocument = nil
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            readImport(result)
        }
        .confirmationDialog(importTitle, isPresented: Binding(get: { pendingImport != nil },
                                                               set: { if !$0 { pendingImport = nil } }),
                            titleVisibility: .visible) {
            Button("Add to Existing Positions") { finishImport(replacing: false) }
            Button("Replace All Positions", role: .destructive) { finishImport(replacing: true) }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("Replacing removes every current portfolio first. A backup of the current state is kept either way.")
        }
        .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: Layouts

    private var splitLayout: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 310, ideal: 350, max: 440)
        } detail: {
            Group {
                if let symbol = store.selectedSymbol, let holding = store.holding(symbol) {
                    DetailView(holding: holding)
                        .id(symbol)
                } else {
                    OverviewView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AmbientBackground(trend: ambientTrend) }
            .toolbar { toolbarItems(showOverviewButton: true) }
        }
    }

    private var phoneLayout: some View {
        NavigationStack {
            SidebarView()
                .navigationTitle("Depotticker")
                .toolbar { toolbarItems(showOverviewButton: false) }
                .navigationDestination(isPresented: $store.showOverview) {
                    OverviewView()
                        .background { AmbientBackground(trend: store.visibleTotals.day) }
                        .navigationTitle("Overview")
                }
                .navigationDestination(item: $store.selectedSymbol) { symbol in
                    if let holding = store.holding(symbol) {
                        DetailView(holding: holding)
                            .background { AmbientBackground(trend: store.dayPct(symbol)) }
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private func toolbarItems(showOverviewButton: Bool) -> some ToolbarContent {
        if showOverviewButton {
            ToolbarItem(placement: .navigation) {
                Button {
                    store.selectedSymbol = nil
                } label: {
                    Label("Overview", systemImage: "square.grid.2x2")
                }
                .help("Portfolio overview")
                .disabled(store.selectedSymbol == nil)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Export as CSV…", systemImage: "square.and.arrow.up") {
                    exportName = "Depotticker \(Date().formatted(.iso8601.year().month().day()))"
                    exportDocument = CSVDocument(text: store.exportCSV())
                    showExporter = true
                }
                Button("Import from CSV…", systemImage: "square.and.arrow.down") { showImporter = true }
                Button("Open Import Template", systemImage: "tablecells") { openTemplate() }
                Divider()
                Button("Help", systemImage: "questionmark.circle") {
                    openURL(Links.help)
                }
            } label: {
                Label("Import and Export", systemImage: "arrow.up.arrow.down.square")
            }
            .help("Import, export and help")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.editor = .add
            } label: {
                Label("Add Position", systemImage: "plus")
            }
            .help("Add a position")
        }
    }

    // MARK: Import and export

    private var importTitle: String {
        let count = pendingImport?.reduce(0) { $0 + $1.positions.count } ?? 0
        return "Import \(count) position\(count == 1 ? "" : "s")?"
    }

    private func readImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            // Excel on Windows saves CSV as Latin-1 rather than UTF-8.
            let text = String(data: data, encoding: .utf8) ?? (String(data: data, encoding: .isoLatin1) ?? "")
            pendingImport = try CSVCodec.parse(text)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func finishImport(replacing: Bool) {
        guard let imported = pendingImport else { return }
        pendingImport = nil
        store.apply(imported: imported, replacing: replacing)
    }

    /// On the Mac the template opens straight in Excel or Numbers; elsewhere it is saved first.
    private func openTemplate() {
        #if os(macOS)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Depotticker Template.csv")
        do {
            try Data(CSVCodec.template.utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            importError = error.localizedDescription
        }
        #else
        exportName = "Depotticker Template"
        exportDocument = CSVDocument(text: CSVCodec.template)
        showExporter = true
        #endif
    }
}
