import Foundation

/// The exchanges' free files have no history and only cover shares traded on Xetra, Frankfurt and
/// Tradegate. A second source, chosen by the user, can fill both gaps: it prices the shares the
/// exchanges do not list and supplies the closes from before the app started collecting its own.
extension MarketData {
    /// Symbols that are currently priced by the second source instead of the exchanges.
    static var supplemented: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return supplementedSet
    }

    /// Which of `symbols` the exchanges cannot price: no ISIN, or not traded there in the last days.
    /// Empty while the exchanges' files are still being read, so nothing changes hands too early.
    static func gaps(_ symbols: [String]) async -> Set<String> {
        guard config.fill != nil else { return [] }
        let coverage = await DeutscheBoerse.coverage(symbols)
        let out = Set(symbols.filter { isin(for: $0) == nil || (coverage.settled && !coverage.found.contains($0)) })
        record(asked: symbols, supplemented: out)
        return out
    }

    private static func record(asked: [String], supplemented: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        supplementedSet.subtract(asked)
        supplementedSet.formUnion(supplemented)
    }

    // MARK: History

    private actor HistoryCache {
        private var known: [String: (fetched: Date, history: DailyHistory)] = [:]
        private var running: [String: Task<DailyHistory?, Never>] = [:]

        func history(_ symbol: String, from source: DataSource) async -> DailyHistory? {
            let key = source.rawValue + "|" + symbol
            if let hit = known[key], Date().timeIntervalSince(hit.fetched) < 6 * 3_600 { return hit.history }
            if let task = running[key] { return await task.value }
            let task = Task { try? await MarketData.dailyHistory(symbol, from: source) }
            running[key] = task
            let fresh = await task.value
            running[key] = nil
            if let fresh { known[key] = (Date(), fresh) }
            return fresh ?? known[key]?.history
        }
    }

    private static let historyCache = HistoryCache()

    /// Joins the second source's closes to the ones collected from the exchange. `older` is
    /// converted into the exchange's currency with `rates` (value of one unit of its currency, oldest
    /// first) when the two differ. Returns nil when the two do not fit together: a gap of more than a
    /// fifth at the joint means they are not the same share (another share class, a different ratio).
    static func join(older: [ChartPoint], rates: [ChartPoint]?, own: [ChartPoint]) -> [ChartPoint]? {
        var converted = older
        if let rates {
            guard !rates.isEmpty else { return nil }
            converted = []
            var index = 0
            for point in older {
                while index + 1 < rates.count, rates[index + 1].date <= point.date { index += 1 }
                guard rates[index].date <= point.date.addingTimeInterval(86_400) else { continue }
                converted.append(ChartPoint(date: point.date, price: point.price * rates[index].price))
            }
        }
        guard let first = own.first else { return converted.isEmpty ? nil : converted }
        let calendar = Calendar.utc
        let cut = calendar.startOfDay(for: first.date)
        if let last = converted.last(where: { $0.date < cut }), abs(last.price / first.price - 1) > 0.2 { return nil }
        // The exchange's own close wins on every day it has one; days the app was not running are
        // taken from the second source.
        let ownDays = Set(own.map { calendar.startOfDay(for: $0.date) })
        let end = own.last?.date ?? first.date
        let gaps = converted.filter { $0.date < end && !ownDays.contains(calendar.startOfDay(for: $0.date)) }
        return (gaps + own).sorted { $0.date < $1.date }
    }

    /// Daily closes of a share the exchanges price: the second source's history up to the day the app
    /// started collecting, the exchange's own closes from then on. In the exchange's currency.
    static func filledHistory(_ symbol: String, fill: DataSource) async -> DailyHistory? {
        guard let own = await DeutscheBoerse.collected(symbol) else { return nil }
        guard let old = await historyCache.history(symbol, from: fill) else { return nil }
        var rates: [ChartPoint]?
        if old.currency != own.currency {
            guard let table = await ECB.history(from: old.currency, to: own.currency) else { return nil }
            rates = table
        }
        guard let points = join(older: old.points, rates: rates, own: own.points) else { return nil }
        return DailyHistory(currency: own.currency, points: points)
    }

    /// The part of a daily history that a chart range shows, with the close before it.
    static func slice(_ points: [ChartPoint], range: ChartRange) -> PriceSeries? {
        guard let start = range.start() else { return nil }
        let shown = points.filter { $0.date >= start }
        guard shown.count > 1 else { return nil }
        return PriceSeries(points: shown, previousClose: points.last { $0.date < start }?.price)
    }

    /// Longer ranges for shares the exchanges price, at most four downloads at a time.
    static func filledSeries(_ symbols: [String], range: ChartRange, fill: DataSource) async -> [String: PriceSeries] {
        let found = await each(symbols, limit: 4) { symbol -> PriceSeries? in
            guard let history = await filledHistory(symbol, fill: fill) else { return nil }
            return slice(history.points, range: range)
        }
        return Dictionary(found, uniquingKeysWith: { first, _ in first })
    }
}
