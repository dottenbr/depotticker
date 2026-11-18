import SwiftUI
import WidgetKit

// MARK: Data

struct WidgetPortfolio: Codable, Hashable {
    var name: String
    var value: Double
    var day: Double
    var dayPct: Double
}

struct WidgetMover: Codable, Hashable {
    var symbol: String
    var name: String
    var pct: Double
}

struct DepotEntry: TimelineEntry, Codable {
    var date: Date
    var value: Double
    var cost: Double
    var gain: Double
    var day: Double
    var portfolios: [WidgetPortfolio]
    var movers: [WidgetMover]

    var dayPct: Double {
        let start = value - day
        return start > 0 ? day / start * 100 : 0
    }
    var gainPct: Double { cost > 0 ? gain / cost * 100 : 0 }

    static let placeholder = DepotEntry(
        date: Date(), value: 125_480, cost: 98_000, gain: 27_480, day: 842,
        portfolios: [
            WidgetPortfolio(name: "Broker A", value: 80_300, day: 610, dayPct: 0.77),
            WidgetPortfolio(name: "Broker B", value: 45_180, day: 232, dayPct: 0.52),
        ],
        movers: [
            WidgetMover(symbol: "AAA", name: "Example One", pct: 3.4),
            WidgetMover(symbol: "BBB", name: "Example Two", pct: -2.1),
            WidgetMover(symbol: "CCC", name: "Example Three", pct: 1.8),
            WidgetMover(symbol: "DDD", name: "Example Four", pct: -1.2),
        ]
    )
}

enum WidgetData {
    private static let cacheKey = "lastEntry"

    /// The app's data folder in the real home directory (the widget itself is sandboxed).
    private static var directory: URL {
        // App Store builds share an app-group container with the app.
        if let group = Bundle.main.object(forInfoDictionaryKey: "DepotAppGroup") as? String, !group.isEmpty,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return container.appendingPathComponent("Depotticker")
        }
        let home = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Depotticker")
    }

    static var cached: DepotEntry? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(DepotEntry.self, from: data)
    }

    static func load() async -> DepotEntry? {
        guard let fileData = try? Data(contentsOf: directory.appendingPathComponent("portfolios.json")),
              let file = try? JSONDecoder().decode(PortfolioFile.self, from: fileData),
              let metaData = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
              let meta = try? JSONDecoder().decode([String: SymbolMeta].self, from: metaData)
        else { return cached }

        var seen = Set<String>()
        let symbols = file.portfolios.flatMap(\.positions).map(\.symbol).filter { seen.insert($0).inserted }
        guard !symbols.isEmpty else { return cached }
        let currencies = Set(symbols.compactMap { meta[$0]?.currency })
            .union(file.portfolios.flatMap(\.positions).map(\.currency)).subtracting(["EUR"])
        let all = symbols + currencies.map { "\($0)EUR=X" }
        let batches = stride(from: 0, to: all.count, by: Yahoo.batchSize).map {
            Array(all[$0..<min($0 + Yahoo.batchSize, all.count)])
        }

        var quotes: [String: LiveQuote] = [:]
        await withTaskGroup(of: [String: LiveQuote].self) { group in
            for batch in batches {
                group.addTask { (try? await Yahoo.spark(batch)) ?? [:] }
            }
            for await result in group { quotes.merge(result) { _, new in new } }
        }
        guard !quotes.isEmpty else { return cached }

        var fx: [String: Double] = ["EUR": 1]
        var fxPrevious: [String: Double] = ["EUR": 1]
        for currency in currencies {
            if let quote = quotes["\(currency)EUR=X"] {
                fx[currency] = quote.price
                fxPrevious[currency] = quote.previousClose
            }
        }

        var entry = DepotEntry(date: Date(), value: 0, cost: 0, gain: 0, day: 0, portfolios: [], movers: [])
        for portfolio in file.portfolios {
            var summary = WidgetPortfolio(name: portfolio.name, value: 0, day: 0, dayPct: 0)
            for position in portfolio.positions {
                guard let quote = quotes[position.symbol], let m = meta[position.symbol],
                      let rate = fx[m.currency]
                else { continue }
                let factor = m.scale * position.quantity
                summary.value += quote.price * rate * factor
                summary.day += (quote.price * rate - quote.previousClose * (fxPrevious[m.currency] ?? rate)) * factor
                if !position.costUnknown, let costRate = fx[position.currency] {
                    entry.cost += position.cost * costRate
                    entry.gain += quote.price * rate * factor - position.cost * costRate
                }
            }
            let start = summary.value - summary.day
            summary.dayPct = start > 0 ? summary.day / start * 100 : 0
            entry.value += summary.value
            entry.day += summary.day
            entry.portfolios.append(summary)
        }
        entry.movers = symbols
            .compactMap { symbol in
                quotes[symbol].map {
                    WidgetMover(symbol: symbol, name: meta[symbol]?.name ?? symbol, pct: $0.changePct)
                }
            }
            .sorted { abs($0.pct) > abs($1.pct) }
            .prefix(8)
            .map { $0 }

        if let data = try? JSONEncoder().encode(entry) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        return entry
    }
}

struct DepotProvider: TimelineProvider {
    func placeholder(in context: Context) -> DepotEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (DepotEntry) -> Void) {
        if context.isPreview {
            completion(WidgetData.cached ?? .placeholder)
            return
        }
        Task { completion(await WidgetData.load() ?? .placeholder) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DepotEntry>) -> Void) {
        Task {
            let entry = await WidgetData.load() ?? .placeholder
            let next = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: Views

struct DepotWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: DepotEntry

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: medium
        default: large
        }
    }

    private var title: some View {
        HStack(spacing: 4) {
            Image(systemName: entry.day >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
            Text("Depot")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private func headline(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Fmt.money(entry.value, decimals: 0))
                .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(Fmt.signedMoney(entry.day, decimals: 0))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.trend(entry.day))
            Text("\(Fmt.pct(entry.dayPct)) today")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.trend(entry.day))
        }
    }

    private var small: some View {
        VStack(alignment: .leading) {
            title
            Spacer(minLength: 4)
            headline(size: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading) {
                title
                Spacer(minLength: 4)
                headline(size: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entry.portfolios.prefix(4), id: \.self) { portfolioRow($0) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    title
                    headline(size: 30)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Total gain")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(Fmt.signedMoney(entry.gain, decimals: 0))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Text(Fmt.pct(entry.gainPct))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(Color.trend(entry.gain))
            }
            Divider()
            ForEach(entry.portfolios.prefix(4), id: \.self) { portfolioRow($0) }
            Divider()
            ForEach(entry.movers.prefix(max(0, 7 - min(entry.portfolios.count, 4))), id: \.self) { mover in
                HStack(spacing: 6) {
                    Text(mover.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 64, alignment: .leading)
                    Text(mover.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.pct(mover.pct))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.trend(mover.pct))
                }
            }
            Spacer(minLength: 0)
            Text("Updated \(entry.date.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func portfolioRow(_ portfolio: WidgetPortfolio) -> some View {
        HStack(spacing: 6) {
            Text(portfolio.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(Fmt.compactEUR(portfolio.value))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(Fmt.pct(portfolio.dayPct))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.trend(portfolio.day))
                .frame(minWidth: 54, alignment: .trailing)
        }
    }
}

struct DepotWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DepotWidget", provider: DepotProvider()) { entry in
            DepotWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Portfolio")
        .description("Your total portfolio value, today's change and biggest movers.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct DepotWidgetBundle: WidgetBundle {
    var body: some Widget {
        DepotWidget()
    }
}
