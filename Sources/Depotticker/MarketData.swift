import Foundation

/// Where share prices come from. Exchange prices are licensed data, so the app does not ship with a
/// built-in feed: each user picks a source and, for a licensed vendor, enters their own key.
enum DataSource: String, Codable, CaseIterable, Identifiable {
    case none
    /// Deutsche Börse's free delayed trade files (Xetra, Frankfurt, Tradegate), read on this device.
    case boerse
    /// EODHD (eodhd.com) with the user's own API token.
    case eodhd
    /// Yahoo Finance's undocumented endpoints. Only in the direct-download build.
    case yahoo

    var id: String { rawValue }

    static var available: [DataSource] {
        #if DIRECT
        return [.none, .boerse, .eodhd, .yahoo]
        #else
        return [.none, .boerse, .eodhd]
        #endif
    }

    var title: String {
        switch self {
        case .none: return "None"
        case .boerse: return "German exchanges (free, 15 minutes delayed)"
        case .eodhd: return "EODHD (your own API key)"
        case .yahoo: return "Yahoo Finance (unofficial)"
        }
    }

    var needsKey: Bool { self == .eodhd }

    /// Shown wherever prices appear.
    var attribution: String {
        switch self {
        case .none: return ""
        case .boerse: return "Prices: Deutsche Börse delayed data (Xetra, Frankfurt, Tradegate), 15 minutes delayed · Exchange rates: European Central Bank"
        case .eodhd: return "Prices: EODHD, delayed · Exchange rates: European Central Bank"
        case .yahoo: return "Prices and exchange rates: Yahoo Finance (unofficial)"
        }
    }

    /// How often quotes are fetched. Licensed plans count every symbol of every request.
    var refreshInterval: Duration {
        switch self {
        case .yahoo: return .seconds(20)
        case .boerse: return .seconds(60)
        default: return .seconds(300)
        }
    }

    /// How long an intraday series stays fresh.
    var intradayLifetime: TimeInterval {
        switch self {
        case .yahoo: return 100
        case .boerse: return 60
        default: return 1_800
        }
    }
}

enum MarketDataError: LocalizedError {
    case noSource
    case missingKey
    case unsupported
    case http(Int)
    case malformed
    case missingISIN
    case unknownSymbol
    case noHistory

    var errorDescription: String? {
        switch self {
        case .noSource: return "No price source selected. Choose one in Settings."
        case .missingKey: return "The price source needs your API key. Enter it in Settings."
        case .unsupported: return "Not available from this price source"
        case .http(401), .http(403): return "The price source rejected the API key or the plan does not cover this data"
        case .http(402), .http(429): return "The price source's request limit is reached"
        case .http(let code): return "Price source returned HTTP \(code)"
        case .malformed: return "Unexpected response from the price source"
        case .missingISIN: return "This position has no ISIN yet, which the German exchanges' data needs. Edit the position to set it."
        case .unknownSymbol: return "Not traded on Xetra, Frankfurt or Tradegate in the last days"
        case .noHistory: return "The exchanges' free data has no price history. This chart fills up from the day you started using it."
        }
    }
}

/// The chosen source and the user's API keys, kept in a private file next to the portfolios so the
/// widget and the MCP server use the same source.
struct SourceConfig: Codable, Equatable {
    var source: DataSource = .none
    var keys: [String: String] = [:]

