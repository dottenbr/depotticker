import Foundation

enum YahooError: LocalizedError {
    case http(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .http(429): return "Rate limited by the data source, retrying"
        case .http(let code): return "Data source returned HTTP \(code)"
        case .malformed: return "Unexpected response from the data source"
        }
    }
}

/// Minimal client for Yahoo Finance's public JSON endpoints.
enum Yahoo {
    static let batchSize = 20

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0"]
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// The quote endpoint needs a session cookie plus a matching "crumb" token.
    private actor CrumbStore {
        private var crumb: String?

        func current() async throws -> String {
            if let crumb { return crumb }
            _ = try? await Yahoo.session.data(from: URL(string: "https://fc.yahoo.com")!)
            let (data, response) = try await Yahoo.session.data(
                from: URL(string: "https://query2.finance.yahoo.com/v1/test/getcrumb")!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let text = String(data: data, encoding: .utf8), !text.isEmpty, text.count < 40 else {
                throw YahooError.http(status)
            }
            crumb = text
            return text
        }

        func reset() { crumb = nil }
    }

    private static let crumbs = CrumbStore()

    /// P/E, market cap, dividend yield and similar figures.
    static func fundamentals(_ symbol: String) async throws -> Fundamentals {
        for attempt in 0..<2 {
            let crumb = try await crumbs.current()
            do {
                let obj = try await json("/v7/finance/quote", ["symbols": symbol, "crumb": crumb],
                                         host: "query2.finance.yahoo.com")
                guard let root = obj as? [String: Any],
                      let response = root["quoteResponse"] as? [String: Any],
                      let q = (response["result"] as? [[String: Any]])?.first
                else { throw YahooError.malformed }
                let scale = normalise(currency: q["currency"] as? String ?? "USD")
                return Fundamentals(
                    trailingPE: q["trailingPE"] as? Double,
                    forwardPE: q["forwardPE"] as? Double,
                    eps: (q["epsTrailingTwelveMonths"] as? Double).map { $0 * scale.1 },
                    marketCap: q["marketCap"] as? Double,
                    dividendYield: q["dividendYield"] as? Double,
                    priceToBook: q["priceToBook"] as? Double,
                    analystRating: q["averageAnalystRating"] as? String,
                    earningsDate: (q["earningsTimestamp"] as? Double).map { Date(timeIntervalSince1970: $0) },
                    currency: (q["financialCurrency"] as? String) ?? scale.0
                )
            } catch YahooError.http(let code) where (code == 401 || code == 403) && attempt == 0 {
                await crumbs.reset()
            }
        }
        throw YahooError.malformed
    }

    /// Recent headlines for a symbol; falls back to the company name when the symbol finds nothing.
    static func news(symbol: String, name: String) async throws -> [NewsItem] {
        let plain = name
            .replacingOccurrences(of: #"(?i)[,.]|\b(inc|corp|corporation|ag|se|plc|ltd|n\.?v|holdings?|company|co|the|group)\b"#,
                                  with: " ", options: .regularExpression)
            .split(separator: " ").prefix(2).joined(separator: " ")
        for term in [symbol, plain] where !term.isEmpty {
            let obj = try await json("/v1/finance/search", ["q": term, "quotesCount": "0", "newsCount": "8"])
            guard let root = obj as? [String: Any], let items = root["news"] as? [[String: Any]] else { continue }
            let news: [NewsItem] = items.compactMap { item in
                guard let title = item["title"] as? String,
                      let link = item["link"] as? String, let url = URL(string: link),
                      url.scheme == "https"
                else { return nil }
                return NewsItem(
                    id: (item["uuid"] as? String) ?? link,
                    title: title,
                    publisher: (item["publisher"] as? String) ?? "",
                    url: url,
                    date: Date(timeIntervalSince1970: (item["providerPublishTime"] as? Double) ?? 0)
                )
            }
            if !news.isEmpty { return news }
        }
        return []
    }

    private static func json(_ path: String, _ query: [String: String],
                             host: String = "query1.finance.yahoo.com") async throws -> Any {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = path
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw YahooError.malformed }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw YahooError.http(status) }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Latest price, previous close and an intraday sparkline for up to 20 symbols.
    static func spark(_ symbols: [String]) async throws -> [String: LiveQuote] {
        // A single-symbol request has a different shape, so always send at least two.
        var list = symbols
        if list.count == 1 { list.append("EURUSD=X") }
        let obj = try await json("/v8/finance/spark", [
            "symbols": list.joined(separator: ","), "range": "1d", "interval": "5m",
        ])
        guard let dict = obj as? [String: Any] else { throw YahooError.malformed }
        var out: [String: LiveQuote] = [:]
        for (symbol, value) in dict {
            guard let d = value as? [String: Any] else { continue }
            let closes = (d["close"] as? [Any] ?? []).compactMap { $0 as? Double }
            // "fullday" includes pre-market and after-hours trades; the bars are the regular session.
            // Outside the session the last bar is the official close, so values match the brokers'.
            let fullday = d["fulldayPrice"] as? Double
            let now = Date().timeIntervalSince1970
            let inSession = ((d["start"] as? Double) ?? .infinity) <= now && now <= ((d["end"] as? Double) ?? 0)
            guard let price = inSession ? (fullday ?? closes.last) : (closes.last ?? fullday) else { continue }
            let prev = (d["previousClose"] as? Double) ?? (d["chartPreviousClose"] as? Double) ?? price
            var extended: Double?
            if !inSession, let fullday, abs(fullday - price) > price * 0.0001 { extended = fullday }
            out[symbol] = LiveQuote(price: price, previousClose: prev, spark: closes, extendedPrice: extended)
        }
        return out
    }

