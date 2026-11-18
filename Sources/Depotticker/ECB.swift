import Foundation

/// Euro foreign exchange reference rates of the European Central Bank: one rate per currency and
/// working day, published around 16:00 CET. Free to reuse with the source named.
enum ECB {
    private static let recentURL = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist-90d.xml")!
    private static let fullURL = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.xml")!

    /// One fixing: units of each currency per euro.
    struct Day {
        var date: Date
        var rates: [String: Double]
    }

    private actor Cache {
        private var recent: (fetched: Date, days: [Day])?
        private var full: (fetched: Date, days: [Day])?

        func recentDays() async -> [Day]? {
            if let recent, Date().timeIntervalSince(recent.fetched) < 1_800 { return recent.days }
            guard let days = await ECB.download(ECB.recentURL), !days.isEmpty else { return recent?.days }
            recent = (Date(), days)
            return days
        }

        func fullDays() async -> [Day]? {
            if let full, Date().timeIntervalSince(full.fetched) < 12 * 3_600 { return full.days }
            guard let days = await ECB.download(ECB.fullURL), !days.isEmpty else { return full?.days }
            full = (Date(), days)
            return days
        }
    }

    private static let cache = Cache()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static func download(_ url: URL) async -> [Day]? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return parse(text)
    }

    /// Reads the ECB's XML: `<Cube time="2026-11-17"><Cube currency="USD" rate="1.0989"/>…</Cube>`.
    /// Returns the days oldest first.
    static func parse(_ xml: String) -> [Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var days: [Day] = []
        for block in xml.components(separatedBy: "<Cube time=").dropFirst() {
            let quote = block.first == "'" ? "'" : "\""
            let parts = block.dropFirst().split(separator: Character(quote), maxSplits: 1)
            guard let stamp = parts.first else { continue }
            let numbers = stamp.split(separator: "-").compactMap { Int($0) }
            // Noon keeps the day stable in every time zone the app formats it in.
            guard numbers.count == 3, let date = calendar.date(from: DateComponents(
                year: numbers[0], month: numbers[1], day: numbers[2], hour: 12)) else { continue }
            var rates: [String: Double] = [:]
            for entry in block.components(separatedBy: "currency=").dropFirst() {
                let fields = entry.split(separator: Character(quote), omittingEmptySubsequences: false)
                // fields: "", USD, " rate=", 1.0989, …
                guard fields.count >= 4, let rate = Double(fields[3]), rate > 0 else { continue }
                rates[String(fields[1])] = rate
            }
            if !rates.isEmpty { days.append(Day(date: date, rates: rates)) }
        }
        return days.sorted { $0.date < $1.date }
    }

    /// EUR value of one unit of each currency at the latest fixing and the one before.
    static func latest(_ currencies: Set<String>) async -> [String: (now: Double, previous: Double)] {
        guard let days = await cache.recentDays(), let last = days.last else { return [:] }
        let before = days.count > 1 ? days[days.count - 2] : last
        var out: [String: (now: Double, previous: Double)] = [:]
        for currency in currencies {
            guard let rate = last.rates[currency] else { continue }
            out[currency] = (1 / rate, 1 / (before.rates[currency] ?? rate))
        }
        return out
    }

    /// Date of the latest fixing, for the "as of" note.
    static func latestDate() async -> Date? {
        await cache.recentDays()?.last?.date
    }

    /// Daily value of one unit of `from` expressed in `to` since 1999, oldest first.
    static func history(from: String, to: String) async -> [ChartPoint]? {
        guard let days = await cache.fullDays() else { return nil }
        let points: [ChartPoint] = days.compactMap { day in
            guard let a = from == "EUR" ? 1 : day.rates[from], let b = to == "EUR" ? 1 : day.rates[to] else { return nil }
            // a and b are units per euro: one `from` is b / a units of `to`.
            return ChartPoint(date: day.date, price: b / a)
        }
        return points.isEmpty ? nil : points
    }
}