    func key(_ source: DataSource) -> String? {
        keys[source.rawValue].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func url(in directory: URL) -> URL { directory.appendingPathComponent("source.json") }

    static func load(from directory: URL) -> SourceConfig? {
        guard let data = try? Data(contentsOf: url(in: directory)),
              var config = try? JSONDecoder().decode(SourceConfig.self, from: data)
        else { return nil }
        if !DataSource.available.contains(config.source) { config.source = .none }
        return config
    }

    func save(to directory: URL) {
        let url = Self.url(in: directory)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Single entry point for prices, history, search and exchange rates.
enum MarketData {
    private static let lock = NSLock()
    private static var stored = SourceConfig()

    static var config: SourceConfig {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    static var source: DataSource { config.source }

    /// Listing currency and venue of a symbol differ between sources (a US share is quoted in euros on
    /// Tradegate), so each source keeps its own file of cached symbol facts.
    static var metaFileName: String {
        switch source {
        case .none, .yahoo: return "meta.json"
        default: return "meta-\(source.rawValue).json"
        }
    }

    /// Reads the configuration from the data folder. `DEPOTTICKER_SOURCE=eodhd:<key>` overrides it
    /// (used for demos and tests). Returns false when nothing has been chosen yet.
    @discardableResult
    static func configure(directory: URL) -> Bool {
        lock.lock(); self.directory = directory; lock.unlock()
        if let override = ProcessInfo.processInfo.environment["DEPOTTICKER_SOURCE"], !override.isEmpty {
            let parts = override.split(separator: ":", maxSplits: 1).map(String.init)
            if let source = DataSource(rawValue: parts[0]), DataSource.available.contains(source) {
                config = SourceConfig(source: source, keys: parts.count > 1 ? [source.rawValue: parts[1]] : [:])
                return true
            }
        }
        guard let loaded = SourceConfig.load(from: directory) else {
            config = SourceConfig()
            return false
        }
        config = loaded
        return true
    }

    private static func ready() throws -> DataSource {
        let current = config
        switch current.source {
        case .none: throw MarketDataError.noSource
        case .eodhd:
            guard current.key(.eodhd) != nil else { throw MarketDataError.missingKey }
            return .eodhd
        case .yahoo: return .yahoo
        case .boerse: return .boerse
        }
    }

    // MARK: ISINs

    private static var isinMap: [String: String] = [:]
    private static var directory: URL?

    /// The exchanges' files are keyed by ISIN; the app tells the source which ISIN each symbol has.
    static func register(isins: [String: String]) {
        lock.lock(); isinMap = isins; lock.unlock()
    }

    static func register(portfolios: [Portfolio]) {
        var map: [String: String] = [:]
        for position in portfolios.flatMap(\.positions) {
            if let isin = position.isin, !isin.isEmpty { map[position.symbol] = isin }
        }
        register(isins: map)
    }

    static var registeredISINs: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return isinMap
    }

    static func isin(for symbol: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return isinMap[symbol]
    }

    // MARK: Quote cache for the widget

    /// A widget must not download whole-market files, so the app leaves its latest quotes for it.
    static var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

    private struct CachedQuote: Codable {
        var price: Double
        var previousClose: Double
    }

    static func cache(quotes: [String: LiveQuote]) {
        guard source == .boerse, let directory, !quotes.isEmpty else { return }
        let slim = quotes.mapValues { CachedQuote(price: $0.price, previousClose: $0.previousClose) }
        try? JSONEncoder().encode(slim).write(to: directory.appendingPathComponent("quotes.json"), options: .atomic)
    }

    private static func cachedQuotes() throws -> [String: LiveQuote] {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("quotes.json")),
              let slim = try? JSONDecoder().decode([String: CachedQuote].self, from: data)
        else { throw MarketDataError.malformed }
        return slim.mapValues { LiveQuote(price: $0.price, previousClose: $0.previousClose, spark: []) }
    }

    // MARK: Prices

    /// Latest price and previous close per symbol. Symbols the source does not know are left out.
    static func quotes(_ symbols: [String]) async throws -> [String: LiveQuote] {
        guard !symbols.isEmpty else { return [:] }
        switch try ready() {
        case .eodhd: return try await EODHD.quotes(symbols)
        case .boerse: return try await Self.isExtension ? cachedQuotes() : DeutscheBoerse.quotes(symbols)
        case .yahoo:
            #if DIRECT
            return try await batched(symbols, size: Yahoo.batchSize) { try await Yahoo.spark($0) }
            #else
            throw MarketDataError.noSource
            #endif
        case .none: throw MarketDataError.noSource
        }
    }

    /// Price history of several symbols for one range, in raw quote units.
    static func series(_ symbols: [String], range: ChartRange) async -> [String: PriceSeries] {
        guard !symbols.isEmpty, let source = try? ready() else { return [:] }
        switch source {
        case .eodhd: return await EODHD.series(symbols, range: range)
        case .boerse: return await DeutscheBoerse.series(symbols, range: range)
        case .yahoo:
            #if DIRECT
            return (try? await batched(symbols, size: Yahoo.batchSize) { try await Yahoo.series($0, range: range) }) ?? [:]
            #else
            return [:]
            #endif
        case .none: return [:]
        }
    }

    static func chart(_ symbol: String, range: ChartRange) async throws -> ChartData {
        switch try ready() {
        case .eodhd: return try await EODHD.chart(symbol, range: range)
        case .boerse: return try await DeutscheBoerse.chart(symbol, range: range)
        case .yahoo:
            #if DIRECT
            return try await Yahoo.chart(symbol, range: range)
            #else
            throw MarketDataError.noSource
            #endif
        case .none: throw MarketDataError.noSource
        }
    }

    /// Every daily close on record, split-adjusted, oldest first, in the listing's currency.
    static func dailyHistory(_ symbol: String) async throws -> DailyHistory {
        switch try ready() {
        case .eodhd: return try await EODHD.dailyHistory(symbol)
        case .boerse: return try await DeutscheBoerse.dailyHistory(symbol)
        case .yahoo:
            #if DIRECT
            return try await Yahoo.dailyHistory(symbol)
            #else
            throw MarketDataError.noSource
            #endif
        case .none: throw MarketDataError.noSource
        }
    }

    static func search(_ text: String) async throws -> [SearchResult] {
        switch try ready() {
        case .eodhd: return try await EODHD.search(text)
        case .boerse: return try await Instruments.search(text)
        case .yahoo:
            #if DIRECT
            return try await Yahoo.search(text)
            #else
            throw MarketDataError.noSource
            #endif
        case .none: throw MarketDataError.noSource
        }
    }

    static func fundamentals(_ symbol: String) async throws -> Fundamentals {
        #if DIRECT
        if try ready() == .yahoo { return try await Yahoo.fundamentals(symbol) }
        #endif
        throw MarketDataError.unsupported
    }

    static func news(symbol: String, name: String) async throws -> [NewsItem] {
        switch try ready() {
        case .eodhd: return try await EODHD.news(symbol)
        case .boerse: return []
        case .yahoo:
            #if DIRECT
            return try await Yahoo.news(symbol: symbol, name: name)
            #else
            return []
            #endif
        case .none: return []
        }
    }

    // MARK: Exchange rates

    /// EUR value of one unit of each currency, now and at the previous fixing or close.
    static func rates(_ currencies: Set<String>) async -> [String: (now: Double, previous: Double)] {
        let wanted = currencies.subtracting(["EUR"])
        guard !wanted.isEmpty else { return [:] }
        #if DIRECT
        if source == .yahoo {
            let symbols = wanted.map { "\($0)EUR=X" }
            if let quotes = try? await batched(symbols, size: Yahoo.batchSize, { try await Yahoo.spark($0) }) {
                var out: [String: (now: Double, previous: Double)] = [:]
                for currency in wanted {
                    if let quote = quotes["\(currency)EUR=X"] { out[currency] = (quote.price, quote.previousClose) }
                }
                if !out.isEmpty { return out }
            }
        }
        #endif
        return await ECB.latest(wanted)
    }

    /// Daily value of one unit of `from` expressed in `to`, oldest first.
    static func rateHistory(from: String, to: String) async -> [ChartPoint]? {
        #if DIRECT
        if source == .yahoo { return (try? await Yahoo.dailyHistory("\(from)\(to)=X"))?.points }
        #endif
        return await ECB.history(from: from, to: to)
    }

    // MARK: Helpers

    static func batched<T>(_ symbols: [String], size: Int,
                           _ fetch: @escaping ([String]) async throws -> [String: T]) async throws -> [String: T] {
        let batches = stride(from: 0, to: symbols.count, by: size).map {
            Array(symbols[$0..<min($0 + size, symbols.count)])
        }
        var merged: [String: T] = [:]
        var failure: Error?
        await withTaskGroup(of: Result<[String: T], Error>.self) { group in
            for batch in batches {
                group.addTask {
                    do { return .success(try await fetch(batch)) } catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case .success(let part): merged.merge(part) { _, new in new }
                case .failure(let error): failure = error
                }
            }
        }
        if merged.isEmpty, let failure { throw failure }
        return merged
    }

    /// Some exchanges quote in minor units (pence, cents).
    static func normalise(currency: String) -> (String, Double) {
        switch currency {
        case "GBp", "GBX": return ("GBP", 0.01)
        case "ZAc", "ZAC": return ("ZAR", 0.01)
        case "ILA": return ("ILS", 0.01)
        default: return (currency.uppercased(), 1)
        }
    }
}
