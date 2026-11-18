import XCTest
@testable import Depotticker

final class TradeTests: XCTestCase {
    func testAverageCostSurvivesASale() throws {
        var position = Position(symbol: "AAPL", name: "Apple", quantity: 0, unitCost: 0, trades: [
            Trade(kind: .buy, day: "2023-03-14", quantity: 10, price: 150),
            Trade(kind: .buy, day: "2024-08-02", quantity: 10, price: 250),
            Trade(kind: .sell, day: "2025-05-20", quantity: 5, price: 300),
        ])
        XCTAssertEqual(position.quantity, 15)
        XCTAssertEqual(position.unitCost, 200, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(position.realized), 500, accuracy: 1e-9)

        position.record(Trade(kind: .sell, day: "2025-06-01", quantity: 15, price: 100))
        XCTAssertEqual(position.quantity, 0)
        XCTAssertEqual(try XCTUnwrap(position.realized), -1000, accuracy: 1e-9)
    }

    func testTradesAreAppliedInDateOrderWithUndatedFirst() throws {
        let position = Position(symbol: "X", name: "X", quantity: 0, unitCost: 0, trades: [
            Trade(kind: .sell, day: "2024-01-01", quantity: 4, price: 20),
            Trade(kind: .buy, day: nil, quantity: 10, price: 10),
        ])
        XCTAssertEqual(position.quantity, 6)
        XCTAssertEqual(try XCTUnwrap(position.realized), 40, accuracy: 1e-9)
    }

    func testSaleFromSharesOfUnknownCostHasNoStatedProfit() {
        var position = Position(symbol: "X", name: "X", quantity: 10, unitCost: 0, costUnknown: true)
        XCTAssertEqual(position.realized, 0)
        position.record(Trade(kind: .sell, day: "2026-01-05", quantity: 4, price: 50))
        XCTAssertEqual(position.quantity, 6)
        // The proceeds (200) must not be reported as profit.
        XCTAssertNil(position.realized)
    }

    func testFirstRecordedTradeKeepsTheExistingHolding() {
        var position = Position(symbol: "X", name: "X", quantity: 14, unitCost: 260.6, currency: "USD")
        position.record(Trade(kind: .buy, day: "2026-11-10", quantity: 6, price: 200))
        XCTAssertEqual(position.quantity, 20)
        XCTAssertEqual(position.unitCost, 242.42, accuracy: 1e-9)
        XCTAssertEqual(position.trades.count, 2)
    }

    func testOldFilesWithoutNewFieldsStillLoad() throws {
        let json = #"{"portfolios":[{"id":"11111111-1111-4111-8111-111111111111","name":"A","positions":[{"id":"A0000000-0000-4000-8000-000000000001","symbol":"SAP.DE","name":"SAP","quantity":5,"unitCost":120}]}]}"#
        let file = try JSONDecoder().decode(PortfolioFile.self, from: Data(json.utf8))
        let position = try XCTUnwrap(file.portfolios.first?.positions.first)
        XCTAssertEqual(position.currency, "EUR")
        XCTAssertFalse(position.costUnknown)
        XCTAssertTrue(position.trades.isEmpty)
        // A plain EUR position is written back without the optional fields.
        let written = String(decoding: try JSONEncoder().encode(position), as: UTF8.self)
        XCTAssertFalse(written.contains("currency"))
        XCTAssertFalse(written.contains("trades"))
    }
}

final class ImportTests: XCTestCase {
    func testRaymondJamesExport() throws {
        let csv = """
        "Description","SYMBOL/CUSIP","Quantity","Delayed Price","Current Value","Daily Price Change","Daily Value Change","Investment Gain/(Loss)","Amount Invested / Unit","Product Type","Amount Invested (x)","Estimated Annual Income","Time Held"\r
        "EXAMPLE ONE INCORPORATED","AAA","23.000","$180.94","$4,161.62","$0.00","$0.00","($487.14)","$202.12","Stock","$4,648.76","$0.00","Long"\r
        "EXAMPLE TWO COMPANY","BRK.B","1,278.805","$116.94","$149,543.46","$0.00","$0.00","","","Stock","","$557.61",""\r
        """
        let portfolios = try CSVCodec.parse(csv)
        XCTAssertEqual(portfolios.map(\.name), ["Raymond James"])
        let positions = portfolios[0].positions
        XCTAssertEqual(positions.count, 2)
        XCTAssertEqual(positions[0].symbol, "AAA")
        XCTAssertEqual(positions[0].quantity, 23)
        XCTAssertEqual(positions[0].unitCost, 202.12)
        XCTAssertEqual(positions[0].currency, "USD")
        XCTAssertEqual(positions[0].timeHeld, "long")
        XCTAssertFalse(positions[0].costUnknown)
        XCTAssertEqual(positions[1].symbol, "BRK-B")
        XCTAssertEqual(positions[1].quantity, 1278.805)
        XCTAssertTrue(positions[1].costUnknown)
    }

