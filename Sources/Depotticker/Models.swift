import Foundation
import SwiftUI

struct Position: Codable, Identifiable, Hashable {
    var id = UUID()
    var symbol: String
    var name: String
    var quantity: Double
    /// Average purchase price per share in EUR.
    var unitCost: Double

    var cost: Double { quantity * unitCost }
}

struct Portfolio: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var positions: [Position] = []
}

struct PortfolioFile: Codable {
    var portfolios: [Portfolio]
}

/// Static-ish facts about a symbol, cached on disk so values show instantly on launch.
struct SymbolMeta: Codable, Hashable {
    var symbol: String
    var name: String
    /// ISO currency (minor units like GBp are normalised to GBP with scale 0.01).
    var currency: String
    var scale: Double
    var exchange: String
    var open: Double?
    var dayHigh: Double?
    var dayLow: Double?
    var volume: Double?
    var week52High: Double?
    var week52Low: Double?
    var previousClose: Double?
}

/// Latest price in the symbol's raw quote units (apply `SymbolMeta.scale`).
struct LiveQuote: Hashable {
    /// Regular-session price: live while the market is open, the official close afterwards.
    var price: Double
    var previousClose: Double
    var spark: [Double]
    /// Pre-market or after-hours price, when there is one. Never used for values or gains.
    var extendedPrice: Double?

    var changePct: Double {
        previousClose > 0 ? (price / previousClose - 1) * 100 : 0
    }
}

struct ChartPoint: Hashable, Codable {
    var date: Date
    var price: Double
    var volume: Double?
}

/// Today's regular trading session of a listing.
struct MarketSession: Hashable {
    var open: Date
    var close: Date

    var isOpen: Bool { (open...close).contains(Date()) }

    var status: String {
        let now = Date()
        let time = Date.FormatStyle.dateTime.hour().minute()
        if isOpen { return "Market open · closes \(close.formatted(time))" }
        if now < open { return "Market closed · opens \(open.formatted(time))" }
        return "Market closed"
    }
}

/// An extra line drawn on a chart, aligned point by point with the main series.
struct ChartComparison: Identifiable {
    var name: String
    var color: Color
    var values: [Double]
    var id: String { name }
}

struct PriceSeries {
    var points: [ChartPoint]
    var previousClose: Double?
}

struct ChartData {
    var meta: SymbolMeta
    var points: [ChartPoint]
    var previousClose: Double?
    var session: MarketSession?
}

enum ChartRange: String, CaseIterable, Identifiable {
    case day = "1D", week = "1W", month = "1M", quarter = "3M", half = "6M"
    case ytd = "YTD", year = "1Y", fiveYears = "5Y", max = "Max"

    var id: String { rawValue }

    var query: (range: String, interval: String) {
        switch self {
        case .day: return ("1d", "2m")
        case .week: return ("5d", "15m")
        case .month: return ("1mo", "1h")
        case .quarter: return ("3mo", "1d")
        case .half: return ("6mo", "1d")
        case .ytd: return ("ytd", "1d")
        case .year: return ("1y", "1d")
        case .fiveYears: return ("5y", "1wk")
        case .max: return ("max", "1mo")
        }
    }

    var axisFormat: Date.FormatStyle {
        switch self {
        case .day: return .dateTime.hour().minute()
        case .week: return .dateTime.weekday(.abbreviated).day()
        case .month, .quarter, .half, .ytd: return .dateTime.day().month(.abbreviated)
        case .year: return .dateTime.month(.abbreviated).year(.twoDigits)
        case .fiveYears, .max: return .dateTime.year()
        }
    }

    var hoverFormat: Date.FormatStyle {
        switch self {
        case .day: return .dateTime.hour().minute()
        case .week, .month: return .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        default: return .dateTime.day().month(.abbreviated).year()
        }
    }

    var label: String {
        switch self {
        case .day: return "today"
        case .week: return "past week"
        case .month: return "past month"
        case .quarter: return "past 3 months"
        case .half: return "past 6 months"
        case .ytd: return "year to date"
        case .year: return "past year"
        case .fiveYears: return "past 5 years"
        case .max: return "all time"
        }
    }
}

/// Valuation figures for a stock (empty for most funds).
struct Fundamentals: Hashable {
    var trailingPE: Double?
    var forwardPE: Double?
    var eps: Double?
    var marketCap: Double?
    var dividendYield: Double?
    var priceToBook: Double?
    var analystRating: String?
    var earningsDate: Date?
    var currency: String?
}

struct NewsItem: Identifiable, Hashable {
    var id: String
    var title: String
    var publisher: String
    var url: URL
    var date: Date
}

struct SearchResult: Identifiable, Hashable {
    var symbol: String
    var name: String
    var exchange: String
    var type: String
    var id: String { symbol }
}

/// A symbol aggregated across the visible portfolios.
struct Holding: Identifiable, Hashable {
    struct Lot: Hashable {
        var portfolioID: UUID
        var portfolioName: String
        var position: Position
    }

    var symbol: String
    var name: String
    var lots: [Lot]

    var id: String { symbol }
    var quantity: Double { lots.reduce(0) { $0 + $1.position.quantity } }
    var cost: Double { lots.reduce(0) { $0 + $1.position.cost } }
    var unitCost: Double { quantity > 0 ? cost / quantity : 0 }
}

struct Totals {
    var value = 0.0
    var cost = 0.0
    var day = 0.0
    var count = 0
    var missing = 0

    var gain: Double { value - cost }
    var gainPct: Double { cost > 0 ? gain / cost * 100 : 0 }
    var dayPct: Double {
        let start = value - day
        return start > 0 ? day / start * 100 : 0
    }
}