    /// Price history for up to 20 symbols in one request (raw quote units, no currency information).
    static func series(_ symbols: [String], range: ChartRange) async throws -> [String: PriceSeries] {
        var list = symbols
        if list.count == 1 { list.append("EURUSD=X") }
        let q = range.query
        let obj = try await json("/v8/finance/spark", [
            "symbols": list.joined(separator: ","), "range": q.range, "interval": q.interval,
        ])
        guard let dict = obj as? [String: Any] else { throw YahooError.malformed }
        var out: [String: PriceSeries] = [:]
        for (symbol, value) in dict {
            guard let d = value as? [String: Any] else { continue }
            let closes = d["close"] as? [Any] ?? []
            let stamps = d["timestamp"] as? [Any] ?? []
            var points: [ChartPoint] = []
            for (index, stamp) in stamps.enumerated() where index < closes.count {
                guard let time = stamp as? Double, let close = closes[index] as? Double else { continue }
                points.append(ChartPoint(date: Date(timeIntervalSince1970: time), price: close))
            }
            guard !points.isEmpty else { continue }
            out[symbol] = PriceSeries(points: points,
                                      previousClose: (d["chartPreviousClose"] as? Double) ?? (d["previousClose"] as? Double))
        }
        return out
    }

    static func chart(_ symbol: String, range: ChartRange) async throws -> ChartData {
        let q = range.query
        let obj = try await json("/v8/finance/chart/\(symbol)", [
            "range": q.range, "interval": q.interval, "includePrePost": "false",
        ])
        guard let root = obj as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let m = result["meta"] as? [String: Any]
        else { throw YahooError.malformed }

        let (currency, scale) = normalise(currency: m["currency"] as? String ?? "USD")
        let quote = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first ?? [:]
        let closes = quote["close"] as? [Any] ?? []
        let opens = (quote["open"] as? [Any] ?? []).compactMap { $0 as? Double }
        let volumes = quote["volume"] as? [Any] ?? []
        let stamps = result["timestamp"] as? [Any] ?? []

        var points: [ChartPoint] = []
        for (i, stamp) in stamps.enumerated() where i < closes.count {
            guard let t = stamp as? Double, let c = closes[i] as? Double else { continue }
            let volume = i < volumes.count ? volumes[i] as? Double : nil
            points.append(ChartPoint(date: Date(timeIntervalSince1970: t), price: c * scale, volume: volume))
        }

        var session: MarketSession?
        if let regular = (m["currentTradingPeriod"] as? [String: Any])?["regular"] as? [String: Any],
           let start = regular["start"] as? Double, let end = regular["end"] as? Double {
            session = MarketSession(open: Date(timeIntervalSince1970: start), close: Date(timeIntervalSince1970: end))
        }

        func num(_ key: String) -> Double? { (m[key] as? Double).map { $0 * scale } }
        let prev = num("chartPreviousClose") ?? num("previousClose")
        let meta = SymbolMeta(
            symbol: symbol,
            name: (m["longName"] as? String) ?? (m["shortName"] as? String) ?? symbol,
            currency: currency,
            scale: scale,
            exchange: (m["fullExchangeName"] as? String) ?? (m["exchangeName"] as? String) ?? "",
            open: range == .day ? opens.first.map { $0 * scale } : nil,
            dayHigh: num("regularMarketDayHigh"),
            dayLow: num("regularMarketDayLow"),
            volume: m["regularMarketVolume"] as? Double,
            week52High: num("fiftyTwoWeekHigh"),
            week52Low: num("fiftyTwoWeekLow"),
            previousClose: range == .day ? prev : nil
        )
        return ChartData(meta: meta, points: points, previousClose: prev, session: session)
    }

    static func search(_ text: String) async throws -> [SearchResult] {
        let obj = try await json("/v1/finance/search", [
            "q": text, "quotesCount": "10", "newsCount": "0",
        ])
        guard let root = obj as? [String: Any], let quotes = root["quotes"] as? [[String: Any]] else {
            throw YahooError.malformed
        }
        return quotes.compactMap { q in
            guard let symbol = q["symbol"] as? String else { return nil }
            let type = (q["quoteType"] as? String) ?? ""
            guard ["EQUITY", "ETF", "MUTUALFUND", "CRYPTOCURRENCY", "INDEX"].contains(type) else { return nil }
            return SearchResult(
                symbol: symbol,
                name: (q["longname"] as? String) ?? (q["shortname"] as? String) ?? symbol,
                exchange: (q["exchDisp"] as? String) ?? "",
                type: type
            )
        }
    }

    /// Some exchanges quote in minor units (pence, cents).
    static func normalise(currency: String) -> (String, Double) {
        switch currency {
        case "GBp", "GBX": return ("GBP", 0.01)
        case "ZAc": return ("ZAR", 0.01)
        case "ILA": return ("ILS", 0.01)
        default: return (currency.uppercased(), 1)
        }
    }
}