    func testDollarAmounts() {
        XCTAssertEqual(CSVCodec.parseDollar("$4,161.62"), 4161.62)
        XCTAssertEqual(CSVCodec.parseDollar("($487.14)"), -487.14)
        XCTAssertNil(CSVCodec.parseDollar(""))
    }

    func testOwnLayoutWithDatedRowsAndGermanNumbers() throws {
        let csv = """
        Portfolio;Symbol;Name;Quantity;Average cost;Currency;Date;Type
        Broker;AAPL;Apple;10;150,25;EUR;14.03.2023;Buy
        Broker;AAPL;Apple;6;172,40;EUR;2024-08-02;Buy
        Broker;AAPL;Apple;4;210;EUR;20.05.2025;Sell
        Broker;SAP.DE;SAP SE;5;1.120,50;EUR;;
        US;VTI;Vanguard;12,5;;USD;;
        """
        let portfolios = try CSVCodec.parse(csv)
        XCTAssertEqual(portfolios.map(\.name), ["Broker", "US"])
        let apple = portfolios[0].positions[0]
        XCTAssertEqual(apple.trades.map(\.day), ["2023-03-14", "2024-08-02", "2025-05-20"])
        XCTAssertEqual(apple.quantity, 12)
        XCTAssertEqual(apple.unitCost, (10 * 150.25 + 6 * 172.4) / 16, accuracy: 1e-9)
        let sap = portfolios[0].positions[1]
        XCTAssertTrue(sap.trades.isEmpty)
        XCTAssertEqual(sap.unitCost, 1120.5)
        let fund = portfolios[1].positions[0]
        XCTAssertEqual(fund.quantity, 12.5)
        XCTAssertEqual(fund.currency, "USD")
        XCTAssertTrue(fund.costUnknown)
    }

    func testOldHeaderStillImports() throws {
        let portfolios = try CSVCodec.parse("Portfolio,Symbol,Name,Quantity,Average cost (EUR)\nA,AAPL,Apple,10,150.25\n")
        XCTAssertEqual(portfolios[0].positions[0].unitCost, 150.25)
        XCTAssertEqual(portfolios[0].positions[0].currency, "EUR")
    }

    func testBadDateIsReported() {
        XCTAssertThrowsError(try CSVCodec.parse("Symbol,Quantity,Average cost,Date\nAAPL,1,10,31/31/2024\n"))
    }

    func testExportRoundTrip() throws {
        let original = [Portfolio(name: "Broker", positions: [
            Position(symbol: "AAPL", name: "Apple", quantity: 0, unitCost: 0, currency: "USD", trades: [
                Trade(kind: .buy, day: "2023-03-14", quantity: 10, price: 150.25),
                Trade(kind: .sell, day: "2025-05-20", quantity: 4, price: 210),
            ]),
            Position(symbol: "SAP.DE", name: "SAP SE", quantity: 5, unitCost: 120),
            Position(symbol: "DIS", name: "Disney", quantity: 3, unitCost: 0, currency: "USD", costUnknown: true),
        ])]
        let text = CSVCodec.export(original, priceEUR: { _ in 100 }, rateEUR: { _ in 1 })
        let back = try CSVCodec.parse(text)[0].positions
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[0].quantity, 6)
        XCTAssertEqual(back[0].unitCost, 150.25, accuracy: 1e-9)
        XCTAssertEqual(back[0].currency, "USD")
        XCTAssertEqual(back[0].trades.count, 2)
        XCTAssertEqual(back[1].unitCost, 120)
        XCTAssertTrue(back[2].costUnknown)
    }
}

