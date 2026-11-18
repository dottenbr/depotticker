import Charts
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("portfolioRange") private var range: ChartRange = .month
    private var history: [ChartPoint] {
        store.histories[store.historyKey(range, store.selectedPortfolioID)] ?? []
    }
    @State private var hoverIndex: Int?
    @State private var dragStart: Int?
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }


    var body: some View {
        let totals = store.visibleTotals
        let holdings = store.visibleHoldings
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(totals)
                // On 1D the reference is yesterday's close, so chart and header agree with "Today".
                let previousClose: Double? = range == .day && totals.value > 0 ? totals.value - totals.day : nil
                ChartPanel(points: history, baseline: previousClose,
                           color: .trend(previousClose != nil ? totals.day
                                         : (history.last?.price ?? 0) - (history.first?.price ?? 0)),
                           ranges: Store.historyRanges, error: nil,
                           range: $range, hoverIndex: $hoverIndex, dragStart: $dragStart)
                Text(chartNote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)

                AdaptiveStack {
                    tile("Today", Fmt.signedMoney(totals.day), Fmt.pct(totals.dayPct), totals.day)
                    tile("Total gain", Fmt.signedMoney(totals.gain), Fmt.pct(totals.gainPct), totals.gain)
                    tile("Invested", Fmt.money(totals.cost), "\(totals.count) positions", nil)
                }

                if store.selectedPortfolioID == nil, store.portfolios.count > 1 {
                    Card(title: "Portfolios") {
                        ForEach(store.portfolios) { portfolio in
                            PortfolioRow(portfolio: portfolio, total: totals.value)
                        }
                    }
                }

                AllocationCard(holdings: holdings, total: totals.value)

                AdaptiveStack {
                    movers("Top gainers today", holdings: holdings, ascending: false)
                    movers("Top losers today", holdings: holdings, ascending: true)
                }

                if totals.uncosted > 0 {
                    Text("\(totals.uncosted) position(s) have no known purchase price. They count towards the value, but not towards total gain and invested.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if totals.missing > 0 {
                    Text("\(totals.missing) position(s) have no quote yet and are not included in the totals.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(compact ? 16 : 24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .task(id: store.historyKey(range, store.selectedPortfolioID)) {
            hoverIndex = nil
            dragStart = nil
            // Usually already preloaded; this refreshes the range if it has gone stale.
            await store.loadHistory(range)
        }
    }

    private func header(_ totals: Totals) -> some View {
        let hovered = hoverIndex.flatMap { history.indices.contains($0) ? history[$0] : nil }
        let measured = dragStart.flatMap { history.indices.contains($0) ? history[$0].price : nil }
        let value = hovered?.price ?? (totals.value > 0 ? totals.value : nil)
        // At rest the header shows your real figures: today's change on 1D, otherwise your total gain.
        // The chart's own period change is not your return and is only read out while you point at it.
        var change: Double?
        var changePct: Double?
        var caption = ""
        if let hovered {
            if let from = measured ?? history.first?.price, from > 0 {
                change = hovered.price - from
                changePct = (hovered.price - from) / from * 100
            }
            caption = "these shares · " + chartCaption(points: history, hoverIndex: hoverIndex, dragStart: dragStart, range: range)
        } else if totals.value > 0 {
            if range == .day {
                change = totals.day
                changePct = totals.dayPct
                caption = "today"
            } else if totals.cost > 0 {
                change = totals.gain
                changePct = totals.gainPct
                caption = "total gain since purchase"
            }
        }

        return VStack(alignment: .leading, spacing: 6) {
            Text(store.selectedPortfolioName)
                .font(.title3)
                .foregroundStyle(.secondary)
            AdaptiveStack(spacing: compact ? 2 : 12) {
                Text(store.amountsHidden ? "••••••" : (value.map { Fmt.money($0) } ?? "—"))
                    .font(.system(size: compact ? 36 : 46, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let change, let changePct {
                    Text("\(Fmt.signedMoney(change, decimals: 0))  \(Fmt.pct(changePct))")
                        .font(.system(size: 17, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.trend(change))
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Explains what the chart is, and on longer ranges what it is not.
    private var chartNote: String {
        guard range != .day, let first = history.first?.price, let last = history.last?.price, first > 0 else {
            return "Value of the shares you hold today during the day, at today's exchange rates."
        }
        return "Price history of the shares you hold today, at today's exchange rates: \(Fmt.pct((last / first - 1) * 100)) over the \(range.label). "
            + "This is not your own return, because it ignores when and at what price you bought. Your return is the total gain."
    }

    private func tile(_ title: String, _ main: String, _ sub: String, _ trend: Double?) -> some View {
        Card(title: nil) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(main)
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(trend == nil ? Color.primary : Color.trend(trend))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Text(sub)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(trend == nil ? Color.secondary : Color.trend(trend))
            }
        }
    }

    private func movers(_ title: String, holdings: [Holding], ascending: Bool) -> some View {
        var ranked: [(Holding, Double)] = []
        for holding in holdings {
            guard let pct = store.dayPct(holding.symbol), ascending ? pct < 0 : pct > 0 else { continue }
            ranked.append((holding, pct))
        }
        ranked.sort { ascending ? $0.1 < $1.1 : $0.1 > $1.1 }
        ranked = Array(ranked.prefix(5))
        return Card(title: title) {
            if ranked.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(ranked, id: \.0.id) { holding, pct in
                Button {
                    store.selectedSymbol = holding.symbol
                } label: {
                    HStack {
                        Text(holding.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 76, alignment: .leading)
                        Text(holding.name)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(store.dayChange(holding).map { Fmt.signedMoney($0, decimals: 0) } ?? "")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                        ChangePill(text: Fmt.pct(pct), trend: pct)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Donut chart of the largest positions with a clickable legend.
private struct AllocationCard: View {
    @EnvironmentObject private var store: Store
    var holdings: [Holding]
    var total: Double

    struct Slice: Identifiable {
        var id: String
        var symbol: String?
        var name: String
        var value: Double
        var color: Color
    }

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .yellow, .green, .mint, .teal, .indigo]

    private var slices: [Slice] {
        var ranked: [(Holding, Double)] = []
        for holding in holdings {
            if let value = store.value(holding), value > 0 { ranked.append((holding, value)) }
        }
        ranked.sort { $0.1 > $1.1 }
        let top = ranked.prefix(Self.palette.count)
        var result: [Slice] = []
        for (index, item) in top.enumerated() {
            result.append(Slice(id: item.0.symbol, symbol: item.0.symbol, name: item.0.name,
                                value: item.1, color: Self.palette[index]))
        }
        let rest = ranked.dropFirst(top.count).reduce(0) { $0 + $1.1 }
        if rest > 0 {
            result.append(Slice(id: "other", symbol: nil, name: "\(ranked.count - top.count) other positions",
                                value: rest, color: Color.gray.opacity(0.55)))
        }
        return result
    }

    var body: some View {
        let slices = slices
        Card(title: "Largest Positions") {
            AdaptiveStack(spacing: 20) {
                Chart(slices) { slice in
                    SectorMark(angle: .value("Value", slice.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .cornerRadius(4)
                        .foregroundStyle(slice.color)
                }
                .chartLegend(.hidden)
                .frame(width: 230, height: 230)
                .frame(maxWidth: .infinity)
                .overlay {
                    VStack(spacing: 2) {
                        Text("\(holdings.count)")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("positions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 7) {
                    ForEach(slices) { slice in
                        Button {
                            if let symbol = slice.symbol { store.selectedSymbol = symbol }
                        } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(slice.color)
                                    .frame(width: 11, height: 11)
                                Text(slice.symbol ?? "Other")
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .frame(width: 70, alignment: .leading)
                                Text(slice.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Fmt.money(slice.value, decimals: 0))
                                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                                Text(total > 0 ? Fmt.plainPct(slice.value / total * 100) : "—")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(slice.symbol == nil)
                    }
                }
            }
        }
    }
}

private struct PortfolioRow: View {
    @EnvironmentObject private var store: Store
    @Environment(\.horizontalSizeClass) private var sizeClass
    var portfolio: Portfolio
    var total: Double

    var body: some View {
        let totals = store.totals(in: portfolio.id)
        let share = total > 0 ? totals.value / total : 0
        Button {
            store.selectedPortfolioID = portfolio.id
        } label: {
            VStack(spacing: 6) {
                HStack {
                    Text(portfolio.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text(Fmt.plainPct(share * 100))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if sizeClass != .compact {
                        Text("\(Fmt.signedMoney(totals.day, decimals: 0)) today")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Color.trend(totals.day))
                    }
                    Text("\(Fmt.pct(totals.gainPct)) total")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.trend(totals.gain))
                        .lineLimit(1)
                        .frame(minWidth: 96, alignment: .trailing)
                    Text(Fmt.money(totals.value, decimals: 0))
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .lineLimit(1)
                        .frame(minWidth: 84, alignment: .trailing)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.accentColor).frame(width: max(geo.size.width * share, 3))
                    }
                }
                .frame(height: 5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show only \(portfolio.name)")
    }
}
