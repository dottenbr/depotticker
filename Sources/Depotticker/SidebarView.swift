import SwiftUI

enum SortMode: String, CaseIterable, Identifiable {
    case value = "Position value", name = "Name (A–Z)", dayPct = "Today %", gainPct = "Total gain %"
    var id: String { rawValue }
}

enum PillMode: String, CaseIterable {
    case dayPct, dayEUR, gainPct, gainEUR

    var next: PillMode {
        let all = PillMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var caption: String {
        switch self {
        case .dayPct: return "Today %"
        case .dayEUR: return "Today €"
        case .gainPct: return "Total gain %"
        case .gainEUR: return "Total gain €"
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("sortMode") private var sortMode: SortMode = .value
    @AppStorage("pillMode") private var pillMode: PillMode = .dayPct
    @State private var filter = ""
    @State private var namePrompt: NamePrompt?
    @State private var nameText = ""
    @State private var confirmDelete = false

    enum NamePrompt: Identifiable {
        case new, rename(UUID)
        var id: String {
            switch self {
            case .new: return "new"
            case .rename(let id): return id.uuidString
            }
        }
    }

    private var rows: [Holding] {
        var list = store.visibleHoldings
        if !filter.isEmpty {
            list = list.filter {
                $0.symbol.localizedCaseInsensitiveContains(filter) || $0.name.localizedCaseInsensitiveContains(filter)
            }
        }
        // Largest position first; falls back to A–Z while there is no value data.
        let hasValues = list.contains { store.value($0) != nil }
        switch sortMode == .value && !hasValues ? SortMode.name : sortMode {
        case .value: list.sort { (store.value($0) ?? -1) > (store.value($1) ?? -1) }
        case .dayPct: list.sort { (store.dayPct($0.symbol) ?? -999) > (store.dayPct($1.symbol) ?? -999) }
        case .gainPct: list.sort { (store.gainPct($0) ?? -999) > (store.gainPct($1) ?? -999) }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            portfolioChips
            summary
            List(selection: $store.selectedSymbol) {
                ForEach(rows) { holding in
                    HoldingRow(holding: holding, pillMode: $pillMode)
                        .tag(holding.symbol)
                        .contextMenu { rowMenu(holding) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let lot = holding.lots.first, holding.lots.count == 1 {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    store.delete(lot.position, from: lot.portfolioID)
                                }
                                Button("Edit", systemImage: "pencil") {
                                    store.editor = .edit(portfolioID: lot.portfolioID, position: lot.position)
                                }
                                .tint(.accentColor)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if store.portfolios.flatMap(\.positions).isEmpty {
                    ContentUnavailableView("No positions yet", systemImage: "chart.line.uptrend.xyaxis",
                                           description: Text("Add your first position with the + button."))
                }
            }
            footer
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter")
        .alert(namePromptTitle, isPresented: Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } })) {
            TextField("Name", text: $nameText)
            Button("Save") {
                switch namePrompt {
                case .new: store.addPortfolio(named: nameText)
                case .rename(let id): store.renamePortfolio(id, to: nameText)
                case nil: break
                }
                namePrompt = nil
            }
            Button("Cancel", role: .cancel) { namePrompt = nil }
        }
        .confirmationDialog("Delete “\(store.selectedPortfolioName)” and all its positions?",
                            isPresented: $confirmDelete) {
            Button("Delete Portfolio", role: .destructive) {
                if let id = store.selectedPortfolioID { store.deletePortfolio(id) }
            }
        }
    }

    private var namePromptTitle: String {
        if case .rename = namePrompt { return "Rename Portfolio" }
        return "New Portfolio"
    }

    private var portfolioChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                chip("All", id: nil)
                ForEach(store.portfolios) { portfolio in
                    chip(portfolio.name, id: portfolio.id)
                }
                Menu {
                    Button("New Portfolio…") {
                        nameText = ""
                        namePrompt = .new
                    }
                    if let id = store.selectedPortfolioID {
                        Button("Rename “\(store.selectedPortfolioName)”…") {
                            nameText = store.selectedPortfolioName
                            namePrompt = .rename(id)
                        }
                        Button("Delete “\(store.selectedPortfolioName)”…", role: .destructive) {
                            confirmDelete = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 22)
                }
                .compactMenu()
                .help("Manage portfolios")
            }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, id: UUID?) -> some View {
        let selected = store.selectedPortfolioID == id
        return Button {
            store.selectedPortfolioID = id
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(Color.accentColor).interactive() : .regular.interactive(), in: .capsule)
    }

    private var summary: some View {
        let totals = store.visibleTotals
        let masked = store.amountsHidden
        return Button {
            store.selectedSymbol = nil
            store.showOverview = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.selectedPortfolioName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(masked ? "••••••" : (totals.value > 0 ? Fmt.money(totals.value) : "—"))
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                HStack(spacing: 6) {
                    Text("\(Fmt.signedMoney(totals.day))  \(Fmt.pct(totals.dayPct))")
                        .foregroundStyle(Color.trend(totals.day))
                    Text("today")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                HStack(spacing: 6) {
                    Text("\(Fmt.signedMoney(totals.gain))  \(Fmt.pct(totals.gainPct))")
                        .foregroundStyle(Color.trend(totals.gain))
                    Text("total")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the portfolio overview")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.lastError == nil && store.sourceConfig.source != .none ? Color.up : Color.orange)
                .frame(width: 6, height: 6)
            if store.sourceConfig.source == .none || (store.sourceConfig.source.needsKey && store.sourceConfig.key(store.sourceConfig.source) == nil) {
                Button("No price source · Choose…") { store.showSourceSettings = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
            } else if let error = store.lastError {
                Text(error).lineLimit(1)
            } else if store.catchUpMinutes > 1 {
                Text("Still reading today's trades · about \(Duration.seconds(store.catchUpMinutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left")
                    .lineLimit(1)
                    .help("The exchanges publish one file per minute and limit how fast they may be read. Until the earlier files of today are in, a share that has not traded in the last minutes shows an older price.")
            } else if let date = store.lastUpdate {
                Text("\(MarketData.source == .yahoo ? "Live" : "Delayed") · updated \(date.formatted(date: .omitted, time: .standard))")
            } else {
                Text("Loading quotes…")
            }
            Spacer()
            Menu {
                Picker("Sort by", selection: $sortMode) {
                    ForEach(SortMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(sortMode.rawValue, systemImage: "arrow.up.arrow.down")
            }
            .compactMenu()
            .help("Sort positions")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rowMenu(_ holding: Holding) -> some View {
        ForEach(holding.lots, id: \.position.id) { lot in
            Button("Edit \(lot.portfolioName) position…") {
                store.editor = .edit(portfolioID: lot.portfolioID, position: lot.position)
            }
        }
        Divider()
        ForEach(holding.lots, id: \.position.id) { lot in
            Button("Remove from \(lot.portfolioName)", role: .destructive) {
                store.delete(lot.position, from: lot.portfolioID)
            }
        }
    }
}

struct HoldingRow: View {
    @EnvironmentObject private var store: Store
    var holding: Holding
    @Binding var pillMode: PillMode

    var body: some View {
        let quote = store.quotes[holding.symbol]
        let dayPct = quote?.changePct
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(holding.symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(holding.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(Fmt.quantity(holding.quantity)) × \(store.priceEUR(holding.symbol).map { Fmt.money($0) } ?? "—")")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Sparkline(values: quote?.spark ?? [], baseline: quote?.previousClose, color: .trend(dayPct))
                .frame(width: 54, height: 24)
            VStack(alignment: .trailing, spacing: 3) {
                Text(store.value(holding).map { Fmt.money($0, decimals: 0) } ?? "—")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .help("Value of your position")
                    .contentTransition(.numericText())
                Button {
                    pillMode = pillMode.next
                } label: {
                    ChangePill(text: pillText, trend: pillTrend)
                }
                .buttonStyle(.plain)
                .help("\(pillMode.caption) – click to switch")
            }
        }
        .padding(.vertical, 4)
    }

    private var pillText: String {
        switch pillMode {
        case .dayPct: return store.dayPct(holding.symbol).map(Fmt.pct) ?? "—"
        case .dayEUR: return store.dayChange(holding).map { Fmt.signedMoney($0, decimals: 0) } ?? "—"
        case .gainPct: return store.gainPct(holding).map(Fmt.pct) ?? "—"
        case .gainEUR: return store.gain(holding).map { Fmt.signedMoney($0, decimals: 0) } ?? "—"
        }
    }

    private var pillTrend: Double? {
        switch pillMode {
        case .dayPct: return store.dayPct(holding.symbol)
        // The EUR change includes the exchange-rate move, so its sign can differ from the share's own.
        case .dayEUR: return store.dayChange(holding)
        case .gainPct, .gainEUR: return store.gain(holding)
        }
    }
}