final class MergeTests: XCTestCase {
    private func portfolio(_ positions: [Position]) -> [Portfolio] { [Portfolio(name: "Broker", positions: positions)] }

    func testReimportUpdatesInsteadOfDuplicating() {
        let existing = portfolio([Position(symbol: "AAPL", name: "Apple", quantity: 10, unitCost: 100)])
        let incoming = portfolio([Position(symbol: "AAPL", name: "Apple", quantity: 12, unitCost: 110),
                                  Position(symbol: "MSFT", name: "Microsoft", quantity: 1, unitCost: 300)])
        let outcome = PortfolioMerge.merge(incoming, into: existing, replacing: false)
        XCTAssertEqual(outcome.updated, 1)
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.portfolios[0].positions.map(\.quantity), [12, 1])
        XCTAssertEqual(outcome.portfolios[0].positions[0].id, existing[0].positions[0].id)
    }

    func testRecordedPurchasesAreKeptButEstimatesAreReplaced() {
        let recorded = Position(symbol: "AAPL", name: "Apple", quantity: 0, unitCost: 0,
                                trades: [Trade(kind: .buy, day: "2024-01-02", quantity: 10, price: 100)])
        let estimated = Position(symbol: "MSFT", name: "Microsoft", quantity: 0, unitCost: 0,
                                 trades: [Trade(kind: .buy, day: "2024-01-02", quantity: 10, price: 100, estimated: true)])
        let incoming = portfolio([Position(symbol: "AAPL", name: "Apple", quantity: 99, unitCost: 1),
                                  Position(symbol: "MSFT", name: "Microsoft", quantity: 99, unitCost: 1)])
        let outcome = PortfolioMerge.merge(incoming, into: portfolio([recorded, estimated]), replacing: false)
        XCTAssertEqual(outcome.kept, 1)
        XCTAssertEqual(outcome.portfolios[0].positions.map(\.quantity), [10, 99])
    }
}

