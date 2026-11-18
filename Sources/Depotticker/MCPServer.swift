#if os(macOS)
import Foundation

/// A small Model Context Protocol server (JSON-RPC over stdio) so AI agents can read and edit the
/// portfolios. Start it with `Depotticker --mcp`; the running app picks up changes within seconds.
enum MCPServer {
    static let version = "0.5"

    static func runBlocking() -> Never {
        Task.detached {
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8),
                      let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { continue }
                if let response = await handle(message) { send(response) }
            }
            exit(0)
        }
        dispatchMain()
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private static func handle(_ message: [String: Any]) async -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"] else { return nil } // notifications get no reply
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }

        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "depotticker", "version": version],
                "instructions": "Read and edit the user's stock portfolios in the Depotticker app. "
                    + "Costs are average purchase prices per share in each position's own currency (EUR unless stated). "
                    + "The same symbol can be held in several portfolios. Record purchases and sales with add_transaction. Symbols are a US ticker or ticker plus exchange suffix "
                    + "(for example AAPL, SAP.DE); use search_symbols when unsure.",
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let output = try await call(name, arguments)
                return result(["content": [["type": "text", "text": output]], "isError": false])
            } catch {
                return result(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method \(method)"]]
        }
    }

    // MARK: Tools

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:],
                             required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    private static let string: [String: Any] = ["type": "string"]
    private static let number: [String: Any] = ["type": "number"]

    private static var tools: [[String: Any]] {
        [
            tool("list_portfolios", "List all portfolios with their positions (symbol, name, quantity, average cost, cost currency, recorded transactions)."),
            tool("get_valuation", "Current value of every position and portfolio in EUR with live prices, today's change and total gain."),
            tool("search_symbols", "Find the symbol for a company, fund or ISIN at the user's price source.",
                 ["query": string], required: ["query"]),
            tool("create_portfolio", "Create a new, empty portfolio.", ["name": string], required: ["name"]),
            tool("add_position", "Add a position to a portfolio.",
                 ["portfolio": string, "symbol": string, "quantity": number,
                  "average_cost": ["type": "number", "description": "Average purchase price per share in `currency`."],
                  "currency": ["type": "string", "description": "Currency of the purchase price, ISO code. Default EUR."],
                  "name": ["type": "string", "description": "Optional display name; looked up when omitted."]],
                 required: ["portfolio", "symbol", "quantity", "average_cost"]),
            tool("update_position", "Change the quantity, average cost and/or cost currency of an existing position that has no recorded transactions.",
                 ["portfolio": string, "symbol": string, "quantity": number, "average_cost": number, "currency": string],
                 required: ["portfolio", "symbol"]),
            tool("add_transaction", "Record a purchase or sale. Creates the position if needed; quantity and average cost are then derived from the transactions (average-cost method).",
                 ["portfolio": string, "symbol": string,
                  "type": ["type": "string", "enum": ["buy", "sell"]],
                  "quantity": number,
                  "price": ["type": "number", "description": "Price per share in the position's currency."],
                  "date": ["type": "string", "description": "Trade date as YYYY-MM-DD."],
                  "currency": ["type": "string", "description": "Only used when the position is created. Default EUR."]],
                 required: ["portfolio", "symbol", "type", "quantity", "price", "date"]),
            tool("remove_position", "Remove a position from a portfolio.",
                 ["portfolio": string, "symbol": string], required: ["portfolio", "symbol"]),
        ]
    }

    struct ToolError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private static func json(_ object: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    private static func describe(_ position: Position) -> [String: Any] {
        var row: [String: Any] = ["symbol": position.symbol, "name": position.name, "quantity": position.quantity,
                                  "cost_currency": position.currency]
        if let isin = position.isin { row["isin"] = isin }
        if position.costUnknown { row["average_cost"] = NSNull() } else { row["average_cost"] = position.unitCost }
        if !position.trades.isEmpty {
            row["transactions"] = position.orderedTrades.map {
                ["type": $0.kind.rawValue, "date": $0.day ?? "unknown", "quantity": $0.quantity, "price": $0.price] as [String: Any]
            }
            row["realized_gain"] = round2(position.realized)
        }
        return row
    }

    /// False when some sale would take the holding below zero at its date.
    private static func soldWithinHolding(_ position: Position) -> Bool {
        var shares = 0.0
        for trade in position.orderedTrades {
            shares += trade.kind == .buy ? trade.quantity : -trade.quantity
            if shares < -1e-9 { return false }
        }
        return true
    }

    private static func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        let repository = PortfolioRepository()
        MarketData.configure(directory: repository.directory)
        // This process ends after its answer, so it waits for the exchange files instead of reading them in the background.
        DeutscheBoerse.blocking = true
        var portfolios = repository.load()

        func text(_ key: String) throws -> String {
            guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                throw ToolError(message: "Missing argument “\(key)”.")
            }
            return value
        }
        func portfolioIndex() throws -> Int {
            let wanted = try text("portfolio")
            guard let index = portfolios.firstIndex(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                let names = portfolios.map(\.name).joined(separator: ", ")
                throw ToolError(message: "No portfolio named “\(wanted)”. Existing portfolios: \(names.isEmpty ? "none" : names).")
            }
            return index
        }
        func positionIndex(in portfolio: Int) throws -> Int {
            let symbol = try text("symbol").uppercased()
            guard let index = portfolios[portfolio].positions.firstIndex(where: { $0.symbol.uppercased() == symbol }) else {
                throw ToolError(message: "\(portfolios[portfolio].name) has no position in \(symbol).")
            }
            return index
        }

        func currencyArgument() throws -> String? {
            guard let raw = arguments["currency"] as? String, !raw.isEmpty else { return nil }
            let code = raw.uppercased()
            guard code.count == 3 else { throw ToolError(message: "“currency” must be an ISO code such as EUR or USD.") }
            return code
        }

        switch name {
        case "list_portfolios":
            return json(portfolios.map { portfolio in
                ["name": portfolio.name, "positions": portfolio.positions.map(describe)] as [String: Any]
            })

        case "get_valuation":
            return json(try await valuation(portfolios, repository: repository))

        case "search_symbols":
            let found = try await MarketData.search(try text("query"))
            return json(found.map { ["symbol": $0.symbol, "name": $0.name, "exchange": $0.exchange, "type": $0.type] })

        case "create_portfolio":
            let title = try text("name")
            guard !portfolios.contains(where: { $0.name.caseInsensitiveCompare(title) == .orderedSame }) else {
                throw ToolError(message: "A portfolio named “\(title)” already exists.")
            }
            portfolios.append(Portfolio(name: title))
            repository.save(portfolios)
            return "Created portfolio “\(title)”."

        case "add_position":
            let index = try portfolioIndex()
            let symbol = try text("symbol").uppercased()
            guard let quantity = arguments["quantity"] as? Double, quantity > 0 else {
                throw ToolError(message: "“quantity” must be a positive number.")
            }
            guard let cost = (arguments["average_cost"] ?? arguments["average_cost_eur"]) as? Double, cost >= 0 else {
                throw ToolError(message: "“average_cost” must be a number of zero or more.")
            }
            let currency = try currencyArgument() ?? "EUR"
            // Looking the symbol up also rejects symbols that do not exist.
            guard let meta = try? await MarketData.chart(symbol, range: .day).meta else {
                throw ToolError(message: "“\(symbol)” is not a known symbol. Use search_symbols to find it.")
            }
            let display = (arguments["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? meta.name
            portfolios[index].positions.append(Position(symbol: symbol, name: display, quantity: quantity, unitCost: cost, currency: currency))
            repository.save(portfolios)
            return "Added \(quantity) × \(symbol) (\(display)) at \(cost) \(currency) to \(portfolios[index].name)."

        case "update_position":
            let index = try portfolioIndex()
            let position = try positionIndex(in: index)
            let quantity = arguments["quantity"] as? Double
            let cost = (arguments["average_cost"] ?? arguments["average_cost_eur"]) as? Double
            let currency = try currencyArgument()
            guard quantity != nil || cost != nil || currency != nil else {
                throw ToolError(message: "Give “quantity”, “average_cost” or “currency”.")
            }
            guard portfolios[index].positions[position].trades.isEmpty else {
                throw ToolError(message: "This position is derived from recorded transactions; use add_transaction.")
            }
            if let currency { portfolios[index].positions[position].currency = currency }
            if let quantity {
                guard quantity > 0 else { throw ToolError(message: "“quantity” must be positive; use remove_position to delete.") }
                portfolios[index].positions[position].quantity = quantity
            }
            if let cost {
                guard cost >= 0 else { throw ToolError(message: "“average_cost” must be zero or more.") }
                portfolios[index].positions[position].unitCost = cost
                portfolios[index].positions[position].costUnknown = false
            }
            repository.save(portfolios)
            let updated = portfolios[index].positions[position]
            return "\(updated.symbol) in \(portfolios[index].name) is now \(updated.quantity) shares at \(updated.unitCost) \(updated.currency) average cost."

        case "add_transaction":
            let index = try portfolioIndex()
            let symbol = try text("symbol").uppercased()
            guard let kind = Trade.Kind(rawValue: try text("type").lowercased()) else {
                throw ToolError(message: "“type” must be buy or sell.")
            }
            guard let quantity = arguments["quantity"] as? Double, quantity > 0 else {
                throw ToolError(message: "“quantity” must be a positive number.")
            }
            guard let price = arguments["price"] as? Double, price >= 0 else {
                throw ToolError(message: "“price” must be a number of zero or more.")
            }
            let day = try text("date")
            guard Trade.dayFormatter.date(from: day) != nil else {
                throw ToolError(message: "“date” must look like 2026-03-31.")
            }
            let trade = Trade(kind: kind, day: day, quantity: quantity, price: price)
            if let existing = portfolios[index].positions.firstIndex(where: { $0.symbol.uppercased() == symbol }) {
                var position = portfolios[index].positions[existing]
                position.record(trade)
                guard soldWithinHolding(position) else {
                    throw ToolError(message: "That sale is larger than the shares held on \(day).")
                }
                portfolios[index].positions[existing] = position
            } else {
                guard kind == .buy else { throw ToolError(message: "\(portfolios[index].name) has no position in \(symbol) to sell.") }
                guard let meta = try? await MarketData.chart(symbol, range: .day).meta else {
                    throw ToolError(message: "“\(symbol)” is not a known symbol. Use search_symbols to find it.")
                }
                portfolios[index].positions.append(Position(symbol: symbol, name: meta.name, quantity: 0, unitCost: 0,
                                                            currency: try currencyArgument() ?? "EUR", trades: [trade]))
            }
            repository.save(portfolios)
            let updated = portfolios[index].positions.first { $0.symbol.uppercased() == symbol }!
            return "Recorded. \(symbol) in \(portfolios[index].name): \(updated.quantity) shares, average cost "
                + "\(round2(updated.unitCost)) \(updated.currency), realised gain \(round2(updated.realized)) \(updated.currency)."

        case "remove_position":
            let index = try portfolioIndex()
            let position = try positionIndex(in: index)
            repository.backup(portfolios)
            let removed = portfolios[index].positions.remove(at: position)
            repository.save(portfolios)
            return "Removed \(removed.symbol) from \(portfolios[index].name)."

        default:
            throw ToolError(message: "Unknown tool “\(name)”.")
        }
    }

    private static func valuation(_ portfolios: [Portfolio], repository: PortfolioRepository) async throws -> [String: Any] {
        var seen = Set<String>()
        let symbols = portfolios.flatMap(\.positions).map(\.symbol).filter { seen.insert($0).inserted }
        MarketData.register(portfolios: portfolios)
        var meta = repository.loadMeta()
        for symbol in symbols where meta[symbol] == nil {
            if let fresh = try? await MarketData.chart(symbol, range: .day).meta { meta[symbol] = fresh }
        }
        let currencies = Set(symbols.compactMap { meta[$0]?.currency })
            .union(portfolios.flatMap(\.positions).map(\.currency)).subtracting(["EUR"])
        let quotes = try await MarketData.quotes(symbols)
        var fx: [String: Double] = ["EUR": 1]
        var fxPrevious: [String: Double] = ["EUR": 1]
        for (currency, rate) in await MarketData.rates(currencies) {
            fx[currency] = rate.now
            fxPrevious[currency] = rate.previous
        }

        var total = 0.0, totalCost = 0.0, totalGain = 0.0, totalDay = 0.0
        var output: [[String: Any]] = []
        for portfolio in portfolios {
            var value = 0.0, day = 0.0
            var rows: [[String: Any]] = []
            for position in portfolio.positions {
                var row = describe(position)
                row["transactions"] = nil
                if let quote = quotes[position.symbol], let m = meta[position.symbol], let rate = fx[m.currency] {
                    let price = quote.price * rate * m.scale
                    let positionValue = price * position.quantity
                    let positionDay = (quote.price * rate - quote.previousClose * (fxPrevious[m.currency] ?? rate))
                        * m.scale * position.quantity
                    row["price_eur"] = round2(price)
                    row["value_eur"] = round2(positionValue)
                    row["today_change_eur"] = round2(positionDay)
                    row["today_change_pct"] = round2(quote.changePct)
                    row["price_native"] = round2(quote.price * m.scale)
                    row["price_currency"] = m.currency
                    if !position.costUnknown, let costRate = fx[position.currency] {
                        let cost = position.cost * costRate
                        row["invested_eur"] = round2(cost)
                        row["gain_eur"] = round2(positionValue - cost)
                        row["gain_pct"] = cost > 0 ? round2((positionValue / cost - 1) * 100) : 0
                        totalCost += cost
                        totalGain += positionValue - cost
                    } else {
                        row["note"] = "purchase price unknown; not included in gain and invested"
                    }
                    value += positionValue
                    day += positionDay
                } else {
                    row["note"] = "no live price available"
                }
                rows.append(row)
            }
            total += value
            totalDay += day
            output.append(["name": portfolio.name, "value_eur": round2(value), "today_change_eur": round2(day),
                           "positions": rows])
        }
        return ["currency": "EUR", "total_value_eur": round2(total), "today_change_eur": round2(totalDay),
                "total_gain_eur": round2(totalGain), "invested_eur": round2(totalCost),
                "exchange_rates_eur": fx,
                "portfolios": output]
    }
}
#endif
