import Foundation

/// Estimates when a position was bought from its average purchase price, for brokers and files that
/// only report the average. The guess is the most recent day the share closed at that price, so it is
/// the latest possible single purchase date; positions built up over time were partly bought earlier.
enum PurchaseEstimator {
    private actor Cache {
        private var histories: [String: DailyHistory] = [:]

        func history(_ symbol: String) async -> DailyHistory? {
            if let known = histories[symbol] { return known }
            guard let fresh = try? await MarketData.dailyHistory(symbol) else { return nil }
            histories[symbol] = fresh
            return fresh
        }
    }

    private static let cache = Cache()

    /// Daily closes of `symbol` converted into `currency`, oldest first.
    private static func closes(_ symbol: String, in currency: String) async -> [ChartPoint]? {
        guard let history = await cache.history(symbol) else { return nil }
        guard history.currency != currency else { return history.points }
        guard let rates = await MarketData.rateHistory(from: history.currency, to: currency), !rates.isEmpty else { return nil }
        var converted: [ChartPoint] = []
        var index = 0
        for point in history.points {
            while index + 1 < rates.count, rates[index + 1].date <= point.date { index += 1 }
            // Before the first known rate there is nothing to convert with.
            guard rates[index].date <= point.date.addingTimeInterval(86_400) else { continue }
            converted.append(ChartPoint(date: point.date, price: point.price * rates[index].price))
        }
        return converted
    }

    enum Style: String {
        /// One purchase per position, on the most recent day the share traded at the average price.
        case single
        /// Equal purchases once a year, going back as many years as it takes to arrive at the average price.
        case yearly
    }

    /// `timeHeld` narrows the search: "short" means bought within the last year, "long" before that.
    /// `before` only accepts days up to that date; `crossingOnly` gives up when the price never
    /// passed through the average cost there.
    static func estimateDay(symbol: String, unitCost: Double, currency: String, timeHeld: String?,
                            before: Date? = nil, crossingOnly: Bool = false) async -> String? {
        guard unitCost > 0, let points = await closes(symbol, in: currency), points.count > 1 else { return nil }
        let yearAgo = Date().addingTimeInterval(-365 * 86_400)
        let limit = before ?? .distantFuture
        let window: (ChartPoint) -> Bool
        switch timeHeld {
        case "short": window = { $0.date >= yearAgo && $0.date <= limit }
        case "long": window = { $0.date < yearAgo && $0.date <= limit }
        default: window = { $0.date <= limit }
        }
        func search(_ allowed: (ChartPoint) -> Bool) -> Date? {
            // Most recent day on which the price passed through the average cost.
            for i in stride(from: points.count - 1, to: 0, by: -1) where allowed(points[i]) {
                let before = points[i - 1].price - unitCost, after = points[i].price - unitCost
                if before * after <= 0 {
                    return abs(before) < abs(after) && allowed(points[i - 1]) ? points[i - 1].date : points[i].date
                }
            }
            if crossingOnly { return nil }
            // Never traded there in the window: the day it came closest.
            return points.filter(allowed).min { abs($0.price - unitCost) < abs($1.price - unitCost) }?.date
        }
        guard let date = search(window) ?? (crossingOnly ? nil : search({ $0.date <= limit })) else { return nil }
        return Trade.dayFormatter.string(from: date)
    }

