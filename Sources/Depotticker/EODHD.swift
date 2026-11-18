import Foundation

/// Client for EODHD (eodhd.com), used with the user's own API token. Quotes are delayed by about
/// 15 minutes; daily closes are adjusted for splits here because EODHD's plain close is not.
enum EODHD {
    static let batchSize = 15

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    // MARK: Symbols

    /// The app keeps Yahoo-style symbols ("SAP.DE", "AAPL"); EODHD wants "SAP.XETRA", "AAPL.US".
    private static let exchanges: [String: String] = [
        "DE": "XETRA", "F": "F", "SG": "STU", "MU": "MU", "BE": "BE", "HM": "HM", "DU": "DU", "HA": "HA",
        "L": "LSE", "IL": "IL", "PA": "PA", "AS": "AS", "BR": "BR", "LS": "LS", "MI": "MI", "MC": "MC",
        "SW": "SW", "VI": "VI", "ST": "ST", "CO": "CO", "HE": "HE", "OL": "OL", "IR": "IR", "WA": "WAR",
        "TO": "TO", "V": "V", "AX": "AU", "HK": "HK", "KS": "KO", "KQ": "KQ", "T": "TSE", "SI": "SG",
        "SA": "SA", "MX": "MX", "JO": "JSE", "TA": "TA",
    ]

    /// Likely quote currency per EODHD exchange, used until the search endpoint has named it.
    private static let currencies: [String: String] = [
        "US": "USD", "XETRA": "EUR", "F": "EUR", "STU": "EUR", "MU": "EUR", "BE": "EUR", "HM": "EUR",
        "DU": "EUR", "HA": "EUR", "PA": "EUR", "AS": "EUR", "BR": "EUR", "LS": "EUR", "MI": "EUR",
        "MC": "EUR", "VI": "EUR", "HE": "EUR", "IR": "EUR", "LSE": "GBX", "SW": "CHF", "ST": "SEK",
        "CO": "DKK", "OL": "NOK", "WAR": "PLN", "TO": "CAD", "V": "CAD", "AU": "AUD", "HK": "HKD",
        "KO": "KRW", "KQ": "KRW", "TSE": "JPY", "SG": "SGD", "SA": "BRL", "MX": "MXN", "JSE": "ZAC",
        "TA": "ILA", "EUFUND": "EUR", "CC": "USD", "INDX": "USD",
    ]

    static func code(for symbol: String) -> String {
        if symbol.hasPrefix("^") { return "\(symbol.dropFirst()).INDX" }
        if symbol.hasSuffix("-USD"), !symbol.contains(".") { return "\(symbol).CC" }
        guard let dot = symbol.lastIndex(of: ".") else { return "\(symbol).US" }
        let suffix = String(symbol[symbol.index(after: dot)...])
        let ticker = symbol[..<dot]
        // US share classes such as "BRK.B" are written "BRK-B.US".
        if suffix.count == 1, suffix != "F", suffix != "L", suffix != "V", suffix != "T" {
            return "\(ticker)-\(suffix).US"
        }
        return "\(ticker).\(exchanges[suffix] ?? suffix)"
    }

    /// The reverse of `code(for:)`, for search results.
    static func symbol(code: String, exchange: String) -> String {
        switch exchange {
        case "US": return code.replacingOccurrences(of: "-", with: ".")
        case "INDX": return "^\(code)"
        case "CC": return code
        default:
            let suffix = exchanges.first { $0.value == exchange }?.key ?? exchange
            return "\(code).\(suffix)"
        }
    }

    private static func exchange(of code: String) -> String {
        code.split(separator: ".").last.map(String.init) ?? "US"
    }

    // MARK: Requests

