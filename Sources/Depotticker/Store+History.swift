// Value history of the portfolios for the overview chart.
import Foundation
import SwiftUI
import WidgetKit

extension Store {
    // MARK: Portfolio history

    static let historyRanges: [ChartRange] = [.day, .week, .month, .quarter, .half, .ytd, .year, .fiveYears]

    func historyKey(_ range: ChartRange, _ portfolioID: UUID?) -> String {
        "\(range.rawValue)|\(portfolioID?.uuidString ?? "all")"
    }

    /// How long a downloaded range stays fresh: intraday ranges move, daily ones barely do.
    func lifetime(_ range: ChartRange) -> TimeInterval {
        switch range {
        case .day: return MarketData.source.intradayLifetime
        case .week: return 600
        case .month: return 1_800
        default: return 6 * 3_600
        }
    }

    /// Downloads one range for all symbols (three small requests) and recomputes the value history of
    /// every portfolio from it, as if today's holdings had been held for the whole period.
    func loadHistory(_ range: ChartRange, force: Bool = false) async {
        let symbols = allSymbols
        guard !symbols.isEmpty, !historyInFlight.contains(range) else { return }
        if !force, let cached = seriesCache[range], Date().timeIntervalSince(cached.fetched) < lifetime(range),
           histories[historyKey(range, selectedPortfolioID)] != nil {
            return
        }
        historyInFlight.insert(range)
        defer { historyInFlight.remove(range) }
        if fx.count < 2 || meta.isEmpty { await refresh() }

        let series = await MarketData.series(symbols, range: range)
        guard series.count * 2 >= symbols.count else { return }
        seriesCache[range] = (Date(), series)
        seriesSymbols = Set(symbols)
        recomputeHistories(for: range)
        saveHistories()
    }

    func recomputeHistories(for range: ChartRange) {
        guard let series = seriesCache[range]?.series else { return }
        let filters: [UUID?] = [nil] + portfolios.map { Optional($0.id) }
        for filter in filters {
            var inputs: [PortfolioHistory.Series] = []
            for holding in holdings(in: filter) {
                guard let data = series[holding.symbol], let m = meta[holding.symbol], let rate = fx[m.currency] else { continue }
                let factor = holding.quantity * rate * m.scale
                inputs.append(.init(factor: factor, points: data.points,
                                    lead: range == .day ? data.previousClose : nil))
            }
            histories[historyKey(range, filter)] = PortfolioHistory.combine(inputs, range: range)
        }
    }

    /// Loads every range in the background so switching periods is instant.
    func preloadHistories(force: Bool = false) async {
        for range in Store.historyRanges {
            await loadHistory(range, force: force)
        }
    }

    var historiesURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Depotticker-histories.json")
    }

    func saveHistories() {
        try? JSONEncoder().encode(histories).write(to: historiesURL, options: .atomic)
    }

    func loadSavedHistories() {
        guard let data = try? Data(contentsOf: historiesURL),
              let saved = try? JSONDecoder().decode([String: [ChartPoint]].self, from: data)
        else { return }
        histories = saved
    }

    /// Holdings changed: the value histories no longer match. While the same shares are held (a
    /// changed quantity, a move between portfolios) the downloaded prices still apply and only the sums
    /// are redone; `reload` forces new downloads (another source, new ISINs).
    func invalidateHistories(reload: Bool = false) {
        histories.removeAll()
        if reload || Set(allSymbols) != seriesSymbols {
            seriesCache.removeAll()
        } else {
            for range in seriesCache.keys { recomputeHistories(for: range) }
            saveHistories()
        }
        Task { await preloadHistories() }
    }
}
