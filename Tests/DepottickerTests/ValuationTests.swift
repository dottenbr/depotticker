import XCTest
@testable import Depotticker

final class ValuationTests: XCTestCase {
    private func meta(_ symbol: String, _ currency: String, scale: Double = 1) -> SymbolMeta {
        SymbolMeta(symbol: symbol, name: symbol, currency: currency, scale: scale, exchange: "")
    }

    private func quote(_ price: Double, previous: Double) -> LiveQuote {
        LiveQuote(price: price, previousClose: previous, spark: [])
    }

    private func holding(_ positions: Position...) -> Holding {
        Holding.group([Portfolio(name: "P", positions: positions)])[0]
    }

    func testEuroShare() throws {
        let valuation = Valuation(quotes: ["SAP.DE": quote(200, previous: 190)], meta: ["SAP.DE": meta("SAP.DE", "EUR")])
        let sap = holding(Position(symbol: "SAP.DE", name: "SAP", quantity: 5, unitCost: 120))
        XCTAssertEqual(valuation.value(sap), 1000)
        XCTAssertEqual(valuation.dayChange(sap), 50)
        XCTAssertEqual(valuation.cost(sap), 600)
        XCTAssertEqual(valuation.gain(sap), 400)
        XCTAssertEqual(try XCTUnwrap(valuation.gainPct(sap)), 66.666, accuracy: 0.001)
        XCTAssertEqual(valuation.unitCost(sap), 120)
    }

    func testTodaysChangeIncludesTheCurrencyMove() throws {
        // The share did not move in dollars, but the dollar fell from 0.92 to 0.90 EUR.
        let valuation = Valuation(quotes: ["AAPL": quote(100, previous: 100)], meta: ["AAPL": meta("AAPL", "USD")],
                                  fx: ["EUR": 1, "USD": 0.90], fxPrevious: ["EUR": 1, "USD": 0.92])
        let apple = holding(Position(symbol: "AAPL", name: "Apple", quantity: 10, unitCost: 50, currency: "USD"))
        XCTAssertEqual(try XCTUnwrap(valuation.value(apple)), 900, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(valuation.dayChange(apple)), -20, accuracy: 1e-9)
        // Cost in dollars is converted at today's rate.
        XCTAssertEqual(try XCTUnwrap(valuation.gain(apple)), 450, accuracy: 1e-9)
    }

    func testPenceAreScaledAndAEuroCostStaysInEuros() throws {
        let valuation = Valuation(quotes: ["BA.L": quote(1800, previous: 1800)], meta: ["BA.L": meta("BA.L", "GBP", scale: 0.01)],
                                  fx: ["EUR": 1, "GBP": 1.2])
        let bae = holding(Position(symbol: "BA.L", name: "BAE", quantity: 100, unitCost: 15))
        XCTAssertEqual(try XCTUnwrap(valuation.value(bae)), 2160, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(valuation.gain(bae)), 660, accuracy: 1e-9)
    }

    func testSharesOfUnknownCostCountTowardsValueOnly() throws {
        let valuation = Valuation(quotes: ["X": quote(10, previous: 10)], meta: ["X": meta("X", "EUR")])
        let mixed = Holding.group([
            Portfolio(name: "A", positions: [Position(symbol: "X", name: "X", quantity: 10, unitCost: 4)]),
            Portfolio(name: "B", positions: [Position(symbol: "X", name: "X", quantity: 5, unitCost: 0, costUnknown: true)]),
        ])[0]
        XCTAssertEqual(valuation.value(mixed), 150)
        XCTAssertEqual(valuation.cost(mixed), 40)
        XCTAssertEqual(valuation.gain(mixed), 60)
        XCTAssertEqual(valuation.unitCost(mixed), 4)

        let unknown = holding(Position(symbol: "X", name: "X", quantity: 5, unitCost: 0, costUnknown: true))
        XCTAssertNil(valuation.cost(unknown))
        XCTAssertNil(valuation.gain(unknown))
        let totals = valuation.totals([unknown])
        XCTAssertEqual(totals.value, 50)
        XCTAssertEqual(totals.gain, 0)
        XCTAssertEqual(totals.uncosted, 1)
    }

