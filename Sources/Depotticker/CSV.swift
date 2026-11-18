import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Import and export of positions as CSV, readable by Excel and Numbers.
enum CSVCodec {
    static let header = ["Portfolio", "Symbol", "Name", "Quantity", "Average cost (EUR)"]
    static let extraHeader = ["Price (EUR)", "Value (EUR)", "Gain (EUR)", "Gain (%)"]

    enum ImportError: LocalizedError {
        case missingColumn(String)
        case empty
        case badNumber(row: Int, column: String, text: String)

        var errorDescription: String? {
            switch self {
            case .missingColumn(let name): return "The file has no “\(name)” column. Use the template to see the expected layout."
            case .empty: return "The file contains no positions."
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

    /// `priceEUR` adds read-only value columns; they are ignored on import.
    static func export(_ portfolios: [Portfolio], priceEUR: (String) -> Double?) -> String {
        var lines = [line(header + extraHeader)]
        for portfolio in portfolios {
            for position in portfolio.positions {
                var fields = [portfolio.name, position.symbol, position.name,
                              number(position.quantity), number(position.unitCost)]
                if let price = priceEUR(position.symbol) {
                    let value = price * position.quantity
                    let gain = value - position.cost
                    fields += [number(price), number(value, decimals: 2), number(gain, decimals: 2),
                               number(position.cost > 0 ? gain / position.cost * 100 : 0, decimals: 2)]
                }
                lines.append(line(fields))
            }
        }
        // The byte-order mark makes Excel read the file as UTF-8.
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    static var template: String {
        let rows = [
            header,
            ["My Broker", "AAPL", "Apple Inc.", number(10), number(150.25)],
            ["My Broker", "SAP.DE", "SAP SE", number(5), number(120)],
            ["Second Broker", "VWCE.DE", "Vanguard FTSE All-World", number(12.5), number(98.4)],
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

        var order: [String] = []
        var grouped: [String: [Position]] = [:]
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
            let portfolio = cell(portfolioColumn).isEmpty ? "Imported" : cell(portfolioColumn)
            let name = cell(nameColumn).isEmpty ? symbol : cell(nameColumn)
            if grouped[portfolio] == nil { order.append(portfolio) }
            grouped[portfolio, default: []].append(Position(symbol: symbol, name: name, quantity: quantity, unitCost: cost))
        }
        guard !order.isEmpty else { throw ImportError.empty }
        return order.map { Portfolio(name: $0, positions: grouped[$0] ?? []) }
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
