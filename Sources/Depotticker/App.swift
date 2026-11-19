import SwiftUI
import UniformTypeIdentifiers

@main
enum Launcher {
    static func main() {
        #if os(macOS)
        // `Depotticker --mcp` runs the Model Context Protocol server instead of the app.
        if CommandLine.arguments.contains("--mcp") { MCPServer.runBlocking() }
        // `Depotticker --import file.csv` imports a CSV (own layout or a supported broker export).
        // `Depotticker --isins` looks up the ISIN of every position that has none.
        if CommandLine.arguments.contains("--isins") { CommandLineImport.resolveISINs() }
        // `Depotticker --export file.csv` writes every portfolio in the import layout.
        if let index = CommandLine.arguments.firstIndex(of: "--export") {
            CommandLineImport.export(to: CommandLine.arguments.dropFirst(index + 1).first)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--import") {
            CommandLineImport.run(Array(CommandLine.arguments.dropFirst(index + 1)))
        }
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
    @State private var pendingImport: [Portfolio]?
    @State private var importError: String?
    @State private var notice: String?

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
        .sheet(isPresented: $store.showSourceSettings) {
            SourceSettingsSheet()
                .environmentObject(store)
        }
        .sheet(item: $store.editor) { context in
            PositionEditor(context: context)
                .environmentObject(store)
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                      contentType: .commaSeparatedText, defaultFilename: exportName) { _ in
            exportDocument = nil
        }
        .fileImporter(isPresented: $store.showImporter,
                      allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            readImport(result)
        }
        .confirmationDialog(importTitle, isPresented: Binding(get: { pendingImport != nil },
                                                               set: { if !$0 { pendingImport = nil } }),
                            titleVisibility: .visible) {
            Button("Add or Update Positions") { finishImport(replacing: false) }
            Button("Add or Update, and Estimate Purchase Dates") { finishImport(replacing: false, estimate: true) }
            Button("Replace All Positions", role: .destructive) { finishImport(replacing: true) }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("Replacing removes every current portfolio first. A backup of the current state is kept either way. Estimating gives positions without a purchase date the most recent day their share traded at your average price.")
        }
        .alert("Purchase dates", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
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
                } else if store.portfolios.allSatisfy(\.positions.isEmpty) {
                    WelcomeView()
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
                Button("Import from CSV…", systemImage: "square.and.arrow.down") { store.showImporter = true }
                Button("Open Import Template", systemImage: "tablecells") { openTemplate() }
                Menu("Estimate Missing Purchase Dates", systemImage: "calendar.badge.clock") {
                    Button("One Purchase per Position") { estimateDates(.single) }
                    Button("Yearly Purchases over the Years") { estimateDates(.yearly) }
                }
                Button("Price Source…", systemImage: "antenna.radiowaves.left.and.right") { store.showSourceSettings = true }
                #if os(iOS)
                Toggle("Amounts in Widget", systemImage: "eye", isOn: $store.widgetShowsAmounts)
                #endif
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
            let imported = try CSVCodec.parse(CSVCodec.text(from: data))
            pendingImport = imported
            // With nothing there yet, the choice between adding and replacing means nothing: just import.
            if store.portfolios.allSatisfy(\.positions.isEmpty) { finishImport(replacing: false) }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func finishImport(replacing: Bool, estimate: Bool = false) {
        guard let imported = pendingImport else { return }
        pendingImport = nil
        store.apply(imported: imported, replacing: replacing)
        if estimate { estimateDates() }
    }

    private func estimateDates(_ style: PurchaseEstimator.Style = .single) {
        Task {
            let count = await store.estimatePurchaseDates(style: style)
            notice = count == 0
                ? "Every position with a known purchase price already has a purchase date."
                : "Estimated the purchases of \(count) position\(count == 1 ? "" : "s") from your average prices. Quantities and costs are unchanged. The entries are marked as estimated; correct them on the share's page where you know better."
        }
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

#if os(macOS)
/// `Depotticker --import <file.csv> [--estimate]`, or `Depotticker --import --estimate` to only estimate.
enum CommandLineImport {
    static func export(to path: String?) -> Never {
        guard let path else {
            print("Usage: Depotticker --export <file.csv>")
            exit(2)
        }
        let csv = CSVCodec.export(PortfolioRepository().load(), priceEUR: { _ in nil }, rateEUR: { _ in nil })
        do {
            try Data(csv.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            print("Exported to \(path)")
            exit(0)
        } catch {
            print("Export failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run(_ arguments: [String]) -> Never {
        // --estimate [single|yearly] [--portfolio NAME] [--before YYYY-MM-DD]
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let estimate = arguments.contains("--estimate")
        let style = value("--estimate").flatMap(PurchaseEstimator.Style.init) ?? .single
        let only = value("--portfolio")
        let before = value("--before").flatMap(Trade.dayFormatter.date(from:))
        let path = arguments.first { $0.lowercased().hasSuffix(".csv") || $0.lowercased().hasSuffix(".txt") }
        guard path != nil || estimate else {
            print("Usage: Depotticker --import <file.csv> [--estimate]")
            exit(2)
        }
        let repository = PortfolioRepository()
        MarketData.configure(directory: repository.directory)
        var portfolios = repository.load()
        repository.backup(portfolios)
        if let path {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let imported = try CSVCodec.parse(CSVCodec.text(from: data))
                let outcome = PortfolioMerge.merge(imported, into: portfolios, replacing: false)
                portfolios = outcome.portfolios
                let names = imported.map(\.name).joined(separator: ", ")
                print("Imported into \(names): \(outcome.added) added, \(outcome.updated) updated, \(outcome.kept) kept (have recorded purchases).")
            } catch {
                print("Import failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        guard estimate else {
            repository.save(portfolios)
            exit(0)
        }
        let start = portfolios
        Task.detached {
            let outcome = await PurchaseEstimator.fillMissingDates(in: start, style: style, portfolio: only, before: before)
            repository.save(outcome.portfolios)
            print("Estimated the purchase date of \(outcome.estimated) position(s).")
            exit(0)
        }
        dispatchMain()
    }

    /// Looks up missing ISINs in the public registers and saves them (a backup is kept).
    static func resolveISINs() -> Never {
        let repository = PortfolioRepository()
        var portfolios = repository.load()
        let meta = repository.loadMeta()
        repository.backup(portfolios)
        Task.detached {
            var seen = Set<String>()
            let open = portfolios.flatMap(\.positions).filter { ($0.isin ?? "").isEmpty && seen.insert($0.symbol).inserted }
            var missing: [String] = []
            for position in open {
                let name = meta[position.symbol]?.name ?? position.name
                guard let found = await Instruments.isin(for: position.symbol, names: [name, position.name]) else {
                    print("\(position.symbol): no ISIN found (\(name))")
                    missing.append(position.symbol)
                    continue
                }
                print("\(position.symbol): \(found.isin)  \(found.name)")
                for p in portfolios.indices {
                    for i in portfolios[p].positions.indices where portfolios[p].positions[i].symbol == position.symbol {
                        portfolios[p].positions[i].isin = found.isin
                    }
                }
                repository.save(portfolios)
            }
            print("\(open.count - missing.count) of \(open.count) found." + (missing.isEmpty ? "" : " Missing: \(missing.joined(separator: ", "))"))
            exit(0)
        }
        dispatchMain()
    }
}
#endif
