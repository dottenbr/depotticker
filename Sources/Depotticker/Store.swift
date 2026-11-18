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
    static var refreshInterval: Duration { MarketData.source.refreshInterval }

    @Published var portfolios: [Portfolio] = []
    @Published var quotes: [String: LiveQuote] = [:]
    @Published var meta: [String: SymbolMeta] = [:]
    /// EUR value of one unit of each currency.
    @Published var fx: [String: Double] = ["EUR": 1]
    /// The same rates at the previous close, so today's change includes the currency move.
    private var fxPrevious: [String: Double] = ["EUR": 1]
    @Published var selectedPortfolioID: UUID?
    @Published var selectedSymbol: String?
    @Published var editor: EditorContext?
    /// Pushes the overview page on iPhone, where it is not permanently visible.
    @Published var showOverview = false
    /// Presents the price-source sheet. `--source-settings` opens it at launch (used when checking layouts).
    @Published var showSourceSettings = CommandLine.arguments.contains("--source-settings")
    @Published var lastUpdate: Date?
    @Published var lastError: String?
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
    @Published private(set) var sourceConfig = SourceConfig()
    /// Day of the exchange rates in use, when they are the ECB's daily reference rates.
    @Published private(set) var ratesDate: Date?

    /// True when amounts should currently be masked (menu bar on the Mac, totals on iPhone and iPad).
    var amountsHidden: Bool { autoHideAmounts && sharingDetected }

    /// Value history per range and portfolio, keyed by `historyKey`.
    @Published private(set) var histories: [String: [ChartPoint]] = [:]

    private var repository = PortfolioRepository()
    private var refreshTask: Task<Void, Never>?
    private var privacyTask: Task<Void, Never>?
    private var cloudObserver: NSObjectProtocol?
    private var metaInFlight: Set<String> = []
    private var loadedStamp: Date?
    private var seriesCache: [ChartRange: (fetched: Date, series: [String: PriceSeries])] = [:]
    private var historyInFlight: Set<ChartRange> = []

    init() {
        let defaults = UserDefaults.standard
        menuBarMode = defaults.string(forKey: "menuBarMode").flatMap(MenuBarMode.init) ?? .percent
        autoHideAmounts = defaults.object(forKey: "autoHideAmounts") as? Bool ?? true
        excludeFromCapture = defaults.object(forKey: "excludeFromCapture") as? Bool ?? true
        portfolios = repository.load()
        if !MarketData.configure(directory: repository.directory), ProcessInfo.processInfo.environment["DEPOTTICKER_SOURCE"] == nil {
            // First start of a version with selectable sources: installs that already hold positions keep
            // the source they have been using; new installs start without one.
            var initial = SourceConfig()
            if !portfolios.isEmpty, DataSource.available.contains(.yahoo) { initial.source = .yahoo }
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

    private func save() {
        repository.save(portfolios)
        loadedStamp = repository.stamp()
        WidgetCenter.shared.reloadAllTimelines()
        invalidateHistories()
    }

    /// Picks up edits written by the MCP server.
    private func reloadIfChangedElsewhere() {
        guard let stamp = repository.stamp(), stamp != loadedStamp else { return }
        loadedStamp = stamp
        let fresh = repository.load()
        guard fresh != portfolios else { return }
        portfolios = fresh
        WidgetCenter.shared.reloadAllTimelines()
        invalidateHistories()
    }

    /// App Store builds share the portfolios between Mac, iPhone and iPad through iCloud.
    private func startCloudSync() {
        guard PortfolioRepository.usesCloudStore else { return }
        let cloud = NSUbiquitousKeyValueStore.default
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.adoptCloudCopy() }
        }
        cloud.synchronize()
        adoptCloudCopy()
    }

    private func adoptCloudCopy() {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: PortfolioRepository.cloudKey),
              let fresh = PortfolioRepository.decode(data)
        else {
            // Nothing in iCloud yet: publish what this device has.
            if !portfolios.isEmpty { repository.save(portfolios) }
            return
        }
        guard fresh != portfolios else { return }
        portfolios = fresh
        repository.save(fresh)
        loadedStamp = repository.stamp()
        WidgetCenter.shared.reloadAllTimelines()
        invalidateHistories()
        Task { await refresh() }
    }

    private func saveMeta() {
        repository.saveMeta(meta)
    }

    // MARK: Price source

    /// Switches the price source or stores an API key, then reloads everything from the new source.
    func setSource(_ source: DataSource, key: String? = nil) {
        var config = sourceConfig
        config.source = source
        if let key { config.keys[source.rawValue] = key.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard config != sourceConfig else { return }
        config.save(to: repository.directory)
        MarketData.config = config
        sourceConfig = config
        quotes.removeAll()
        lastError = nil
        WidgetCenter.shared.reloadAllTimelines()
        invalidateHistories()
        Task { await refresh() }
    }

    // MARK: Import and export

    func exportCSV() -> String {
        CSVCodec.export(portfolios, priceEUR: { [self] in priceEUR($0) }, rateEUR: { [self] in fx[$0] })
    }

    /// Applies imported portfolios. Positions go into the portfolio with the same name; `replacing`
    /// drops everything first (the previous state is kept as a backup file).
    func apply(imported: [Portfolio], replacing: Bool) {
        repository.backup(portfolios)
        portfolios = PortfolioMerge.merge(imported, into: portfolios, replacing: replacing).portfolios
        if let selected = selectedPortfolioID, !portfolios.contains(where: { $0.id == selected }) {
            selectedPortfolioID = nil
        }
        save()
        Task { await refresh() }
    }

    /// Adds an estimated purchase date to every position that has a cost but no date. Returns how many.
    @discardableResult
    func estimatePurchaseDates(style: PurchaseEstimator.Style = .single) async -> Int {
        let outcome = await PurchaseEstimator.fillMissingDates(in: portfolios, style: style)
        guard outcome.estimated > 0 else { return 0 }
        repository.backup(portfolios)
        // Keep edits made while the estimate was running.
        for portfolio in outcome.portfolios {
            guard let p = portfolios.firstIndex(where: { $0.id == portfolio.id }) else { continue }
            for position in portfolio.positions where !position.trades.isEmpty {
                if let i = portfolios[p].positions.firstIndex(where: { $0.id == position.id }),
                   portfolios[p].positions[i].needsPurchaseDate {
                    portfolios[p].positions[i] = position
                }
            }
        }
        save()
        return outcome.estimated
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
        for symbol in symbols {
            if let quote = merged[symbol] { quotes[symbol] = quote }
        }
        lastError = failure
        if !merged.isEmpty { lastUpdate = Date() }
    }

    private func loadMissingMeta(for symbols: [String]) async {
        let missing = symbols.filter { meta[$0] == nil && !metaInFlight.contains($0) }
        guard !missing.isEmpty else { return }
        metaInFlight.formUnion(missing)
        var iterator = missing.makeIterator()
        await withTaskGroup(of: SymbolMeta?.self) { group in
            func addNext() {
                guard let symbol = iterator.next() else { return }
                group.addTask { try? await MarketData.chart(symbol, range: .day).meta }
            }
            for _ in 0..<4 { addNext() }
            for await result in group {
                if let result { meta[result.symbol] = result }
                addNext()
            }
        }
        metaInFlight.subtract(missing)
        saveMeta()
    }

    // MARK: Portfolio history

    static let historyRanges: [ChartRange] = [.day, .week, .month, .quarter, .half, .ytd, .year, .fiveYears]

    func historyKey(_ range: ChartRange, _ portfolioID: UUID?) -> String {
        "\(range.rawValue)|\(portfolioID?.uuidString ?? "all")"
    }

    /// How long a downloaded range stays fresh: intraday ranges move, daily ones barely do.
    private func lifetime(_ range: ChartRange) -> TimeInterval {
        switch range {
        case .day: return MarketData.source.intradayLifetime
        case .week: return 600
        case .month: return 1_800
        default: return 6 * 3_600
        }
    }

    /// Downloads one range for all symbols (three small requests) and recomputes the value history of
    /// every portfolio from it, as if today's holdings had been held for the whole period.
    func loadHistory(_ range: ChartRange, force: Bool = false) async {
        let symbols = allSymbols
        guard !symbols.isEmpty, !historyInFlight.contains(range) else { return }
        if !force, let cached = seriesCache[range], Date().timeIntervalSince(cached.fetched) < lifetime(range),
           histories[historyKey(range, selectedPortfolioID)] != nil {
            return
        }
        historyInFlight.insert(range)
        defer { historyInFlight.remove(range) }
        if fx.count < 2 || meta.isEmpty { await refresh() }

        let series = await MarketData.series(symbols, range: range)
        guard series.count * 2 >= symbols.count else { return }
        seriesCache[range] = (Date(), series)
        recomputeHistories(for: range)
        saveHistories()
    }

    private func recomputeHistories(for range: ChartRange) {
        guard let series = seriesCache[range]?.series else { return }
        let filters: [UUID?] = [nil] + portfolios.map { Optional($0.id) }
        for filter in filters {
            var inputs: [PortfolioHistory.Series] = []
            for holding in holdings(in: filter) {
                guard let data = series[holding.symbol], let m = meta[holding.symbol], let rate = fx[m.currency] else { continue }
                let factor = holding.quantity * rate * m.scale
                inputs.append(.init(factor: factor, points: data.points,
                                    lead: range == .day ? data.previousClose : nil))
            }
            histories[historyKey(range, filter)] = PortfolioHistory.combine(inputs, range: range)
        }
    }

    /// Loads every range in the background so switching periods is instant.
    func preloadHistories(force: Bool = false) async {
        for range in Store.historyRanges {
            await loadHistory(range, force: force)
        }
    }

    private var historiesURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Depotticker-histories.json")
    }

    private func saveHistories() {
        try? JSONEncoder().encode(histories).write(to: historiesURL, options: .atomic)
    }

    private func loadSavedHistories() {
        guard let data = try? Data(contentsOf: historiesURL),
              let saved = try? JSONDecoder().decode([String: [ChartPoint]].self, from: data)
        else { return }
        histories = saved
    }

    /// Holdings changed: the cached histories no longer match.
    private func invalidateHistories() {
        seriesCache.removeAll()
        histories.removeAll()
        Task { await preloadHistories(force: true) }
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

    // MARK: Derived values (all in EUR)

    private func rate(_ symbol: String) -> Double? {
        guard let m = meta[symbol], let fxRate = fx[m.currency] else { return nil }
        return fxRate * m.scale
    }

    func priceEUR(_ symbol: String) -> Double? {
        guard let quote = quotes[symbol], let rate = rate(symbol) else { return nil }
        return quote.price * rate
    }

    /// Price in the listing's own currency.
    func nativePrice(_ symbol: String) -> Double? {
        guard let quote = quotes[symbol], let m = meta[symbol] else { return nil }
        return quote.price * m.scale
    }

    func dayPct(_ symbol: String) -> Double? { quotes[symbol]?.changePct }

    func value(_ holding: Holding) -> Double? {
        priceEUR(holding.symbol).map { $0 * holding.quantity }
    }

    /// Today's change in EUR: value now minus value at the previous close, each at its own exchange rate.
    func dayChange(_ holding: Holding) -> Double? {
        guard let quote = quotes[holding.symbol], let m = meta[holding.symbol],
              let rate = fx[m.currency], let previousRate = fxPrevious[m.currency] ?? fx[m.currency]
        else { return nil }
        return (quote.price * rate - quote.previousClose * previousRate) * m.scale * holding.quantity
    }

    /// Pre-market or after-hours price in the listing's currency, if any.
    func extendedPrice(_ symbol: String) -> Double? {
        guard let extended = quotes[symbol]?.extendedPrice, let m = meta[symbol] else { return nil }
        return extended * m.scale
    }

    /// Amount paid in EUR at today's exchange rates, over the lots whose purchase price is known.
    func cost(_ holding: Holding) -> Double? {
        var total = 0.0
        var known = false
        for lot in holding.lots where !lot.position.costUnknown {
            guard let rate = fx[lot.position.currency] else { return nil }
            total += lot.position.cost * rate
            known = true
        }
        return known ? total : nil
    }

    /// Average purchase price per share in EUR.
    func unitCost(_ holding: Holding) -> Double? {
        guard let cost = cost(holding), holding.costedQuantity > 0 else { return nil }
        return cost / holding.costedQuantity
    }

    /// Value minus cost of the shares whose purchase price is known. Bought in a foreign currency,
    /// this is the broker's own gain converted at today's rate.
    func gain(_ holding: Holding) -> Double? {
        guard let price = priceEUR(holding.symbol), let cost = cost(holding) else { return nil }
        return price * holding.costedQuantity - cost
    }

    func gainPct(_ holding: Holding) -> Double? {
        guard let gain = gain(holding), let cost = cost(holding), cost > 0 else { return nil }
        return gain / cost * 100
    }

    /// Profit already taken through recorded sales, in EUR at today's exchange rates.
    func realized(_ holding: Holding) -> Double {
        holding.lots.reduce(0) { $0 + $1.position.realized * (fx[$1.position.currency] ?? 0) }
    }

    func holdings(in portfolioID: UUID?) -> [Holding] {
        var order: [String] = []
        var bySymbol: [String: Holding] = [:]
        for portfolio in portfolios where portfolioID == nil || portfolio.id == portfolioID {
            for position in portfolio.positions {
                let lot = Holding.Lot(portfolioID: portfolio.id, portfolioName: portfolio.name, position: position)
                if bySymbol[position.symbol] == nil {
                    order.append(position.symbol)
                    // A source that could not name the listing reports the symbol; the name on record is better.
                    let known = meta[position.symbol]?.name
                    let name = known.flatMap { $0 == position.symbol ? nil : $0 } ?? position.name
                    bySymbol[position.symbol] = Holding(symbol: position.symbol, name: name, lots: [lot])
                } else {
                    bySymbol[position.symbol]?.lots.append(lot)
                }
            }
        }
        return order.compactMap { bySymbol[$0] }
    }

    var visibleHoldings: [Holding] { holdings(in: selectedPortfolioID) }

    func holding(_ symbol: String) -> Holding? {
        visibleHoldings.first { $0.symbol == symbol } ?? holdings(in: nil).first { $0.symbol == symbol }
    }

    func totals(in portfolioID: UUID?) -> Totals {
        var totals = Totals()
        for holding in holdings(in: portfolioID) {
            totals.count += 1
            guard let value = value(holding) else {
                totals.missing += 1
                continue
            }
            totals.value += value
            totals.cost += cost(holding) ?? 0
            totals.gain += gain(holding) ?? 0
            if holding.lots.contains(where: { $0.position.costUnknown }) { totals.uncosted += 1 }
            totals.day += dayChange(holding) ?? 0
        }
        return totals
    }

    var visibleTotals: Totals { totals(in: selectedPortfolioID) }

    var selectedPortfolioName: String {
        portfolios.first { $0.id == selectedPortfolioID }?.name ?? "All Portfolios"
    }

    /// Text for the menu bar item, or nil to show only the icon.
    var menuBarTitle: String? {
        let totals = totals(in: nil)
        guard totals.value > 0 else { return nil }
        // While sharing is likely, fall back to the percentage, which reveals no amounts.
        let mode = amountsHidden && menuBarMode.showsAmounts ? MenuBarMode.percent : menuBarMode
        let arrow = totals.day >= 0 ? "▲" : "▼"
        let pct = (abs(totals.dayPct) / 100).formatted(.percent.precision(.fractionLength(2)))
        let change = Fmt.money(abs(totals.day), decimals: 0)
        switch mode {
        case .icon: return nil
        case .percent: return "\(arrow) \(pct)"
        case .change: return "\(arrow) \(change)"
        case .changeAndPercent: return "\(arrow) \(change) · \(pct)"
        case .value: return "\(Fmt.compactEUR(totals.value)) \(arrow) \(pct)"
        }
    }

    // MARK: Editing

    func addPortfolio(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let portfolio = Portfolio(name: trimmed)
        portfolios.append(portfolio)
        selectedPortfolioID = portfolio.id
        save()
    }

    func renamePortfolio(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = portfolios.firstIndex(where: { $0.id == id }) else { return }
        portfolios[index].name = trimmed
        save()
    }

    func deletePortfolio(_ id: UUID) {
        portfolios.removeAll { $0.id == id }
        if selectedPortfolioID == id { selectedPortfolioID = nil }
        save()
    }

    func add(_ position: Position, to portfolioID: UUID) {
        guard let index = portfolios.firstIndex(where: { $0.id == portfolioID }) else { return }
        portfolios[index].positions.append(position)
        save()
        Task { await refresh() }
    }

    func update(_ position: Position, in portfolioID: UUID, movingTo target: UUID) {
        guard let from = portfolios.firstIndex(where: { $0.id == portfolioID }),
              let index = portfolios[from].positions.firstIndex(where: { $0.id == position.id })
        else { return }
        if target == portfolioID {
            portfolios[from].positions[index] = position
        } else if let to = portfolios.firstIndex(where: { $0.id == target }) {
            portfolios[from].positions.remove(at: index)
            portfolios[to].positions.append(position)
        }
        save()
        Task { await refresh() }
    }

    func delete(_ position: Position, from portfolioID: UUID) {
        guard let index = portfolios.firstIndex(where: { $0.id == portfolioID }) else { return }
        portfolios[index].positions.removeAll { $0.id == position.id }
        save()
    }
}
