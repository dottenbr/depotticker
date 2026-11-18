import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Combines imported portfolios with the existing ones. Used by the app and by `Depotticker --import`.
enum PortfolioMerge {
    struct Outcome {
        var portfolios: [Portfolio]
        var added = 0
        var updated = 0
        /// Positions left alone because their figures come from recorded trades.
        var kept = 0
    }

    /// Without `replacing`, positions go into the portfolio of the same name: a symbol already held
    /// there is updated to the imported quantity and cost (so importing a fresh broker export does not
    /// create duplicates), anything else is added.
    static func merge(_ imported: [Portfolio], into existing: [Portfolio], replacing: Bool) -> Outcome {
        if replacing {
            return Outcome(portfolios: imported, added: imported.reduce(0) { $0 + $1.positions.count })
        }
        var outcome = Outcome(portfolios: existing)
        for incoming in imported {
            guard let index = outcome.portfolios.firstIndex(where: {
                $0.name.caseInsensitiveCompare(incoming.name) == .orderedSame
            }) else {
                outcome.portfolios.append(incoming)
                outcome.added += incoming.positions.count
                continue
            }
            for position in incoming.positions {
                let matches = outcome.portfolios[index].positions.indices.filter {
                    outcome.portfolios[index].positions[$0].symbol == position.symbol
                }
                if matches.count == 1, let match = matches.first {
                    // Purchases the user recorded are only replaced by a file that brings its own.
                    if !outcome.portfolios[index].positions[match].hasRecordedTrades || !position.trades.isEmpty {
                        var fresh = position
                        fresh.id = outcome.portfolios[index].positions[match].id
                        // A file without an ISIN column must not wipe an ISIN already known.
                        if (fresh.isin ?? "").isEmpty { fresh.isin = outcome.portfolios[index].positions[match].isin }
                        outcome.portfolios[index].positions[match] = fresh
                        outcome.updated += 1
                    } else {
                        outcome.kept += 1
                    }
                } else {
                    outcome.portfolios[index].positions.append(position)
                    outcome.added += 1
                }
            }
        }
        return outcome
    }
}

/// Import and export of positions as CSV, readable by Excel and Numbers.
enum CSVCodec {
    static let header = ["Portfolio", "Symbol", "Name", "Quantity", "Average cost", "Currency", "Date", "Type", "ISIN"]
    static let extraHeader = ["Price (EUR)", "Value (EUR)", "Gain (EUR)", "Gain (%)"]

    enum ImportError: LocalizedError {
        case missingColumn(String)
        case empty
        case badNumber(row: Int, column: String, text: String)
        case badDate(row: Int, text: String)

        var errorDescription: String? {
            switch self {
            case .missingColumn(let name): return "The file has no “\(name)” column. Use the template to see the expected layout."
            case .empty: return "The file contains no positions."
            case .badDate(let row, let text):
                return "Row \(row): “\(text)” is not a date. Write dates like 2026-03-31 or 31.03.2026."
            case .badNumber(let row, let column, let text):
                return "Row \(row): “\(text)” in column “\(column)” is not a number."
            }
        }
    }

    /// Semicolon-separated in regions that use a decimal comma (as Excel expects there), otherwise comma-separated.
    private static var usesDecimalComma: Bool { Locale.current.decimalSeparator == "," }
    private static var delimiter: String { usesDecimalComma ? ";" : "," }

