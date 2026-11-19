import Foundation
import SwiftUI
import WidgetKit

enum EditorContext: Identifiable {
    case add
    case edit(portfolioID: UUID, position: Position)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(_, let position): return position.id.uuidString
        }
    }
}

@MainActor
final class Store: ObservableObject {
    // Members without an access modifier below are internal so the Store+… files can use them;
    // the views go through the published properties and the functions in those files.
    static var refreshInterval: Duration { MarketData.source.refreshInterval }

    @Published var portfolios: [Portfolio] = [] {
        didSet { MarketData.register(portfolios: portfolios) }
    }
    @Published var quotes: [String: LiveQuote] = [:]
    @Published var meta: [String: SymbolMeta] = [:]
    /// EUR value of one unit of each currency.
    @Published var fx: [String: Double] = ["EUR": 1]
    /// The same rates at the previous close, so today's change includes the currency move.
    var fxPrevious: [String: Double] = ["EUR": 1]
    @Published var selectedPortfolioID: UUID?
    @Published var selectedSymbol: String?
    @Published var editor: EditorContext?
    /// Pushes the overview page on iPhone, where it is not permanently visible.
    @Published var showOverview = false
    /// Presents the price-source sheet. `--source-settings` opens it at launch (used when checking layouts).
    @Published var showSourceSettings = CommandLine.arguments.contains("--source-settings")
    /// Asks the window to show the file picker for an import (from the menu or the welcome).
    @Published var showImporter = false
    @Published var lastUpdate: Date?
    @Published var lastError: String?
    /// Set when the portfolio file could not be read at launch; stays until the app is restarted.
    @Published var dataProblem: String?
    /// Whether the widget may show money amounts; it shows percentages only otherwise.
    @Published var widgetShowsAmounts = false {
        didSet {
            WidgetSettings(showAmounts: widgetShowsAmounts).save(to: repository.directory)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    @Published var menuBarMode: MenuBarMode {
        didSet { UserDefaults.standard.set(menuBarMode.rawValue, forKey: "menuBarMode") }
    }
    /// Hide money amounts in the menu bar while a call or screen sharing is likely in progress.
    @Published var autoHideAmounts: Bool {
        didSet { UserDefaults.standard.set(autoHideAmounts, forKey: "autoHideAmounts") }
    }
    /// Keep this app's windows out of screen sharing and recordings.
    @Published var excludeFromCapture: Bool {
        didSet {
            UserDefaults.standard.set(excludeFromCapture, forKey: "excludeFromCapture")
            PrivacySignals.excludeWindowsFromCapture(excludeFromCapture)
        }
    }
    @Published private(set) var sharingDetected = false
    /// The chosen price source and API keys (see `MarketData`).
    @Published var sourceConfig = SourceConfig()
    /// Day of the exchange rates in use, when they are the ECB's daily reference rates.
    @Published private(set) var ratesDate: Date?
    /// Minutes the German-exchanges source still needs to read the rest of today's trade files. Until
    /// then a share that last traded earlier today still shows an older price.
    @Published private(set) var catchUpMinutes = 0
    /// Progress of the ISIN lookup (done, total) while it runs.
    @Published var isinProgress: (done: Int, total: Int)?
    /// Symbols whose ISIN the lookup could not find; they need it entered by hand.
    @Published var unresolvedISINs: [String] = []

    /// True when amounts should currently be masked (menu bar on the Mac, totals on iPhone and iPad).
    var amountsHidden: Bool { autoHideAmounts && sharingDetected }

    /// Value history per range and portfolio, keyed by `historyKey`.
    @Published var histories: [String: [ChartPoint]] = [:]

    var repository = PortfolioRepository()
    var refreshTask: Task<Void, Never>?
    var privacyTask: Task<Void, Never>?
    var cloudObserver: NSObjectProtocol?
    var metaInFlight: Set<String> = []
    var loadedStamp: Date?
    var seriesCache: [ChartRange: (fetched: Date, series: [String: PriceSeries])] = [:]
    var historyInFlight: Set<ChartRange> = []
    /// The symbols the cached price series were downloaded for.
    var seriesSymbols: Set<String> = []

    init() {
        let defaults = UserDefaults.standard
        menuBarMode = defaults.string(forKey: "menuBarMode").flatMap(MenuBarMode.init) ?? .percent
        autoHideAmounts = defaults.object(forKey: "autoHideAmounts") as? Bool ?? true
        excludeFromCapture = defaults.object(forKey: "excludeFromCapture") as? Bool ?? true
        let loaded = repository.loadChecked()
        portfolios = loaded.portfolios
        dataProblem = loaded.problem?.message
        widgetShowsAmounts = WidgetSettings.load(from: repository.directory).showAmounts
        if !MarketData.configure(directory: repository.directory), ProcessInfo.processInfo.environment["DEPOTTICKER_SOURCE"] == nil {
            // First start: the direct download starts with Yahoo, which needs no key and covers every
            // exchange, so an imported file shows prices at once. The App Store build has no keyless
            // source that covers everything, so there the user chooses.
            var initial = SourceConfig()
            if DataSource.available.contains(.yahoo) { initial.source = .yahoo }
            initial.save(to: repository.directory)
            MarketData.config = initial
        }
        sourceConfig = MarketData.config
        loadSavedHistories()
        loadedStamp = repository.stamp()
        meta = repository.loadMeta()
        startCloudSync()
        // Launch arguments used when checking layouts in the simulator.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--select"), index + 1 < arguments.count {
            selectedSymbol = arguments[index + 1]
        }
        if arguments.contains("--overview") { showOverview = true }
        privacyTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    let detected = PrivacySignals.isLikelySharing
                    if detected != self.sharingDetected { self.sharingDetected = detected }
                    if !Snapshot.isRequested { PrivacySignals.excludeWindowsFromCapture(self.excludeFromCapture) }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            // Preload every period once, then keep the intraday chart current.
            Task { [weak self] in await self?.preloadHistories() }
            while !Task.isCancelled {
                try? await Task.sleep(for: Store.refreshInterval)
                await self?.refresh()
                await self?.loadHistory(.day)
            }
        }
    }

