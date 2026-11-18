import Foundation
import SwiftUI

/// One purchase or sale of a position.
struct Trade: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable { case buy, sell }

    var id = UUID()
    var kind: Kind
    /// Calendar day as yyyy-MM-dd; nil for a holding whose purchase date is not known.
    var day: String?
    var quantity: Double
    /// Price per share in the position's currency.
    var price: Double
    /// True when the date is a guess derived from the average cost, not a recorded purchase.
    var estimated: Bool?

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var date: Date? { day.flatMap(Trade.dayFormatter.date(from:)) }
}

extension Calendar {
    /// Trading days are counted in UTC so that a day reads the same in every time zone.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

struct Position: Codable, Identifiable, Hashable {
    var id = UUID()
    var symbol: String
    var name: String
    var quantity: Double
    /// Average purchase price per share, in `currency`.
    var unitCost: Double
    /// Currency of the purchase prices (the broker's account currency), not of the listing.
    var currency: String = "EUR"
    /// True when the broker does not report what was paid; such positions count towards value, not gains.
    var costUnknown: Bool = false
    /// Purchases and sales. When present, `quantity` and `unitCost` are derived from them.
    var trades: [Trade] = []
    /// The broker's holding-period hint, when it gives one: "long" (over a year), "short" or "mixed".
    var timeHeld: String?
    /// International Securities Identification Number; the German exchanges' data is keyed by it.
    var isin: String?

    /// Cost is known but no purchase carries a date yet.
    var needsPurchaseDate: Bool {
        !costUnknown && quantity > 0 && unitCost > 0 && trades.allSatisfy { $0.day == nil }
    }

    /// Dates entered by the user or read from a file, as opposed to estimates.
    var hasRecordedTrades: Bool { trades.contains { $0.day != nil && $0.estimated != true } }

    var cost: Double { quantity * unitCost }

    init(id: UUID = UUID(), symbol: String, name: String, quantity: Double, unitCost: Double,
         currency: String = "EUR", costUnknown: Bool = false, trades: [Trade] = [], timeHeld: String? = nil,
         isin: String? = nil) {
        self.timeHeld = timeHeld
        self.isin = isin
        self.id = id
        self.symbol = symbol
        self.name = name
        self.quantity = quantity
        self.unitCost = unitCost
        self.currency = currency
        self.costUnknown = costUnknown
        self.trades = trades
        applyTrades()
    }

    enum CodingKeys: String, CodingKey { case id, symbol, name, quantity, unitCost, currency, costUnknown, trades, timeHeld, isin }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        symbol = try c.decode(String.self, forKey: .symbol)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? symbol
        quantity = try c.decode(Double.self, forKey: .quantity)
        unitCost = try c.decodeIfPresent(Double.self, forKey: .unitCost) ?? 0
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "EUR"
        costUnknown = try c.decodeIfPresent(Bool.self, forKey: .costUnknown) ?? false
        trades = try c.decodeIfPresent([Trade].self, forKey: .trades) ?? []
        timeHeld = try c.decodeIfPresent(String.self, forKey: .timeHeld)
        isin = try c.decodeIfPresent(String.self, forKey: .isin)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(name, forKey: .name)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(unitCost, forKey: .unitCost)
        // Written only when they differ from the defaults, so plain EUR files stay as they were.
        if currency != "EUR" { try c.encode(currency, forKey: .currency) }
        if costUnknown { try c.encode(true, forKey: .costUnknown) }
        if !trades.isEmpty { try c.encode(trades, forKey: .trades) }
        try c.encodeIfPresent(timeHeld, forKey: .timeHeld)
        try c.encodeIfPresent(isin, forKey: .isin)
    }