    /// Equal yearly purchases ending at `end` whose prices average the position's cost. The number of
    /// years is the smallest whose market prices explain the average (within 5 %, at most 10 %); the prices are then
    /// scaled by that small remainder so that the total paid is exactly quantity × average cost.
    static func yearlyLots(symbol: String, quantity: Double, unitCost: Double, currency: String,
                           end: Date) async -> [Trade]? {
        guard unitCost > 0, quantity > 0, let points = await closes(symbol, in: currency), points.count > 1 else { return nil }
        func close(on date: Date) -> ChartPoint? {
            guard let first = points.first, date >= first.date else { return nil }
            var low = 0, high = points.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if points[middle].date <= date { low = middle } else { high = middle - 1 }
            }
            return points[low]
        }
        let calendar = Calendar(identifier: .gregorian)
        let whole = quantity == quantity.rounded()
        var lots: [ChartPoint] = []
        var best: (count: Int, error: Double)?
        for year in 0..<40 {
            guard let date = calendar.date(byAdding: .year, value: -year, to: end), let point = close(on: date) else { break }
            lots.append(point)
            if whole, Double(lots.count) > quantity { break }
            let mean = lots.reduce(0) { $0 + $1.price } / Double(lots.count)
            let error = abs(mean / unitCost - 1)
            if best == nil || error < best!.error - 1e-9 { best = (lots.count, error) }
            // The fewest purchases that explain the average are the simplest guess.
            if error <= 0.05 {
                best = (lots.count, error)
                break
            }
        }
        // A single purchase is better dated by the day the share actually traded at that price.
        guard let best, best.error <= 0.10, best.count > 1 else { return nil }
        let chosen = Array(lots.prefix(best.count).reversed())   // oldest first
        var shares: [Double] = []
        if whole {
            let base = (quantity / Double(best.count)).rounded(.down)
            var extra = Int(quantity - base * Double(best.count))
            for _ in chosen {
                shares.append(base + (extra > 0 ? 1 : 0))
                extra -= 1
            }
        } else {
            let part = (quantity / Double(best.count) * 10_000).rounded() / 10_000
            shares = Array(repeating: part, count: best.count)
            shares[best.count - 1] = quantity - part * Double(best.count - 1)
        }
        let paid = zip(shares, chosen).reduce(0) { $0 + $1.0 * $1.1.price }
        guard paid > 0 else { return nil }
        let factor = quantity * unitCost / paid
        return zip(shares, chosen).map { amount, point in
            Trade(kind: .buy, day: Trade.dayFormatter.string(from: point.date), quantity: amount,
                  price: point.price * factor, estimated: true)
        }
    }

    /// Gives every position that has a known cost but no purchase date estimated purchases.
    /// Quantities, costs and values do not change. `portfolio` limits the work to one depot;
    /// `before` says the purchases happened up to that date where the prices allow it.
    static func fillMissingDates(in portfolios: [Portfolio], style: Style = .single, portfolio only: String? = nil,
                                 before: Date? = nil) async -> (portfolios: [Portfolio], estimated: Int) {
        var result = portfolios
        var count = 0
        let recent = Date().addingTimeInterval(-182 * 86_400)
        for p in result.indices where only == nil || result[p].name.caseInsensitiveCompare(only!) == .orderedSame {
            for i in result[p].positions.indices {
                let position = result[p].positions[i]
                guard position.needsPurchaseDate else { continue }
                func single(_ price: Double, before: Date? = nil, crossingOnly: Bool = false) async -> String? {
                    await estimateDay(symbol: position.symbol, unitCost: price, currency: position.currency,
                                      timeHeld: position.timeHeld, before: before, crossingOnly: crossingOnly)
                }
                func yearly(end: Date) async -> [Trade]? {
                    await yearlyLots(symbol: position.symbol, quantity: position.quantity, unitCost: position.unitCost,
                                     currency: position.currency, end: end)
                }
                if !position.trades.isEmpty {
                    // Several purchases at different prices: date each one from its own price.
                    var dated = false
                    for t in position.trades.indices where position.trades[t].kind == .buy {
                        guard let day = await single(position.trades[t].price, before: before) else { continue }
                        result[p].positions[i].trades[t].day = day
                        result[p].positions[i].trades[t].estimated = true
                        dated = true
                    }
                    guard dated else { continue }
                } else {
                    var trades: [Trade]?
                    // The broker's "short" or "long" already says it was not built up over the years.
                    let spread = style == .yearly && position.timeHeld != "short" && position.timeHeld != "long"
                    if spread, let before { trades = await yearly(end: before) }
                    if trades == nil, let before, let day = await single(position.unitCost, before: before, crossingOnly: true) {
                        trades = [Trade(kind: .buy, day: day, quantity: position.quantity, price: position.unitCost, estimated: true)]
                    }
                    if trades == nil, spread { trades = await yearly(end: recent) }
                    if trades == nil, let day = await single(position.unitCost) {
                        trades = [Trade(kind: .buy, day: day, quantity: position.quantity, price: position.unitCost, estimated: true)]
                    }
                    guard let trades else { continue }
                    result[p].positions[i].trades = trades
                    // Keep the broker's average to the last digit.
                    result[p].positions[i].quantity = position.quantity
                    result[p].positions[i].unitCost = position.unitCost
                }
                count += 1
            }
        }
        return (result, count)
    }
}