    private static func json(_ path: String, _ query: [String: String] = [:]) async throws -> Any {
        guard let token = MarketData.config.key(.eodhd) else { throw MarketDataError.missingKey }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "eodhd.com"
        comps.path = "/api/" + path
        comps.queryItems = (query.merging(["api_token": token, "fmt": "json"]) { a, _ in a })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw MarketDataError.malformed }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MarketDataError.http(status) }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// EODHD writes missing numbers as the string "NA".
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static let utc = Calendar.utc

    /// "2026-11-17" as noon UTC, so the day reads the same in every time zone.
    private static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    // MARK: Quotes

    private struct Live {
        var quote: LiveQuote
        var open: Double?
        var high: Double?
        var low: Double?
        var volume: Double?
        /// When the price was recorded.
        var time: Date?
    }

    private static func live(_ symbols: [String]) async throws -> [String: Live] {
        try await MarketData.batched(symbols, size: batchSize) { batch in
            let codes = batch.map(code(for:))
            var query: [String: String] = [:]
            if codes.count > 1 { query["s"] = codes.dropFirst().joined(separator: ",") }
            let obj = try await json("real-time/\(codes[0])", query)
            let rows = (obj as? [[String: Any]]) ?? (obj as? [String: Any]).map { [$0] } ?? []
            var out: [String: Live] = [:]
            for row in rows {
                guard let code = row["code"] as? String, let index = codes.firstIndex(of: code),
                      let price = number(row["close"]), price > 0
                else { continue }
                let previous = number(row["previousClose"]) ?? price
                out[batch[index]] = Live(
                    quote: LiveQuote(price: price, previousClose: previous > 0 ? previous : price, spark: []),
                    open: number(row["open"]), high: number(row["high"]), low: number(row["low"]),
                    volume: number(row["volume"]),
                    time: number(row["timestamp"]).map { Date(timeIntervalSince1970: $0) })
            }
            return out
        }
    }

    /// The previous close EODHD sends with a live quote is sometimes a day behind, so it is taken from
    /// the daily closes instead: the last close before the day of the quote.
    static func quotes(_ symbols: [String]) async throws -> [String: LiveQuote] {
        let now = try await live(symbols)
        let fixed = await MarketData.each(Array(now.keys), limit: 6) { symbol -> LiveQuote? in
            guard let entry = now[symbol] else { return nil }
            return await corrected(entry, symbol: symbol)
        }
        return Dictionary(fixed, uniquingKeysWith: { first, _ in first })
    }

    private static func corrected(_ entry: Live, symbol: String) async -> LiveQuote {
        var quote = entry.quote
        if let history = try? await dailyHistory(symbol) {
            let scale = await identity(symbol).units.1
            let dayStart = utc.startOfDay(for: entry.time ?? Date())
            if let previous = history.points.last(where: { $0.date < dayStart })?.price, previous > 0 {
                quote.previousClose = previous / scale
            }
        }
        return quote
    }

    // MARK: History

    private actor Cache {
        private var daily: [String: (fetched: Date, history: DailyHistory)] = [:]
        private var identities: [String: Identity] = [:]
        private var inFlight: [String: Task<DailyHistory, Error>] = [:]

        func history(_ symbol: String, download: @escaping () async throws -> DailyHistory) async throws -> DailyHistory {
            if let entry = daily[symbol], Date().timeIntervalSince(entry.fetched) < 6 * 3_600 { return entry.history }
            if let running = inFlight[symbol] { return try await running.value }
            let task = Task { try await download() }
            inFlight[symbol] = task
            defer { inFlight[symbol] = nil }
            let history = try await task.value
            daily[symbol] = (Date(), history)
            return history
        }

        func identity(_ symbol: String) -> Identity? { identities[symbol] }
        func store(_ identity: Identity, for symbol: String) { identities[symbol] = identity }
    }

    private static let cache = Cache()

    /// Divides every close before a split by the split ratio, so the whole series is in today's shares.
    static func adjust(_ bars: [(date: Date, close: Double)], splits: [(date: Date, ratio: Double)]) -> [ChartPoint] {
        let ordered = splits.sorted { $0.date < $1.date }
        var factor = 1.0
        var index = ordered.count - 1
        var points: [ChartPoint] = []
        for bar in bars.sorted(by: { $0.date < $1.date }).reversed() {
            while index >= 0, ordered[index].date > bar.date {
                factor *= ordered[index].ratio
                index -= 1
            }
            points.append(ChartPoint(date: bar.date, price: bar.close / factor))
        }
        return points.reversed()
    }

    /// "7.000000/1.000000" means seven new shares for one old share.
    static func ratio(_ text: String) -> Double? {
        let parts = text.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    /// Cached for six hours; callers asking for the same symbol at the same time share one download.
    static func dailyHistory(_ symbol: String) async throws -> DailyHistory {
        try await cache.history(symbol) { try await downloadHistory(symbol) }
    }

    private static func downloadHistory(_ symbol: String) async throws -> DailyHistory {
        let code = code(for: symbol)
        async let barsJSON = json("eod/\(code)", ["period": "d"])
        async let splitsJSON = try? json("splits/\(code)")
        let bars: [(date: Date, close: Double)] = ((try await barsJSON) as? [[String: Any]] ?? []).compactMap { row in
            guard let date = (row["date"] as? String).flatMap(day), let close = number(row["close"]), close > 0 else { return nil }
            return (date, close)
        }
        guard !bars.isEmpty else { throw MarketDataError.malformed }
        let splits: [(date: Date, ratio: Double)] = ((await splitsJSON) as? [[String: Any]] ?? []).compactMap { row in
            guard let date = (row["date"] as? String).flatMap(day), let ratio = (row["split"] as? String).flatMap(ratio) else { return nil }
            return (date, ratio)
        }
        let (currency, scale) = await identity(symbol).units
        let points = adjust(bars, splits: splits).map { ChartPoint(date: $0.date, price: $0.price * scale) }
        return DailyHistory(currency: currency, points: points)
    }

    /// Bars of the latest trading day on record, in raw quote units.
    private static func intraday(_ symbol: String) async throws -> [ChartPoint] {
        let from = Int(Date().timeIntervalSince1970) - 5 * 86_400
        let obj = try await json("intraday/\(code(for: symbol))", ["interval": "5m", "from": String(from)])
        let all: [ChartPoint] = (obj as? [[String: Any]] ?? []).compactMap { row in
            guard let time = number(row["timestamp"]), let close = number(row["close"]), close > 0 else { return nil }
            return ChartPoint(date: Date(timeIntervalSince1970: time), price: close, volume: number(row["volume"]))
        }
        guard let last = all.last else { return [] }
        return all.filter { utc.isDate($0.date, inSameDayAs: last.date) }
    }

    /// Points of one range in the listing's currency, plus the close before the first point of a day range.
    private static func points(_ symbol: String, range: ChartRange) async throws -> PriceSeries {
        let history = try await dailyHistory(symbol)
        if range == .day {
            let scale = await identity(symbol).units.1
            let bars = try await intraday(symbol).map { ChartPoint(date: $0.date, price: $0.price * scale, volume: $0.volume) }
            guard let first = bars.first else { throw MarketDataError.malformed }
            let dayStart = utc.startOfDay(for: first.date)
            return PriceSeries(points: bars, previousClose: history.points.last { $0.date < dayStart }?.price)
        }
        guard let start = range.start() else { throw MarketDataError.malformed }
        var points = history.points.filter { $0.date >= start }
        if range == .max {
            // Month ends are enough for decades of history.
            var monthly: [ChartPoint] = []
            for point in points {
                if let last = monthly.last, utc.isDate(last.date, equalTo: point.date, toGranularity: .month) {
                    monthly[monthly.count - 1] = point
                } else {
                    monthly.append(point)
                }
            }
            points = monthly
        }
        guard !points.isEmpty else { throw MarketDataError.malformed }
        return PriceSeries(points: points, previousClose: history.points.last { $0.date < start }?.price)
    }

    /// Price history in raw quote units, as the store expects (it applies the scale itself).
    static func series(_ symbols: [String], range: ChartRange) async -> [String: PriceSeries] {
        let found = await MarketData.each(symbols, limit: 6) { symbol -> PriceSeries? in
            guard var series = try? await points(symbol, range: range) else { return nil }
            let scale = await identity(symbol).units.1
            if scale != 1 {
                series.points = series.points.map { ChartPoint(date: $0.date, price: $0.price / scale, volume: $0.volume) }
                series.previousClose = series.previousClose.map { $0 / scale }
            }
            return series
        }
        return Dictionary(found, uniquingKeysWith: { first, _ in first })
    }

    static func chart(_ symbol: String, range: ChartRange) async throws -> ChartData {
        let series = try await points(symbol, range: range)
        let identity = await identity(symbol)
        let (currency, scale) = identity.units
        // One live request serves both the day's figures and the corrected previous close.
        let now = try? await live([symbol])[symbol]
        var corrected: LiveQuote?
        if let now { corrected = await self.corrected(now, symbol: symbol) }
        let history = try? await dailyHistory(symbol)
        let yearAgo = Date().addingTimeInterval(-365 * 86_400)
        let year = history?.points.filter { $0.date >= yearAgo }.map(\.price) ?? []
        let meta = SymbolMeta(
            symbol: symbol, name: identity.name, currency: currency, scale: scale, exchange: identity.exchange,
            open: range == .day ? now?.open.map { $0 * scale } : nil,
            dayHigh: now?.high.map { $0 * scale }, dayLow: now?.low.map { $0 * scale }, volume: now?.volume,
            week52High: year.max(), week52Low: year.min(),
            previousClose: range == .day ? corrected.map { $0.previousClose * scale } : nil)
        return ChartData(meta: meta, points: series.points,
                         previousClose: range == .day ? (meta.previousClose ?? series.previousClose) : series.previousClose,
                         session: nil)
    }

    // MARK: Search and identity

    struct Identity {
        var name: String
        var exchange: String
        /// Quote currency as EODHD reports it (may be a minor unit such as GBX).
        var currency: String

        var units: (String, Double) { MarketData.normalise(currency: currency) }
    }

    private struct Match {
        var code: String
        var exchange: String
        var name: String
        var type: String
        var currency: String
    }

    private static func matches(_ text: String, limit: Int) async throws -> [Match] {
        let path = text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
        let obj = try await json("search/\(path)", ["limit": String(limit)])
        return (obj as? [[String: Any]] ?? []).compactMap { row in
            guard let code = row["Code"] as? String, let exchange = row["Exchange"] as? String else { return nil }
            return Match(code: code, exchange: exchange, name: (row["Name"] as? String) ?? code,
                         type: (row["Type"] as? String) ?? "", currency: (row["Currency"] as? String) ?? "")
        }
    }

    /// Name, exchange and currency of a symbol; guessed from the exchange when the search does not answer.
    static func identity(_ symbol: String) async -> Identity {
        if let known = await cache.identity(symbol) { return known }
        let code = code(for: symbol)
        let exchange = exchange(of: code)
        let ticker = String(code.dropLast(exchange.count + 1))
        var identity = Identity(name: symbol, exchange: exchange, currency: currencies[exchange] ?? "USD")
        if let found = try? await matches(ticker, limit: 15),
           let match = found.first(where: { $0.code == ticker && $0.exchange == exchange }) {
            identity.name = match.name
            if !match.currency.isEmpty { identity.currency = match.currency }
        }
        await cache.store(identity, for: symbol)
        return identity
    }

    static func search(_ text: String) async throws -> [SearchResult] {
        let kinds = ["Common Stock": "EQUITY", "Preferred Stock": "EQUITY", "ETF": "ETF", "FUND": "MUTUALFUND",
                     "Mutual Fund": "MUTUALFUND", "INDEX": "INDEX", "Currency": "CRYPTOCURRENCY"]
        var seen = Set<String>()
        return try await matches(text, limit: 12).compactMap { match in
            guard let type = kinds[match.type] else { return nil }
            let symbol = symbol(code: match.code, exchange: match.exchange)
            guard seen.insert(symbol).inserted else { return nil }
            return SearchResult(symbol: symbol, name: match.name, exchange: match.exchange, type: type)
        }
    }

    static func news(_ symbol: String) async throws -> [NewsItem] {
        let obj = try await json("news", ["s": code(for: symbol), "limit": "8"])
        let formatter = ISO8601DateFormatter()
        return (obj as? [[String: Any]] ?? []).compactMap { row in
            guard let title = row["title"] as? String, let link = row["link"] as? String,
                  let url = URL(string: link), url.scheme == "https"
            else { return nil }
            let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
            return NewsItem(id: link, title: title, publisher: host, url: url,
                            date: (row["date"] as? String).flatMap(formatter.date) ?? Date(timeIntervalSince1970: 0))
        }
    }
}
