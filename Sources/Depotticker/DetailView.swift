import SwiftUI

struct DetailView: View {
    @EnvironmentObject private var store: Store
    var holding: Holding

    @AppStorage("chartRange") private var range: ChartRange = .day
    @State private var data: ChartData?
    @State private var loadError: String?
    @State private var hoverIndex: Int?
    /// Start of a click-drag measurement between two points.
    @State private var dragStart: Int?
    @State private var fundamentals: Fundamentals?
    @State private var news: [NewsItem] = []
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }

    private var symbol: String { holding.symbol }
    private var meta: SymbolMeta? { store.meta[symbol] }
    private var currency: String { meta?.currency ?? "EUR" }
    private var points: [ChartPoint] { data?.points ?? [] }

    /// Reference price the range's change is measured against.
    private var baseline: Double? {
        guard let data else { return nil }
        return range == .day ? (data.previousClose ?? data.points.first?.price) : data.points.first?.price
    }

    /// Your average purchase price converted from EUR into the listing's currency.
    private var averageCostNative: Double? {
        guard let rate = store.fx[currency], rate > 0, let cost = store.unitCost(holding), cost > 0 else { return nil }
        return cost / rate
    }

    private var currentPrice: Double? {
        store.nativePrice(symbol) ?? points.last?.price
    }

    var body: some View {
        // On the 1D range follow the live price so the chart matches the list.
        let latest = range == .day ? (currentPrice ?? points.last?.price) : points.last?.price
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ChartPanel(points: points,
                           baseline: range == .day ? baseline : nil,
                           color: .trend((latest ?? 0) - (baseline ?? 0)),
                           averageCost: averageCostNative,
                           error: loadError,
                           range: $range, hoverIndex: $hoverIndex, dragStart: $dragStart)
                positionCard
                statsCard
                if !news.isEmpty { newsCard }
            }
            .padding(compact ? 16 : 24)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .task {
            async let figures = try? MarketData.fundamentals(symbol)
            async let headlines = try? MarketData.news(symbol: symbol, name: holding.name)
            fundamentals = await figures
            news = await headlines ?? []
        }
        .task(id: range) {
            hoverIndex = nil
            dragStart = nil
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: range == .day ? max(.seconds(30), MarketData.source.refreshInterval) : .seconds(300))
            }
        }
    }

    private func load() async {
        do {
            let fresh = try await MarketData.chart(symbol, range: range)
            data = fresh
            loadError = nil
            store.update(meta: fresh.meta)
        } catch {
            if data == nil { loadError = error.localizedDescription }
        }
    }

    // MARK: Header

    private var header: some View {
        let hovered = hoverIndex.flatMap { points.indices.contains($0) ? points[$0] : nil }
        let measureFrom = dragStart.flatMap { points.indices.contains($0) ? points[$0] : nil }
        let reference = measureFrom?.price ?? baseline
        let price = hovered?.price ?? currentPrice
        let change = price.flatMap { p in reference.map { p - $0 } }
        let changePct = change.flatMap { c in reference.map { $0 > 0 ? c / $0 * 100 : 0 } }

        let status = HStack(spacing: 5) {
            if let session = data?.session {
                Circle()
                    .fill(session.isOpen ? Color.up : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(session.status)
                    .lineLimit(1)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, data?.session == nil ? 0 : 10)
        .padding(.vertical, data?.session == nil ? 0 : 4)
        .glassEffect(.regular, in: .capsule)
        let listing = Text([meta?.exchange, currency].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        let priceText = Text(price.map { Fmt.money($0, currency) } ?? "—")
            .font(.system(size: compact ? 34 : 40, weight: .semibold, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText())
        let changeText = Group {
            if let change, let changePct {
                Text("\(Fmt.signedMoney(change, currency))  \(Fmt.pct(changePct))")
                    .font(.system(size: compact ? 15 : 17, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.trend(change))
                    .lineLimit(1)
            }
        }
        let caption = Text(chartCaption(points: points, hoverIndex: hoverIndex, dragStart: dragStart, range: range))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        let converted = Group {
            if currency != "EUR", hovered == nil, let eur = store.priceEUR(symbol) {
                Text("≈ \(Fmt.money(eur))")
                    .font(.system(size: compact ? 15 : 17, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(symbol)
                    .font(.system(size: compact ? 24 : 28, weight: .bold))
                Text(holding.name)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !compact {
                    status
                    listing
                }
            }
            if hovered == nil, let extended = store.extendedPrice(symbol), let regular = store.nativePrice(symbol), regular > 0 {
                Text("Outside trading hours: \(Fmt.money(extended, currency))  \(Fmt.pct((extended / regular - 1) * 100)) · not included in your values")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    priceText
                    Spacer()
                    converted
                }
                HStack(spacing: 8) {
                    changeText
                    caption
                }
                HStack(spacing: 8) {
                    status
                    listing
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    priceText
                    changeText
                    caption
                    Spacer()
                    converted
                }
            }
        }
    }

    // MARK: Position

    private var positionCard: some View {
        let value = store.value(holding)
        let gain = store.gain(holding)
        let day = store.dayChange(holding)
        let total = store.totals(in: nil).value
        return Card(title: "Your Position") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], spacing: 14) {
                Stat(label: "Value", value: value.map { Fmt.money($0) } ?? "—")
                Stat(label: "Today", value: day.map { Fmt.signedMoney($0) } ?? "—", color: .trend(day))
                Stat(label: "Total gain", value: gain.map { Fmt.signedMoney($0) } ?? "—", color: .trend(gain))
                Stat(label: "Total gain %", value: store.gainPct(holding).map(Fmt.pct) ?? "—", color: .trend(gain))
                Stat(label: "Shares", value: Fmt.quantity(holding.quantity))
                Stat(label: "Average cost", value: store.unitCost(holding).map { Fmt.money($0) } ?? "—")
                Stat(label: "Invested", value: store.cost(holding).map { Fmt.money($0) } ?? "—")
                if holding.hasSales {
                    let realized = store.realized(holding)
                    Stat(label: "Realised gain", value: realized.map { Fmt.signedMoney($0) } ?? "—", color: .trend(realized))
                }
                Stat(label: "Share of all portfolios",
                     value: value.map { total > 0 ? Fmt.plainPct($0 / total * 100) : "—" } ?? "—")
            }
            Divider()
            ForEach(holding.lots, id: \.position.id) { lot in
                LotRow(lot: lot, priceEUR: store.priceEUR(symbol))
            }
        }
    }

    // MARK: Statistics

    private var statsCard: some View {
        Card(title: "Key Figures") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], spacing: 14) {
                Stat(label: "P/E (trailing)", value: ratio(fundamentals?.trailingPE))
                Stat(label: "P/E (forward)", value: ratio(fundamentals?.forwardPE))
                Stat(label: "Earnings per share", value: money(fundamentals?.eps))
                Stat(label: "Market cap", value: fundamentals?.marketCap.map { "\(Fmt.compact($0)) \(currency)" } ?? "—")
                Stat(label: "Dividend yield", value: fundamentals?.dividendYield.map { Fmt.plainPct($0, decimals: 2) } ?? "—")
                Stat(label: "Price / book", value: ratio(fundamentals?.priceToBook))
                Stat(label: "Analyst rating", value: fundamentals?.analystRating ?? "—")
                Stat(label: "Earnings date",
                     value: fundamentals?.earningsDate?.formatted(.dateTime.day().month(.abbreviated).year()) ?? "—")
                Stat(label: "Open", value: money(meta?.open))
                Stat(label: "Day high", value: money(meta?.dayHigh))
                Stat(label: "Day low", value: money(meta?.dayLow))
                Stat(label: "Previous close", value: money(meta?.previousClose))
                Stat(label: "52-week high", value: money(meta?.week52High))
                Stat(label: "52-week low", value: money(meta?.week52Low))
                Stat(label: "Volume", value: meta?.volume.map(Fmt.compact) ?? "—")
                Stat(label: "From 52-week high", value: fromHigh)
            }
        }
    }

    // MARK: News

    private var newsCard: some View {
        Card(title: "News") {
            VStack(spacing: 0) {
                ForEach(news.prefix(6)) { item in
                    NewsRow(item: item)
                    if item.id != news.prefix(6).last?.id { Divider().opacity(0.5) }
                }
            }
        }
    }

    private func ratio(_ value: Double?) -> String {
        value.map { Fmt.number($0, decimals: 1) } ?? "—"
    }

    private func money(_ value: Double?) -> String {
        value.map { Fmt.money($0, currency) } ?? "—"
    }

    private var fromHigh: String {
        guard let high = meta?.week52High, high > 0, let price = currentPrice else { return "—" }
        return Fmt.pct((price / high - 1) * 100)
    }
}