    // MARK: Persistence

    func save() {
        if !repository.save(portfolios) {
            dataProblem = "Your portfolios have outgrown iCloud's 1 MB limit and are no longer synced. They are safe on this device."
        }
        loadedStamp = repository.stamp()
        WidgetCenter.shared.reloadAllTimelines()
        invalidateHistories()
    }

    /// Picks up edits written by the MCP server.
    func reloadIfChangedElsewhere() {
        guard let stamp = repository.stamp(), stamp != loadedStamp else { return }
        loadedStamp = stamp
        let fresh = repository.load()
        guard fresh != portfolios else { return }
        portfolios = fresh
        WidgetCenter.shared.reloadAllTimelines()
        invalidateHistories()
    }

    func saveMeta() {
        repository.saveMeta(meta)
    }

    // MARK: Live data

    var allSymbols: [String] {
        var seen = Set<String>()
        return portfolios.flatMap(\.positions).map(\.symbol).filter { seen.insert($0).inserted }
    }

    func refresh() async {
        reloadIfChangedElsewhere()
        let symbols = allSymbols
        guard !symbols.isEmpty else {
            lastError = MarketData.source == .none ? MarketDataError.noSource.localizedDescription : nil
            return
        }
        await loadMissingMeta(for: symbols)

        // Listing currencies plus the currencies positions were bought in.
        let currencies = Set(symbols.compactMap { meta[$0]?.currency })
            .union(portfolios.flatMap(\.positions).map(\.currency)).subtracting(["EUR"])
        async let rates = MarketData.rates(currencies)
        var merged: [String: LiveQuote] = [:]
        var failure: String?
        do { merged = try await MarketData.quotes(symbols) } catch { failure = error.localizedDescription }

        for (currency, rate) in await rates {
            fx[currency] = rate.now
            fxPrevious[currency] = rate.previous
        }
        ratesDate = MarketData.source == .yahoo ? nil : await ECB.latestDate()
        // A share that moved between the exchanges and the gap-filling source is now quoted in another
        // currency: its cached facts are replaced before its new price is shown.
        let supplemented = MarketData.supplemented
        let moved = supplemented.symmetricDifference(supplementedSeen)
        supplementedSeen = supplemented
        let stale = moved.filter { symbol in
            guard let known = meta[symbol] else { return false }
            return (known.exchange == "Xetra" || known.exchange == "Frankfurt" || known.exchange == "Tradegate")
                == supplemented.contains(symbol)
        }
        if !stale.isEmpty {
            for symbol in stale {
                meta[symbol] = nil
                quotes[symbol] = nil
            }
            await loadMissingMeta(for: symbols)
        }
        for symbol in symbols where meta[symbol] != nil || !stale.contains(symbol) {
            if let quote = merged[symbol] { quotes[symbol] = quote }
        }
        lastError = failure
        let backlog = MarketData.source == .boerse ? await DeutscheBoerse.backlog() : 0
        catchUpMinutes = (backlog + DeutscheBoerse.requestsPerRound - 1) / DeutscheBoerse.requestsPerRound
        if !merged.isEmpty {
            lastUpdate = Date()
            MarketData.cache(quotes: merged)
        }
    }

    var supplementedSeen: Set<String> = []

    func loadMissingMeta(for symbols: [String]) async {
        let missing = symbols.filter { meta[$0] == nil && !metaInFlight.contains($0) }
        guard !missing.isEmpty else { return }
        metaInFlight.formUnion(missing)
        for (symbol, fresh) in await MarketData.each(missing, limit: 4, { try? await MarketData.chart($0, range: .day).meta }) {
            meta[symbol] = fresh
        }
        metaInFlight.subtract(missing)
        saveMeta()
    }

    /// Called by the detail view when it has fresher statistics for a symbol.
    func update(meta fresh: SymbolMeta) {
        var merged = fresh
        if let old = meta[fresh.symbol] {
            merged.open = fresh.open ?? old.open
            // A source that could not name the listing must not wipe a name already known.
            if fresh.name == fresh.symbol {
                merged.name = old.name
                if !old.exchange.isEmpty { merged.exchange = old.exchange }
            }
            merged.previousClose = fresh.previousClose ?? old.previousClose
        }
        guard meta[fresh.symbol] != merged else { return }
        meta[fresh.symbol] = merged
        saveMeta()
    }

}
