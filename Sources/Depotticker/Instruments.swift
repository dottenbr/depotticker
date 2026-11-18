import Foundation

/// Finds ISINs and names without a price vendor, from two public registers:
/// ESMA's reference data of all instruments on EU trading venues (names and ISINs), and OpenFIGI
/// (which tickers an ISIN trades under). Neither needs a key.
enum Instruments {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        return URLSession(configuration: config)
    }()

    struct Instrument: Hashable {
        var isin: String
        var name: String
        /// CFI code: E… shares and depositary receipts, C… funds and ETFs.
        var kind: String
        var ended: Bool
    }

    // MARK: ESMA

    /// German venues whose trades the Deutsche Börse files carry.
    private static let venues = "mic:(XGAT OR XGRM OR XETA OR XETB OR FRAA OR FRAB)"

    private static func esma(_ query: String, rows: Int) async throws -> [Instrument] {
        var comps = URLComponents(string: "https://registers.esma.europa.eu/solr/esma_registers_firds/select")!
        comps.queryItems = [
            .init(name: "q", value: query), .init(name: "fq", value: venues), .init(name: "rows", value: String(rows)),
            .init(name: "wt", value: "json"), .init(name: "group", value: "true"), .init(name: "group.field", value: "isin"),
            .init(name: "group.main", value: "true"),
            .init(name: "fl", value: "isin,gnr_full_name,gnr_cfi_code,mrkt_trdng_trmination_date"),
        ]
        guard let url = comps.url else { throw MarketDataError.malformed }
        // The register is slow and sometimes answers with an error page; ask up to three times.
        var docs: [[String: Any]]?
        var failure: Error = MarketDataError.malformed
        for attempt in 0..<3 where docs == nil {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw MarketDataError.http(status) }
                docs = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["response"] as? [String: Any])?["docs"] as? [[String: Any]]
            } catch { failure = error }
        }
        guard let docs else { throw failure }
        let today = ISO8601DateFormatter().string(from: Date())
        return docs.compactMap { doc in
            guard let isin = doc["isin"] as? String, let name = doc["gnr_full_name"] as? String else { return nil }
            let end = doc["mrkt_trdng_trmination_date"] as? String
            return Instrument(isin: isin, name: name, kind: (doc["gnr_cfi_code"] as? String) ?? "",
                              ended: end.map { $0 < today } ?? false)
        }
    }

    /// Words usable in a register query: letters and digits only, lowercased.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func looksLikeISIN(_ text: String) -> Bool {
        let t = text.uppercased()
        return t.count == 12 && t.prefix(2).allSatisfy(\.isLetter) && t.dropFirst(2).allSatisfy { $0.isLetter || $0.isNumber }
            && t.last?.isNumber == true
    }

    /// Shares, depositary receipts and funds whose name starts with the given words, or one ISIN.
    static func find(_ text: String, rows: Int = 25) async throws -> [Instrument] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let query: String
        if looksLikeISIN(trimmed) {
            query = "isin:\(trimmed.uppercased())"
        } else {
            let terms = words(trimmed).prefix(4).map { "\($0)*" }
            guard !terms.isEmpty else { return [] }
            // Shares, preferred shares, depositary receipts and funds; not the certificates written on them.
            query = "gnr_full_name:(\(terms.joined(separator: " AND "))) AND gnr_cfi_code:(ES* OR EP* OR ED* OR C*)"
        }
        let found = try await esma(query, rows: rows)
        // Shares before funds before the rest; listings that have ended last.
        func rank(_ item: Instrument) -> Int {
            (item.ended ? 10 : 0) + (item.kind.hasPrefix("ES") ? 0 : item.kind.hasPrefix("C") ? 1 : item.kind.hasPrefix("ED") ? 2 : 3)
        }
        return found.sorted { rank($0) < rank($1) }
    }

    static func search(_ text: String) async throws -> [SearchResult] {
        try await find(text).filter { !$0.ended }.prefix(12).map { item in
            SearchResult(symbol: item.isin, name: item.name, exchange: "ISIN",
                         type: item.kind.hasPrefix("C") ? "ETF" : "EQUITY", isin: item.isin)
        }
    }

    // MARK: OpenFIGI

    struct Listing: Hashable {
        var ticker: String
        var exchange: String
        var name: String
        var shareClass: String?
    }

    private actor Pace {
        private var last = Date.distantPast

        /// Without a key OpenFIGI allows 25 requests a minute.
        func wait() async {
            let gap = Date().timeIntervalSince(last)
            if gap < 2.6 { try? await Task.sleep(for: .seconds(2.6 - gap)) }
            last = Date()
        }
    }

    private static let pace = Pace()

    /// Up to ten lookups in one request; the answer has one list of listings per job.
    private static func figi(_ jobs: [[String: String]]) async throws -> [[Listing]] {
        await pace.wait()
        var request = URLRequest(url: URL(string: "https://api.openfigi.com/v3/mapping")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jobs)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MarketDataError.http(status) }
        guard let answers = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MarketDataError.malformed }
        return answers.map { answer in
            ((answer["data"] as? [[String: Any]]) ?? []).compactMap { row in
                guard let ticker = row["ticker"] as? String, let exchange = row["exchCode"] as? String else { return nil }
                return Listing(ticker: ticker, exchange: exchange, name: (row["name"] as? String) ?? "",
                               shareClass: row["shareClassFIGI"] as? String)
            }
        }
    }

    /// Ticker and OpenFIGI exchange codes behind one of the app's symbols ("SAP.DE", "AAPL", "BA.L").
    static func target(for symbol: String) -> (ticker: String, exchanges: [String])? {
        guard let dot = symbol.lastIndex(of: ".") else { return (symbol, ["US"]) }
        let ticker = String(symbol[..<dot])
        switch String(symbol[symbol.index(after: dot)...]) {
        case "DE": return (ticker, ["GY", "GR"])
        case "F": return (ticker, ["GF", "GR"])
        case "SG": return (ticker, ["GS", "GR"])
        case "MU": return (ticker, ["GM", "GR"])
        case "AS": return (ticker, ["NA"])
        case "PA": return (ticker, ["FP"])
        case "L": return (ticker + "/", ["LN"])
        case "MI": return (ticker, ["IM"])
        case "SW": return (ticker, ["SW", "SE"])
        case "VI": return (ticker, ["AV"])
        case "MC": return (ticker, ["SM"])
        case "BR": return (ticker, ["BB"])
        case "ST": return (ticker, ["SS"])
        case "CO": return (ticker, ["DC"])
        case "HE": return (ticker, ["FH"])
        case "OL": return (ticker, ["NO"])
        default: return nil
        }
    }

    /// The symbol the app uses for an ISIN: the US ticker for US shares, otherwise the Xetra or
    /// Frankfurt ticker with suffix, and the ISIN itself when OpenFIGI knows neither.
    static func symbol(forISIN isin: String) async -> String {
        guard let listings = try? await figi([["idType": "ID_ISIN", "idValue": isin]]).first else { return isin }
        func ticker(_ exchange: String) -> String? { listings.first { $0.exchange == exchange }?.ticker }
        if isin.hasPrefix("US") || isin.hasPrefix("CA"), let us = ticker("US") { return us.replacingOccurrences(of: "/", with: ".") }
        if let xetra = ticker("GY") { return "\(xetra).DE" }
        if let us = ticker("US") { return us.replacingOccurrences(of: "/", with: ".") }
        if let frankfurt = ticker("GF") ?? ticker("GR") { return "\(frankfurt).F" }
        return isin
    }

    /// Finds the ISIN of one of the app's symbols. A candidate from the ESMA register is accepted only
    /// when OpenFIGI confirms that this ISIN trades under exactly that ticker on that exchange.
    static func isin(for symbol: String, names given: [String]) async -> (isin: String, name: String)? {
        guard let target = target(for: symbol) else { return nil }
        // The register's own name for the ticker makes the better search words.
        var names = given
        for exchange in target.exchanges {
            if let listing = try? await figi([["idType": "TICKER", "idValue": target.ticker, "exchCode": exchange]]).first?.first {
                names.insert(listing.name, at: 0)
                break
            }
        }
        var tried = Set<String>()
        var checked = Set<String>()
        for candidateName in names {
            let all = words(candidateName)
            // Register names are abbreviated ("Semiconduct.Manufact."), so search by word beginnings:
            // first the three leading words, then fewer.
            let attempts = [3, 2, 1].map { all.prefix($0).map { String($0.prefix(5)) }.joined(separator: " ") }
            for attempt in attempts where !attempt.isEmpty && tried.insert(attempt).inserted {
                guard let candidates = try? await find(attempt, rows: 60) else { continue }
                let open = candidates.filter { !$0.ended && !checked.contains($0.isin) }.prefix(30)
                var start = 0
                while start < open.count {
                    let batch = Array(open.dropFirst(start).prefix(10))
                    start += batch.count
                    guard let answers = try? await figi(batch.map { ["idType": "ID_ISIN", "idValue": $0.isin] }) else { continue }
                    for (candidate, listings) in zip(batch, answers) {
                        checked.insert(candidate.isin)
                        if listings.contains(where: { $0.ticker == target.ticker && target.exchanges.contains($0.exchange) }) {
                            return (candidate.isin, candidate.name)
                        }
                    }
                }
            }
        }
        return nil
    }
}