/// One compact headline; opens the article in the browser.
private struct NewsRow: View {
    @Environment(\.openURL) private var openURL
    var item: NewsItem
    @State private var hovering = false

    var body: some View {
        Button {
            openURL(item.url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(item.publisher) · \(item.date.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.url.host() ?? "")
    }
}

private struct LotRow: View {
    @EnvironmentObject private var store: Store
    var lot: Holding.Lot
    var priceEUR: Double?

    var body: some View {
        let position = lot.position
        let rate = store.fx[position.currency]
        let gain: Double? = position.costUnknown ? nil : priceEUR.flatMap { price in
            rate.map { (price - position.unitCost * $0) * position.quantity }
        }
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 12) {
            Text(lot.portfolioName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .frame(minWidth: 70, alignment: .leading)
            Text(position.costUnknown ? "\(Fmt.quantity(position.quantity)) · purchase price unknown"
                 : "\(Fmt.quantity(position.quantity)) × \(Fmt.money(position.unitCost, position.currency))")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Text(priceEUR.map { Fmt.money($0 * position.quantity, decimals: 0) } ?? "—")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
            Text(gain.map { Fmt.signedMoney($0) } ?? "—")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Color.trend(gain))
                .lineLimit(1)
                .frame(minWidth: 80, alignment: .trailing)
            Button {
                store.editor = .edit(portfolioID: lot.portfolioID, position: position)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit this position or record a purchase or sale")
        }
        ForEach(position.orderedTrades) { trade in
            HStack(spacing: 6) {
                Image(systemName: trade.kind == .buy ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(trade.kind == .buy ? Color.secondary : Color.orange)
                Text((trade.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Date unknown")
                     + (trade.estimated == true ? " (estimated)" : ""))
                Text("\(trade.kind == .buy ? "Bought" : "Sold") \(Fmt.quantity(trade.quantity)) × \(Fmt.money(trade.price, position.currency))")
                Spacer()
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
        }
        }
    }
}
