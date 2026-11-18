import XCTest
@testable import Depotticker

/// The tools an AI agent uses to edit the portfolios, run against a file in a temporary folder.
final class MCPTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("DEPOTTICKER_DATA", directory.path, 1)
        MCPServer.lookUp = { symbol in
            symbol == "NOPE" ? nil : SymbolMeta(symbol: symbol, name: "\(symbol) Inc.", currency: "EUR", scale: 1, exchange: "")
        }
        PortfolioRepository().save([Portfolio(name: "Broker", positions: [
            Position(symbol: "SAP.DE", name: "SAP SE", quantity: 10, unitCost: 100),
            Position(symbol: "DIS", name: "Disney", quantity: 5, unitCost: 0, currency: "USD", costUnknown: true),
        ])])
    }

    override func tearDown() {
        unsetenv("DEPOTTICKER_DATA")
        try? FileManager.default.removeItem(at: directory)
    }

    private var positions: [Position] { PortfolioRepository().load().first?.positions ?? [] }

    private func position(_ symbol: String) throws -> Position {
        try XCTUnwrap(positions.first { $0.symbol == symbol })
    }

    private func assertFails(_ name: String, _ arguments: [String: Any], file: StaticString = #filePath, line: UInt = #line) async {
        let before = positions
        do {
            _ = try await MCPServer.call(name, arguments)
            XCTFail("\(name) should have been refused", file: file, line: line)
        } catch {}
        XCTAssertEqual(positions, before, "a refused call must not change the file", file: file, line: line)
    }

    func testAddPosition() async throws {
        _ = try await MCPServer.call("add_position", ["portfolio": "broker", "symbol": "aapl", "quantity": 3.0,
                                                      "average_cost": 150.0, "currency": "usd"])
        let added = try position("AAPL")
        XCTAssertEqual(added.quantity, 3)
        XCTAssertEqual(added.unitCost, 150)
        XCTAssertEqual(added.currency, "USD")
        XCTAssertEqual(added.name, "AAPL Inc.")

        await assertFails("add_position", ["portfolio": "Broker", "symbol": "NOPE", "quantity": 1.0, "average_cost": 1.0])
        await assertFails("add_position", ["portfolio": "Elsewhere", "symbol": "MSFT", "quantity": 1.0, "average_cost": 1.0])
        await assertFails("add_position", ["portfolio": "Broker", "symbol": "MSFT", "quantity": 0.0, "average_cost": 1.0])
        await assertFails("add_position", ["portfolio": "Broker", "symbol": "MSFT", "quantity": 1.0, "average_cost": 1.0, "currency": "EURO"])
    }

    func testAddingASymbolAlreadyHeldDoesNotCreateASecondPosition() async throws {
        await assertFails("add_position", ["portfolio": "Broker", "symbol": "SAP.DE", "quantity": 1.0, "average_cost": 1.0])
    }

    func testUpdatePosition() async throws {
        _ = try await MCPServer.call("update_position", ["portfolio": "Broker", "symbol": "SAP.DE", "quantity": 12.0])
        XCTAssertEqual(try position("SAP.DE").quantity, 12)
        XCTAssertEqual(try position("SAP.DE").unitCost, 100)

        // Giving a cost makes a position of unknown cost a known one.
        _ = try await MCPServer.call("update_position", ["portfolio": "Broker", "symbol": "DIS", "average_cost": 80.0])
        XCTAssertFalse(try position("DIS").costUnknown)
        XCTAssertEqual(try position("DIS").unitCost, 80)

        await assertFails("update_position", ["portfolio": "Broker", "symbol": "SAP.DE"])
        await assertFails("update_position", ["portfolio": "Broker", "symbol": "SAP.DE", "quantity": -1.0])
    }

    func testBuyAndSell() async throws {
        _ = try await MCPServer.call("add_transaction", ["portfolio": "Broker", "symbol": "SAP.DE", "type": "buy",
                                                         "quantity": 10.0, "price": 200.0, "date": "2026-03-02"])
        var sap = try position("SAP.DE")
        XCTAssertEqual(sap.quantity, 20)
        XCTAssertEqual(sap.unitCost, 150)
        XCTAssertEqual(sap.trades.count, 2)   // the earlier holding became an undated opening purchase

        let answer = try await MCPServer.call("add_transaction", ["portfolio": "Broker", "symbol": "SAP.DE", "type": "sell",
                                                                  "quantity": 5.0, "price": 250.0, "date": "2026-06-01"])
        sap = try position("SAP.DE")
        XCTAssertEqual(sap.quantity, 15)
        XCTAssertEqual(sap.unitCost, 150)
        XCTAssertEqual(sap.realized, 500)
        XCTAssertTrue(answer.contains("realised gain 500"), answer)

        // Once transactions are recorded, quantity and cost can no longer be set by hand.
        await assertFails("update_position", ["portfolio": "Broker", "symbol": "SAP.DE", "quantity": 1.0])
    }

    func testASaleCannotExceedTheHoldingOnItsDate() async throws {
        await assertFails("add_transaction", ["portfolio": "Broker", "symbol": "SAP.DE", "type": "sell",
                                              "quantity": 11.0, "price": 250.0, "date": "2026-06-01"])
        await assertFails("add_transaction", ["portfolio": "Broker", "symbol": "MSFT", "type": "sell",
                                              "quantity": 1.0, "price": 250.0, "date": "2026-06-01"])
        await assertFails("add_transaction", ["portfolio": "Broker", "symbol": "SAP.DE", "type": "buy",
                                              "quantity": 1.0, "price": 250.0, "date": "01.06.2026"])
        // Shares bought in June cannot cover a sale in May.
        _ = try await MCPServer.call("add_transaction", ["portfolio": "Broker", "symbol": "MSFT", "type": "buy",
                                                         "quantity": 2.0, "price": 300.0, "date": "2026-06-01"])
        await assertFails("add_transaction", ["portfolio": "Broker", "symbol": "MSFT", "type": "sell",
                                              "quantity": 1.0, "price": 310.0, "date": "2026-05-01"])
    }

    func testASaleFromSharesOfUnknownCostReportsNoProfit() async throws {
        let answer = try await MCPServer.call("add_transaction", ["portfolio": "Broker", "symbol": "DIS", "type": "sell",
                                                                  "quantity": 2.0, "price": 90.0, "date": "2026-06-01"])
        XCTAssertEqual(try position("DIS").quantity, 3)
        XCTAssertTrue(answer.contains("realised gain unknown"), answer)
        let listed = try await MCPServer.call("list_portfolios", [:])
        XCTAssertTrue(listed.contains("\"realized_gain\" : null"), listed)
        XCTAssertTrue(listed.contains("\"average_cost\" : null"), listed)
    }

    func testRemovePositionKeepsABackup() async throws {
        _ = try await MCPServer.call("remove_position", ["portfolio": "Broker", "symbol": "sap.de"])
        XCTAssertEqual(positions.map(\.symbol), ["DIS"])
        let backup = try Data(contentsOf: directory.appendingPathComponent("portfolios.backup.json"))
        XCTAssertEqual(PortfolioRepository.decode(backup)?.first?.positions.count, 2)
        await assertFails("remove_position", ["portfolio": "Broker", "symbol": "SAP.DE"])
    }

    func testCreatePortfolio() async throws {
        _ = try await MCPServer.call("create_portfolio", ["name": "Second"])
        XCTAssertEqual(PortfolioRepository().load().map(\.name), ["Broker", "Second"])
        await assertFails("create_portfolio", ["name": "second"])
    }
}