    /// Trades in date order; undated ones (the opening holding) first.
    var orderedTrades: [Trade] {
        trades.enumerated().sorted { a, b in
            let x = a.element.day ?? "", y = b.element.day ?? ""
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }

    /// Shares, average cost and realised gain after all trades, by the average-cost method:
    /// a sale leaves the average cost of the remaining shares unchanged.
    var tradeSummary: (quantity: Double, unitCost: Double, realized: Double)? {
        guard !trades.isEmpty else { return nil }
        var shares = 0.0, cost = 0.0, realized = 0.0
        for trade in orderedTrades {
            switch trade.kind {
            case .buy:
                shares += trade.quantity
                cost += trade.quantity * trade.price
            case .sell:
                let sold = min(trade.quantity, shares)
                let average = shares > 0 ? cost / shares : 0
                realized += sold * (trade.price - average)
                cost -= sold * average
                shares -= sold
            }
        }
        if shares < 1e-9 { shares = 0; cost = 0 }
        return (shares, shares > 0 ? cost / shares : 0, realized)
    }

    var hasSales: Bool { trades.contains { $0.kind == .sell } }

    /// Profit already taken through sales, in `currency`. Nil when shares were sold out of a holding
    /// whose purchase price is unknown: the proceeds are known then, the profit is not.
    var realized: Double? {
        if costUnknown, hasSales { return nil }
        return tradeSummary?.realized ?? 0
    }

    /// Adds a trade. The first one turns the present holding into an undated opening purchase,
    /// so nothing already held is lost.
    mutating func record(_ trade: Trade) {
        if trades.isEmpty, quantity > 0 {
            trades.append(Trade(kind: .buy, day: nil, quantity: quantity, price: costUnknown ? 0 : unitCost))
        }
        trades.append(trade)
        applyTrades()
    }

    /// Brings `quantity` and `unitCost` in line with the trades.
    mutating func applyTrades() {
        guard let summary = tradeSummary else { return }
        quantity = summary.quantity
        unitCost = summary.unitCost
    }
}

struct Portfolio: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var positions: [Position] = []

    enum CodingKeys: String, CodingKey { case id, name, positions }
}

extension Portfolio {
    /// A position that cannot be read (a missing field, a wrong type) is left out instead of making
    /// the whole file unreadable; `SkippedEntries` in the decoder's `userInfo` counts them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        let entries = try c.decodeIfPresent([Lossy<Position>].self, forKey: .positions) ?? []
        positions = entries.compactMap(\.value)
        (decoder.userInfo[SkippedEntries.key] as? SkippedEntries)?.count += entries.count - positions.count
    }
}

/// Decodes to nil instead of failing.
struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Counts what a lenient decode left out.
final class SkippedEntries {
    static let key = CodingUserInfoKey(rawValue: "skippedEntries")!
    var count = 0
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

struct DailyHistory {
    var currency: String
    var points: [ChartPoint]
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

    /// The first moment the range covers, counted back from `now`; nil for the intraday range.
    func start(from now: Date = Date()) -> Date? {
        let utc = Calendar.utc
        switch self {
        case .day: return nil
        case .week: return utc.date(byAdding: .day, value: -7, to: now)
        case .month: return utc.date(byAdding: .month, value: -1, to: now)
        case .quarter: return utc.date(byAdding: .month, value: -3, to: now)
        case .half: return utc.date(byAdding: .month, value: -6, to: now)
        case .ytd: return utc.date(from: DateComponents(year: utc.component(.year, from: now), month: 1, day: 1))
        case .year: return utc.date(byAdding: .year, value: -1, to: now)
        case .fiveYears: return utc.date(byAdding: .year, value: -5, to: now)
        case .max: return .distantPast
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
    var isin: String?
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
    /// Shares whose purchase price is known.
    var costedQuantity: Double { lots.reduce(0) { $0 + ($1.position.costUnknown ? 0 : $1.position.quantity) } }
    var hasSales: Bool { lots.contains { $0.position.hasSales } }
}

struct Totals {
    var value = 0.0
    /// Amount paid for the positions whose cost is known, in EUR at today's exchange rates.
    var cost = 0.0
    /// Value minus cost of the positions whose cost is known.
    var gain = 0.0
    var day = 0.0
    var count = 0
    var missing = 0
    /// Positions without a known purchase price; they are left out of `cost` and `gain`.
    var uncosted = 0

    var gainPct: Double { cost > 0 ? gain / cost * 100 : 0 }
    var dayPct: Double {
        let start = value - day
        return start > 0 ? day / start * 100 : 0
    }
}