    func testAMissingPriceOrRateGivesNoFigureInsteadOfAWrongOne() {
        let valuation = Valuation(quotes: ["AAPL": quote(100, previous: 100)], meta: ["AAPL": meta("AAPL", "USD")])
        let apple = holding(Position(symbol: "AAPL", name: "Apple", quantity: 1, unitCost: 50))
        XCTAssertNil(valuation.value(apple))   // no USD rate
        XCTAssertNil(valuation.dayChange(apple))
        let other = holding(Position(symbol: "MSFT", name: "Microsoft", quantity: 1, unitCost: 50))
        XCTAssertNil(valuation.value(other))   // no quote
        let totals = valuation.totals([apple, other])
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.missing, 2)
        XCTAssertEqual(totals.value, 0)
    }

    func testTotalsAndPercentages() throws {
        let valuation = Valuation(quotes: ["A": quote(110, previous: 100), "B": quote(45, previous: 50)],
                                  meta: ["A": meta("A", "EUR"), "B": meta("B", "EUR")])
        let portfolios = [
            Portfolio(name: "One", positions: [Position(symbol: "A", name: "A", quantity: 1, unitCost: 100),
                                               Position(symbol: "B", name: "B", quantity: 2, unitCost: 40)]),
            Portfolio(name: "Two", positions: [Position(symbol: "A", name: "A", quantity: 1, unitCost: 80)]),
        ]
        let holdings = Holding.group(portfolios)
        XCTAssertEqual(holdings.map(\.symbol), ["A", "B"])
        XCTAssertEqual(holdings[0].quantity, 2)
        let totals = valuation.totals(holdings)
        XCTAssertEqual(totals.value, 310)
        XCTAssertEqual(totals.cost, 260)
        XCTAssertEqual(totals.gain, 50)
        XCTAssertEqual(totals.day, 10)
        XCTAssertEqual(totals.dayPct, 10.0 / 300 * 100, accuracy: 1e-9)
        XCTAssertEqual(totals.gainPct, 50.0 / 260 * 100, accuracy: 1e-9)
        // The parts add up to the whole.
        let parts = portfolios.map { valuation.totals(Holding.group([$0])) }
        XCTAssertEqual(parts.reduce(0) { $0 + $1.value }, totals.value, accuracy: 1e-9)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.gain }, totals.gain, accuracy: 1e-9)
    }

    func testRealisedGainIsConvertedAndUnknownWhenTheCostIs() throws {
        let valuation = Valuation(fx: ["EUR": 1, "USD": 0.9])
        let sold = holding(Position(symbol: "X", name: "X", quantity: 0, unitCost: 0, currency: "USD", trades: [
            Trade(kind: .buy, day: "2024-01-02", quantity: 10, price: 100),
            Trade(kind: .sell, day: "2025-01-02", quantity: 4, price: 150),
        ]))
        XCTAssertEqual(try XCTUnwrap(valuation.realized(sold)), 180, accuracy: 1e-9)
        var unknown = Position(symbol: "Y", name: "Y", quantity: 10, unitCost: 0, costUnknown: true)
        unknown.record(Trade(kind: .sell, day: "2025-01-02", quantity: 4, price: 150))
        XCTAssertNil(valuation.realized(holding(unknown)))
    }
}

final class PortfolioHistoryTests: XCTestCase {
    private func at(_ seconds: Double, _ price: Double) -> ChartPoint {
        ChartPoint(date: Date(timeIntervalSince1970: seconds), price: price)
    }

    func testSeriesAreAddedOnACommonGridCarryingTheLastPriceForward() {
        // Five-minute buckets on the 1D range. The second share starts trading later and is held at
        // its previous close until then.
        let a = PortfolioHistory.Series(factor: 2, points: [at(0, 10), at(300, 11), at(600, 12)], lead: 10)
        let b = PortfolioHistory.Series(factor: 1, points: [at(600, 105)], lead: 100)
        let combined = PortfolioHistory.combine([a, b], range: .day)
        XCTAssertEqual(combined.map(\.price), [120, 122, 129])
        XCTAssertEqual(combined.map { $0.date.timeIntervalSince1970 }, [0, 300, 600])
    }

    func testWithoutAPreviousCloseTheFirstPriceStandsIn() {
        let a = PortfolioHistory.Series(factor: 1, points: [at(0, 10), at(86_400, 20)], lead: nil)
        let b = PortfolioHistory.Series(factor: 1, points: [at(86_400, 5)], lead: nil)
        XCTAssertEqual(PortfolioHistory.combine([a, b], range: .year).map(\.price), [15, 25])
    }
}
