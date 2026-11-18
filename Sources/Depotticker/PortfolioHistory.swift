import Foundation

/// Combines per-symbol price series into one value series, like an index of the current holdings.
enum PortfolioHistory {
    struct Series {
        /// Shares held multiplied by the EUR rate of the listing currency.
        var factor: Double
        var points: [ChartPoint]
        /// Price to assume before the first point (previous close on the 1D range).
        var lead: Double?
    }

    static func bucketSize(_ range: ChartRange) -> Double {
        switch range {
        case .day: return 300
        case .week: return 900
        case .month: return 3_600
        case .quarter, .half, .ytd, .year: return 86_400
        case .fiveYears: return 604_800
        case .max: return 2_629_800
        }
    }

    /// Markets trade at different hours, so prices are bucketed on a common time grid and the
    /// last known price of each symbol is carried forward.
    static func combine(_ series: [Series], range: ChartRange) -> [ChartPoint] {
        let size = bucketSize(range)
        var keys = Set<Int>()
        var maps: [[Int: Double]] = []
        for item in series {
            var map: [Int: Double] = [:]
            for point in item.points {
                let key = Int(point.date.timeIntervalSince1970 / size)
                map[key] = point.price
                keys.insert(key)
            }
            maps.append(map)
        }
        var last: [Double?] = series.map { $0.lead ?? $0.points.first?.price }
        var result: [ChartPoint] = []
        for key in keys.sorted() {
            var total = 0.0
            for index in series.indices {
                if let price = maps[index][key] { last[index] = price }
                if let price = last[index] { total += price * series[index].factor }
            }
            result.append(ChartPoint(date: Date(timeIntervalSince1970: Double(key) * size), price: total))
        }
        return result
    }
}