    private static func number(_ value: Double, decimals: Int = 4) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return usesDecimalComma ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    private static func field(_ text: String) -> String {
        guard text.contains(where: { ";,\"\n\r".contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func line(_ fields: [String]) -> String {
        fields.map(field).joined(separator: delimiter)
    }

    /// `priceEUR` and `rateEUR` (EUR per unit of a currency) add read-only value columns; they are
    /// ignored on import. An empty average cost means the purchase price is not known.
    static func export(_ portfolios: [Portfolio], priceEUR: (String) -> Double?,
                       rateEUR: (String) -> Double?) -> String {
        var lines = [line(header + extraHeader)]
        for portfolio in portfolios {
            for position in portfolio.positions {
                var fields = [portfolio.name, position.symbol, position.name, number(position.quantity),
                              position.costUnknown ? "" : number(position.unitCost), position.currency, "", "",
                              position.isin ?? ""]
                // A position with purchases and sales is written as one row per entry.
                let trades = position.orderedTrades
                if let first = trades.first {
                    fields = tradeFields(first, portfolio: portfolio, position: position)
                }
                defer {
                    for trade in trades.dropFirst() {
                        lines.append(line(tradeFields(trade, portfolio: portfolio, position: position)))
                    }
                }
                if let price = priceEUR(position.symbol) {
                    let value = price * position.quantity
                    fields += [number(price), number(value, decimals: 2)]
                    if !position.costUnknown, let rate = rateEUR(position.currency) {
                        let cost = position.cost * rate
                        fields += [number(value - cost, decimals: 2),
                                   number(cost > 0 ? (value / cost - 1) * 100 : 0, decimals: 2)]
                    }
                }
                lines.append(line(fields))
            }
        }
        // The byte-order mark makes Excel read the file as UTF-8.
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func tradeFields(_ trade: Trade, portfolio: Portfolio, position: Position) -> [String] {
        [portfolio.name, position.symbol, position.name, number(trade.quantity),
         position.costUnknown && trade.day == nil ? "" : number(trade.price), position.currency,
         trade.day ?? "", (trade.kind == .buy ? "Buy" : "Sell") + (trade.estimated == true ? " (estimated)" : ""),
         position.isin ?? ""]
    }

    /// Reads 2026-03-31, 31.03.2026 and 3/31/2026 (US order when written with slashes).
    static func parseDay(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        for format in ["yyyy-MM-dd", "dd.MM.yyyy", "d.M.yyyy", "dd.MM.yy", "MM/dd/yyyy", "M/d/yyyy", "M/d/yy"] {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: text), date <= Date().addingTimeInterval(86_400) {
                return Trade.dayFormatter.string(from: date)
            }
        }
        return nil
    }

    static var template: String {
        let rows = [
            header,
            ["My Broker", "SAP.DE", "SAP SE", number(5), number(120), "EUR", "", "", "DE0007164600"],
            ["My Broker", "AAPL", "Apple Inc.", number(10), number(150.25), "EUR", "2023-03-14", "Buy", "US0378331005"],
            ["My Broker", "AAPL", "Apple Inc.", number(6), number(172.4), "EUR", "2024-08-02", "Buy", "US0378331005"],
            ["My Broker", "AAPL", "Apple Inc.", number(4), number(210), "EUR", "2025-05-20", "Sell", "US0378331005"],
            ["US Broker", "VTI", "Vanguard Total Stock Market ETF", number(12.5), number(240.1), "USD", "", "", ""],
        ]
        return "\u{FEFF}" + rows.map(line).joined(separator: "\r\n") + "\r\n"
    }

    static func parse(_ text: String) throws -> [Portfolio] {
        let cleaned = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        let firstLine = cleaned.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let separator: Character = [";", "\t", ","].max { a, b in
            firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
        } ?? ","
        let rows = records(cleaned, separator: separator).filter { row in row.contains { !$0.isEmpty } }
        guard let head = rows.first else { throw ImportError.empty }
        if isRaymondJames(head) { return try parseRaymondJames(rows) }

        func column(_ names: [String]) -> Int? {
            head.firstIndex { cell in
                let key = cell.lowercased().trimmingCharacters(in: .whitespaces)
                return names.contains { key.hasPrefix($0) }
            }
        }
        guard let symbolColumn = column(["symbol", "ticker"]) else { throw ImportError.missingColumn("Symbol") }
        guard let quantityColumn = column(["quantity", "shares", "stück", "anzahl"]) else {
            throw ImportError.missingColumn("Quantity")
        }
        let portfolioColumn = column(["portfolio", "depot", "broker"])
        let nameColumn = column(["name"])
        let costColumn = column(["average cost", "cost", "kaufkurs", "unit cost"])
        let currencyColumn = column(["currency", "währung"])

        let dateColumn = column(["date", "datum", "kaufdatum"])
        let typeColumn = column(["type", "typ", "art", "transaction"])
        let isinColumn = column(["isin"])

        // Rows of the same portfolio and symbol are purchases and sales of one position.
        struct Row { var quantity: Double; var price: Double; var priceGiven: Bool; var day: String?; var kind: Trade.Kind; var estimated: Bool }
        struct Key: Hashable { var portfolio: String; var symbol: String }
        var portfolioOrder: [String] = []
        var keyOrder: [Key] = []
        var rowsByKey: [Key: [Row]] = [:]
        var names: [Key: String] = [:]
        var currencies: [Key: String] = [:]
        var isins: [Key: String] = [:]
        for (index, row) in rows.dropFirst().enumerated() {
            func cell(_ column: Int?) -> String {
                guard let column, column < row.count else { return "" }
                return row[column].trimmingCharacters(in: .whitespaces)
            }
            let symbol = cell(symbolColumn).uppercased()
            guard !symbol.isEmpty else { continue }
            guard let quantity = parseNumber(cell(quantityColumn), separator: separator) else {
                throw ImportError.badNumber(row: index + 2, column: "Quantity", text: cell(quantityColumn))
            }
            let costText = cell(costColumn)
            guard let cost = costText.isEmpty ? 0 : parseNumber(costText, separator: separator) else {
                throw ImportError.badNumber(row: index + 2, column: "Average cost", text: costText)
            }
            let dateText = cell(dateColumn)
            let day = parseDay(dateText)
            if !dateText.isEmpty, day == nil { throw ImportError.badDate(row: index + 2, text: dateText) }
            let typeText = cell(typeColumn).lowercased()
            let kind: Trade.Kind = ["sell", "sold", "verkauf", "sale"].contains { typeText.hasPrefix($0) } ? .sell : .buy
            let currencyText = cell(currencyColumn).uppercased()
            let portfolio = cell(portfolioColumn).isEmpty ? "Imported" : cell(portfolioColumn)
            let key = Key(portfolio: portfolio, symbol: symbol)
            if !portfolioOrder.contains(portfolio) { portfolioOrder.append(portfolio) }
            if rowsByKey[key] == nil { keyOrder.append(key) }
            rowsByKey[key, default: []].append(Row(quantity: quantity, price: cost,
                                                   priceGiven: !(costText.isEmpty && costColumn != nil),
                                                   day: day, kind: kind, estimated: typeText.contains("estimated")))
            if names[key] == nil { names[key] = cell(nameColumn).isEmpty ? symbol : cell(nameColumn) }
            if currencies[key] == nil, currencyText.count == 3 { currencies[key] = currencyText }
            let isinText = cell(isinColumn).uppercased()
            if isins[key] == nil, Instruments.looksLikeISIN(isinText) { isins[key] = isinText }
        }
        guard !keyOrder.isEmpty else { throw ImportError.empty }
        var grouped: [String: [Position]] = [:]
        for key in keyOrder {
            let entries = rowsByKey[key] ?? []
            let currency = currencies[key] ?? "EUR"
            let name = names[key] ?? key.symbol
            if entries.count == 1, let only = entries.first, only.day == nil, only.kind == .buy {
                grouped[key.portfolio, default: []].append(
                    Position(symbol: key.symbol, name: name, quantity: only.quantity, unitCost: only.price,
                             currency: currency, costUnknown: !only.priceGiven, isin: isins[key]))
            } else {
                let trades = entries.map {
                    Trade(kind: $0.kind, day: $0.day, quantity: $0.quantity, price: $0.price,
                          estimated: $0.estimated ? true : nil)
                }
                grouped[key.portfolio, default: []].append(
                    Position(symbol: key.symbol, name: name, quantity: 0, unitCost: 0, currency: currency,
                             costUnknown: entries.contains { $0.kind == .buy && !$0.priceGiven }, trades: trades,
                             isin: isins[key]))
            }
        }
        return portfolioOrder.map { Portfolio(name: $0, positions: grouped[$0] ?? []) }
    }

    // MARK: Raymond James

    /// The "Export Data" file of Raymond James Client Access (Portfolio › Value).
    static let raymondJamesName = "Raymond James"

    private static func isRaymondJames(_ head: [String]) -> Bool {
        let keys = head.map { $0.lowercased() }
        return keys.contains("symbol/cusip") && keys.contains { $0.hasPrefix("amount invested / unit") }
    }

    /// Amounts are US dollars in US notation: "$4,161.62", losses as "($487.14)".
    static func parseDollar(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let negative = text.hasPrefix("(") && text.hasSuffix(")")
        text = text.filter { !"$,() ".contains($0) }
        guard let value = Double(text) else { return nil }
        return negative ? -value : value
    }

    private static func parseRaymondJames(_ rows: [[String]]) throws -> [Portfolio] {
        let head = rows[0].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func column(_ prefix: String) -> Int? { head.firstIndex { $0.hasPrefix(prefix) } }
        guard let symbolColumn = column("symbol/cusip") else { throw ImportError.missingColumn("SYMBOL/CUSIP") }
        guard let quantityColumn = column("quantity") else { throw ImportError.missingColumn("Quantity") }
        let nameColumn = column("description")
        let costColumn = column("amount invested / unit")
        let heldColumn = column("time held")

        var positions: [Position] = []
        for (index, row) in rows.dropFirst().enumerated() {
            func cell(_ column: Int?) -> String {
                guard let column, column < row.count else { return "" }
                return row[column].trimmingCharacters(in: .whitespaces)
            }
            // Yahoo writes share classes with a dash (BRK.B is BRK-B).
            let symbol = cell(symbolColumn).uppercased().replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: "/", with: "-")
            guard !symbol.isEmpty, symbol != "TOTAL" else { continue }
            guard let quantity = parseDollar(cell(quantityColumn)) else {
                throw ImportError.badNumber(row: index + 2, column: "Quantity", text: cell(quantityColumn))
            }
            guard quantity > 0 else { continue }
            // Raymond James leaves the cost empty for shares transferred in without a purchase record.
            let costText = cell(costColumn)
            let cost = parseDollar(costText)
            if !costText.isEmpty, cost == nil {
                throw ImportError.badNumber(row: index + 2, column: "Amount Invested / Unit", text: costText)
            }
            let name = cell(nameColumn).isEmpty ? symbol : cell(nameColumn).capitalized
            positions.append(Position(symbol: symbol, name: name, quantity: quantity, unitCost: cost ?? 0,
                                      currency: "USD", costUnknown: cost == nil,
                                      timeHeld: cell(heldColumn).isEmpty ? nil : cell(heldColumn).lowercased()))
        }
        guard !positions.isEmpty else { throw ImportError.empty }
        return [Portfolio(name: raymondJamesName, positions: positions)]
    }

    /// Reads file contents as UTF-8, or as Windows Latin-1 (Excel and several brokers) when it is not.
    static func text(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// Accepts both "1.234,56" and "1,234.56" as well as plain "1234.56".
    static func parseNumber(_ raw: String, separator: Character) -> Double? {
        var text = raw.filter { !$0.isWhitespace && $0 != "€" && $0 != "'" }
        guard !text.isEmpty else { return nil }
        let lastDot = text.lastIndex(of: "."), lastComma = text.lastIndex(of: ",")
        switch (lastDot, lastComma) {
        case let (dot?, comma?):
            if comma > dot {
                text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                text = text.replacingOccurrences(of: ",", with: "")
            }
        case (nil, _?):
            text = text.replacingOccurrences(of: ",", with: ".")
        default:
            break
        }
        return Double(text)
    }

    /// Splits CSV text into records, honouring quoted fields.
    private static func records(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var current = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending = iterator.next()
        while let character = pending {
            pending = iterator.next()
            if quoted {
                if character == "\"" {
                    if pending == "\"" {
                        current.append("\"")
                        pending = iterator.next()
                    } else {
                        quoted = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == separator {
                row.append(current)
                current = ""
            } else if character.isNewline {
                row.append(current)
                rows.append(row)
                row = []
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty || !row.isEmpty {
            row.append(current)
            rows.append(row)
        }
        return rows
    }
}

/// Wraps CSV text for the system save dialog.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