final class SourceTests: XCTestCase {
    func testECBParsesDaysOldestFirst() {
        let xml = """
        <Cube><Cube time="2026-11-17"><Cube currency="USD" rate="1.0989"/><Cube currency="GBP" rate="0.83305"/></Cube>
        <Cube time="2026-11-16"><Cube currency="USD" rate="1.1000"/></Cube></Cube>
        """
        let days = ECB.parse(xml)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].rates["USD"], 1.1)
        XCTAssertEqual(days[1].rates["GBP"], 0.83305)
        XCTAssertLessThan(days[0].date, days[1].date)
    }

    func testEODHDSymbolMapping() {
        XCTAssertEqual(EODHD.code(for: "AAPL"), "AAPL.US")
        XCTAssertEqual(EODHD.code(for: "SAP.DE"), "SAP.XETRA")
        XCTAssertEqual(EODHD.code(for: "ALV.F"), "ALV.F")
        XCTAssertEqual(EODHD.code(for: "VOD.L"), "VOD.LSE")
        XCTAssertEqual(EODHD.code(for: "BRK.B"), "BRK-B.US")
        XCTAssertEqual(EODHD.code(for: "^GDAXI"), "GDAXI.INDX")
        XCTAssertEqual(EODHD.symbol(code: "SAP", exchange: "XETRA"), "SAP.DE")
        XCTAssertEqual(EODHD.symbol(code: "AAPL", exchange: "US"), "AAPL")
        XCTAssertEqual(EODHD.symbol(code: "BRK-B", exchange: "US"), "BRK.B")
    }

    func testSplitAdjustmentPutsOldClosesIntoTodaysShares() {
        func day(_ offset: Double) -> Date { Date(timeIntervalSince1970: offset * 86_400) }
        let bars: [(date: Date, close: Double)] = [(day(1), 700), (day(2), 100), (day(3), 104), (day(4), 26)]
        let splits: [(date: Date, ratio: Double)] = [(day(2), 7), (day(4), 4)]
        let points = EODHD.adjust(bars, splits: splits)
        XCTAssertEqual(points.map(\.price), [25, 25, 26, 26])
        XCTAssertEqual(EODHD.ratio("7.000000/1.000000"), 7)
        XCTAssertEqual(EODHD.ratio("1.000000/10.000000"), 0.1)
    }

    func testSourceConfigRoundTripIsPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(SourceConfig.load(from: directory))
        SourceConfig(source: .eodhd, keys: ["eodhd": "abc"]).save(to: directory)
        let loaded = try XCTUnwrap(SourceConfig.load(from: directory))
        XCTAssertEqual(loaded.source, .eodhd)
        XCTAssertEqual(loaded.key(.eodhd), "abc")
        let mode = try FileManager.default.attributesOfItem(atPath: SourceConfig.url(in: directory).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    /// Compares the licensed source with the previous one on live data. Run with DEPOTTICKER_LIVE=1.
    func testLiveEODHDMatchesYahoo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEPOTTICKER_LIVE"] == "1")
        MarketData.config = SourceConfig(source: .eodhd, keys: ["eodhd": "demo"])
        let quotes = try await MarketData.quotes(["AAPL", "TSLA", "VTI", "AMZN"])
        XCTAssertEqual(quotes.count, 4)
        let history = try await MarketData.dailyHistory("AAPL")
        let yahoo = try await Yahoo.dailyHistory("AAPL")
        XCTAssertEqual(history.currency, "USD")
        func close(_ points: [ChartPoint], _ day: String) -> Double? {
            points.first { Trade.dayFormatter.string(from: $0.date) == day }?.price
        }
        for day in ["1999-06-01", "2005-03-01", "2014-06-06", "2014-06-09", "2020-08-28", "2020-08-31", "2026-11-13"] {
            let a = try XCTUnwrap(close(history.points, day), day), b = try XCTUnwrap(close(yahoo.points, day), day)
            print("AAPL \(day): EODHD \(a)  Yahoo \(b)")
            XCTAssertEqual(a, b, accuracy: b * 0.002, day)
        }
        let yahooQuote = try await Yahoo.spark(["AAPL", "TSLA"])
        for symbol in ["AAPL", "TSLA"] {
            print("\(symbol) quote: EODHD \(quotes[symbol]!.price) prev \(quotes[symbol]!.previousClose)  Yahoo \(yahooQuote[symbol]!.price) prev \(yahooQuote[symbol]!.previousClose)")
        }
        for range in [ChartRange.day, .month, .year, .max] {
            let chart = try await MarketData.chart("AAPL", range: range)
            print("chart \(range.rawValue): \(chart.points.count) points, first \(chart.points.first!.date) last \(chart.points.last!.date) prev \(chart.previousClose ?? -1) 52w \(chart.meta.week52Low ?? -1)-\(chart.meta.week52High ?? -1)")
        }
        let rates = await MarketData.rates(["USD", "GBP", "CHF"])
        print("ECB:", rates)
        XCTAssertEqual(rates.count, 3)
        let fxHistory = await MarketData.rateHistory(from: "USD", to: "EUR")
        let fx = try XCTUnwrap(fxHistory)
        print("ECB history: \(fx.count) days from \(fx.first!.date), last \(fx.last!.price)")
        let news = try await MarketData.news(symbol: "AAPL", name: "Apple")
        print("news:", news.first?.title ?? "none", news.first?.publisher ?? "")
    }

    func testBoerseParsesAndTracksTrades() {
        let wanted: Set<String> = ["DE0007164600"]
        func line(_ time: String, _ price: Double, _ quantity: Int, system: String = "CLOB", isin: String = "DE0007164600") -> Substring {
            Substring("{\"messageId\":\"x\",\"tradingDateAndTime\":\"\(time)\",\"instrumentIdentificationCode\":\"\(isin)\",\"price\":\(price),\"priceCurrency\":\"EUR\",\"priceNotation\":\"MONE\",\"quantity\":\(quantity),\"tradingSystem\":\"\(system)\"}")
        }
        XCTAssertNil(DeutscheBoerse.parse(line: line("2026-11-17T10:00:00.1Z", 200, 5, isin: "US0378331005"), wanted: wanted, venue: .xetra))
        XCTAssertNil(DeutscheBoerse.parse(line: line("2026-11-17T10:00:00.1Z", 200, 0), wanted: wanted, venue: .xetra))
        var state = DeutscheBoerse.State()
        let rows = [
            line("2026-11-17T16:35:10.000000001Z", 201.3, 100),
            line("2026-11-17T20:50:59.5Z", 202, 8, system: "RETL"),
            line("2026-11-17T09:00:00Z", 199, 10),
            line("2026-11-18T08:05:00Z", 203.5, 20),
        ]
        for row in rows.prefix(3) {
            DeutscheBoerse.apply(DeutscheBoerse.parse(line: row, wanted: wanted, venue: .xetra)!, venue: .xetra, to: &state)
        }
        // The official price is the last order-book trade; the evening retail trade is kept apart.
        XCTAssertEqual(state.last["DETR"]?["DE0007164600"]?.price, 201.3)
        XCTAssertEqual(state.late["DETR"]?["DE0007164600"]?.price, 202)
        XCTAssertEqual(state.bars["DETR"]?["DE0007164600"]?.count, 2)
        // The minute files of the 17th were read from the last trade to the end of trading.
        state.readBefore = .init(day: "2026-11-17", read: ["DETR": Set((16 * 60 + 35)...DeutscheBoerse.lastMinute)])
        DeutscheBoerse.apply(DeutscheBoerse.parse(line: rows[3], wanted: wanted, venue: .xetra)!, venue: .xetra, to: &state)
        XCTAssertEqual(state.previous["DETR"]?["DE0007164600"], 201.3)
        XCTAssertEqual(state.history["DETR"]?["DE0007164600"]?["2026-11-17"], 201.3)
        XCTAssertEqual(state.last["DETR"]?["DE0007164600"]?.price, 203.5)
        XCTAssertEqual(state.bars["DETR"]?["DE0007164600"]?.count, 1)
    }

    func testAHalfReadDayIsNotRecordedAsACloseUntilItsDailyFileConfirmsIt() {
        let isin = "DE0007164600"
        func trade(_ stamp: String, _ price: Double) -> DeutscheBoerse.Trade {
            .init(isin: isin, price: price, currency: "EUR", quantity: 1, time: DeutscheBoerse.date(stamp)!, regular: true)
        }
        var state = DeutscheBoerse.State()
        // The app was closed at noon on the 17th and opened again on the 18th.
        DeutscheBoerse.apply(trade("2026-11-17T11:00:00Z", 199), venue: .xetra, to: &state)
        state.readBefore = .init(day: "2026-11-17", read: ["DETR": Set(360...(11 * 60 + 5))])
        DeutscheBoerse.apply(trade("2026-11-18T08:05:00Z", 203.5), venue: .xetra, to: &state)
        // The noon price is the best previous price known so far, but it is no closing price.
        XCTAssertEqual(state.previous["DETR"]?[isin], 199)
        XCTAssertNil(state.history["DETR"]?[isin]?["2026-11-17"])

        // The complete file of the 17th arrives after today's trades.
        DeutscheBoerse.confirm(day: "2026-11-17", trades: [trade("2026-11-17T16:35:10Z", 201.3), trade("2026-11-17T11:00:00Z", 199)],
                               venue: .xetra, in: &state)
        XCTAssertEqual(state.previous["DETR"]?[isin], 201.3)
        XCTAssertEqual(state.history["DETR"]?[isin]?["2026-11-17"], 201.3)
        XCTAssertEqual(state.last["DETR"]?[isin]?.price, 203.5)
    }

    func testStateFilesOfEarlierVersionsStillLoad() throws {
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DeutscheBoerse.State())) as? [String: Any])
        old["readBefore"] = nil
        XCTAssertNoThrow(try JSONDecoder().decode(DeutscheBoerse.State.self, from: JSONSerialization.data(withJSONObject: old)))
    }

    func testGzipLinesAreInflatedInPieces() throws {
        // "a\nbb\nccc" gzipped.
        let gz = Data(base64Encoded: "H4sIAAAAAAAC/0vkSkriSk5OBgDlN5rECAAAAA==")!
        var lines: [String] = []
        let inflater = DeutscheBoerse.LineInflater { lines.append(String($0)) }
        XCTAssertTrue(inflater.feed(gz.prefix(7)))
        XCTAssertTrue(inflater.feed(gz.dropFirst(7)))
        inflater.finish()
        XCTAssertEqual(lines, ["a", "bb", "ccc"])
    }

    func testSymbolTargetsForTheRegisters() {
        XCTAssertEqual(Instruments.target(for: "AAPL")?.exchanges, ["US"])
        XCTAssertEqual(Instruments.target(for: "SAP.DE")?.ticker, "SAP")
        XCTAssertEqual(Instruments.target(for: "SAP.DE")?.exchanges, ["GY", "GR"])
        XCTAssertTrue(Instruments.looksLikeISIN("de0007164600"))
        XCTAssertFalse(Instruments.looksLikeISIN("SAP"))
        XCTAssertEqual(Instruments.words("Taiwan Semiconductor Mfg. Co."), ["taiwan", "semiconductor", "mfg", "co"])
    }

    /// Reads real exchange files and compares with the previous source. Run with DEPOTTICKER_LIVE=1.
    func testLiveBoerseMatchesYahoo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEPOTTICKER_LIVE"] == "1")
        let names = ["SAP.DE": "SAP SE", "AAPL": "Apple Inc.", "VGWL.DE": "Vanguard FTSE All-World UCITS ETF",
                     "HY9H.F": "SK hynix Inc.", "TSM": "Taiwan Semiconductor Manufacturing", "VTI": "Vanguard Total Stock Market ETF",
                     "RHM.DE": "Rheinmetall AG", "ASML.AS": "ASML Holding N.V.", "BA.L": "BAE Systems plc"]
        var isins: [String: String] = [:]
        for (symbol, name) in names.sorted(by: { $0.key < $1.key }) {
            let found = await Instruments.isin(for: symbol, names: [name])
            print("ISIN \(symbol): \(found?.isin ?? "not found") \(found?.name ?? "")")
            if let found { isins[symbol] = found.isin }
        }
        XCTAssertEqual(isins["SAP.DE"], "DE0007164600")
        XCTAssertEqual(isins["AAPL"], "US0378331005")
        MarketData.register(isins: isins)
        MarketData.config = SourceConfig(source: .boerse)
        DeutscheBoerse.blocking = true
        let started = Date()
        let quotes = try await MarketData.quotes(Array(isins.keys))
        print("first read took \(Int(Date().timeIntervalSince(started))) s")
        let yahoo = try await Yahoo.spark(Array(isins.keys) + ["EURUSD=X", "EURGBP=X"])
        for symbol in isins.keys.sorted() {
            let meta = try? await MarketData.chart(symbol, range: .day)
            print("\(symbol): boerse \(quotes[symbol]?.price ?? -1) prev \(quotes[symbol]?.previousClose ?? -1) late \(quotes[symbol]?.extendedPrice ?? -1) [\(meta?.meta.exchange ?? "?") \(meta?.meta.currency ?? "?") bars \(meta?.points.count ?? 0)]  yahoo \(yahoo[symbol]?.price ?? -1) prev \(yahoo[symbol]?.previousClose ?? -1)")
        }
        print("EURUSD \(yahoo["EURUSD=X"]?.price ?? -1) EURGBP \(yahoo["EURGBP=X"]?.price ?? -1)")
        let sap = try XCTUnwrap(quotes["SAP.DE"]), sapYahoo = try XCTUnwrap(yahoo["SAP.DE"])
        XCTAssertEqual(sap.previousClose, sapYahoo.previousClose, accuracy: sapYahoo.previousClose * 0.002)
        let backlog = await DeutscheBoerse.backlog()
        print("backlog after the first round: \(backlog) minute files")
    }

    // MARK: Gap-filling source

    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 86_400)
    }

    func testOlderHistoryIsConvertedAndJoinedBeforeTheOwnCloses() throws {
        let older = (0..<5).map { ChartPoint(date: day($0), price: 100) }
        let rates = [ChartPoint(date: day(-1), price: 0.9), ChartPoint(date: day(2), price: 0.8)]
        let own = [ChartPoint(date: day(3), price: 81), ChartPoint(date: day(4), price: 82)]
        let joined = try XCTUnwrap(MarketData.join(older: older, rates: rates, own: own))
        XCTAssertEqual(joined.map(\.price), [90, 90, 80, 81, 82])
        // A day the app was not running is taken from the second source.
        let holed = try XCTUnwrap(MarketData.join(older: older, rates: rates, own: [own[0], ChartPoint(date: day(6), price: 83)]))
        XCTAssertEqual(holed.map(\.price), [90, 90, 80, 81, 80, 83])
    }

    func testHistoryOfADifferentShareIsRejected() {
        let older = (0..<3).map { ChartPoint(date: day($0), price: 100) }
        let own = [ChartPoint(date: day(3), price: 10)]
        XCTAssertNil(MarketData.join(older: older, rates: nil, own: own))
    }

    func testSliceKeepsTheCloseBeforeTheRange() throws {
        let now = Date()
        let points = (0..<30).map { ChartPoint(date: now.addingTimeInterval(Double($0 - 29) * 86_400), price: Double($0)) }
        let week = try XCTUnwrap(MarketData.slice(points, range: .week))
        XCTAssertEqual(week.points.last?.price, 29)
        XCTAssertEqual(week.previousClose, (week.points.first?.price ?? 0) - 1)
        XCTAssertNil(MarketData.slice(points, range: .day))
    }

    func testSupplementOnlyAppliesToTheExchangeSource() throws {
        let old = try JSONDecoder().decode(SourceConfig.self, from: Data(#"{"keys":{},"source":"boerse"}"#.utf8))
        XCTAssertNil(old.fill)
        XCTAssertNil(SourceConfig(source: .boerse, keys: [:], supplement: .eodhd).fill, "no key, no supplement")
        XCTAssertEqual(SourceConfig(source: .boerse, keys: ["eodhd": "k"], supplement: .eodhd).fill, .eodhd)
        XCTAssertNil(SourceConfig(source: .eodhd, keys: ["eodhd": "k"], supplement: .eodhd).fill)
        XCTAssertTrue(SourceConfig(source: .boerse, keys: ["eodhd": "k"], supplement: .eodhd).attribution.contains("EODHD"))
    }

    /// The exchanges plus a second source on live data. Run with DEPOTTICKER_LIVE=1.
    func testLiveGapsAreFilled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEPOTTICKER_LIVE"] == "1")
        MarketData.register(isins: ["SAP.DE": "DE0007164600", "AAPL": "US0378331005", "BA.L": "GB0002634946",
                                    "VTI": "US9229087690"])
        MarketData.config = SourceConfig(source: .boerse, keys: [:], supplement: .yahoo)
        DeutscheBoerse.blocking = true
        let symbols = ["SAP.DE", "AAPL", "BA.L", "VTI", "MGC"]
        let quotes = try await MarketData.quotes(symbols)
        print("supplemented:", MarketData.supplemented.sorted())
        for symbol in symbols {
            let day = try? await MarketData.chart(symbol, range: .day)
            let year = try? await MarketData.chart(symbol, range: .year)
            let all = try? await MarketData.dailyHistory(symbol)
            print("\(symbol): \(quotes[symbol]?.price ?? -1) prev \(quotes[symbol]?.previousClose ?? -1) [\(day?.meta.exchange ?? "?") \(day?.meta.currency ?? "?")] 1Y \(year?.points.count ?? 0) points \(year?.points.first?.price ?? -1) → \(year?.points.suffix(3).map(\.price) ?? []) prev \(year?.previousClose ?? -1); all \(all?.points.count ?? 0) in \(all?.currency ?? "?") from \(all?.points.first?.date.description ?? "?")")
        }
        XCTAssertEqual(quotes.count, 5)
        XCTAssertTrue(MarketData.supplemented.isSuperset(of: ["MGC"]))
        XCTAssertFalse(MarketData.supplemented.contains("SAP.DE"))
        let series = await MarketData.series(symbols, range: .month)
        XCTAssertEqual(series.count, 5)
        let aapl = try await MarketData.dailyHistory("AAPL")
        XCTAssertEqual(aapl.currency, "EUR")
        XCTAssertGreaterThan(aapl.points.count, 5_000)
    }

    func testClosingAuctionFollowsFrankfurtTime() {
        let winter = Date(timeIntervalSince1970: 1_795_000_000) // November 2026
        XCTAssertEqual(DeutscheBoerse.closingAuction(on: winter), [16 * 60 + 35, 16 * 60 + 36, 16 * 60 + 37, 16 * 60 + 38])
        let summer = Date(timeIntervalSince1970: 1_783_000_000) // July 2026
        XCTAssertTrue(DeutscheBoerse.closingAuction(on: summer).contains(15 * 60 + 35))
    }
}
