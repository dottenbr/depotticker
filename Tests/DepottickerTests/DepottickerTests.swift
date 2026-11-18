import XCTest
@testable import Depotticker

final class TradeTests: XCTestCase {
    func testAverageCostSurvivesASale() {
        var position = Position(symbol: "AAPL", name: "Apple", quantity: 0, unitCost: 0, trades: [
            Trade(kind: .buy, day: "2023-03-14", quantity: 10, price: 150),
            Trade(kind: .buy, day: "2024-08-02", quantity: 10, price: 250),
            Trade(kind: .sell, day: "2025-05-20", quantity: 5, price: 300),
        ])
        XCTAssertEqual(position.quantity, 15)
        XCTAssertEqual(position.unitCost, 200, accuracy: 1e-9)
        XCTAssertEqual(position.realized, 500, accuracy: 1e-9)

        position.record(Trade(kind: .sell, day: "2025-06-01", quantity: 15, price: 100))
        XCTAssertEqual(position.quantity, 0)
        XCTAssertEqual(position.realized, -1000, accuracy: 1e-9)
    }

    func testTradesAreAppliedInDateOrderWithUndatedFirst() {
        let position = Position(symbol: "X", name: "X", quantity: 0, unitCost: 0, trades: [
            Trade(kind: .sell, day: "2024-01-01", quantity: 4, price: 20),
            Trade(kind: .buy, day: nil, quantity: 10, price: 10),
        ])
        XCTAssertEqual(position.quantity, 6)
        XCTAssertEqual(position.realized, 40, accuracy: 1e-9)
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
