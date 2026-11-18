import SwiftUI

struct PositionEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    var context: EditorContext

    @State private var symbol = ""
    @State private var name = ""
    @State private var quantity: Double?
    @State private var unitCost: Double?
    @State private var portfolioID: UUID?
    @State private var currency = "EUR"
    @State private var costUnknown = false
    @State private var trades: [Trade] = []
    @State private var tradeKind = Trade.Kind.buy
    @State private var tradeDate = Date()
    @State private var tradeQuantity: Double?
    @State private var tradePrice: Double?
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var confirmDelete = false

    private var existing: (portfolioID: UUID, position: Position)? {
        if case .edit(let portfolioID, let position) = context { return (portfolioID, position) }
        return nil
    }

    private var canSave: Bool {
        guard !symbol.isEmpty, portfolioID != nil else { return false }
        if !trades.isEmpty { return true }
        return (quantity ?? 0) > 0 && (costUnknown || (unitCost ?? -1) >= 0)
    }

    /// The position as it would be saved; shares and average cost follow the trades when there are any.
    private var draft: Position {
        Position(id: existing?.position.id ?? UUID(), symbol: symbol, name: name, quantity: quantity ?? 0,
                 unitCost: costUnknown ? 0 : (unitCost ?? 0), currency: currency, costUnknown: costUnknown,
                 trades: trades, timeHeld: existing?.position.timeHeld)
    }

    private var currencies: [String] {
        var list = ["EUR", "USD", "GBP", "CHF"]
        for extra in [store.meta[symbol]?.currency, currency] {
            if let extra, !list.contains(extra) { list.append(extra) }
        }
        return list
    }

    private var canAddTrade: Bool {
        guard let amount = tradeQuantity, amount > 0, (tradePrice ?? -1) >= 0 else { return false }
        return tradeKind == .buy || amount <= draft.quantity + 1e-9
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Add Position" : "Edit Position")
                .font(.title2.bold())

            if existing == nil {
                searchSection
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(symbol).font(.headline)
                    Text(name).font(.callout).foregroundStyle(.secondary)
                }
            }

            Form {
                Picker("Portfolio", selection: $portfolioID) {
                    ForEach(store.portfolios) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Bought in", selection: $currency) {
                    ForEach(currencies, id: \.self) { Text($0).tag($0) }
                }
                if trades.isEmpty {
                    TextField("Shares", value: $quantity, format: .number.precision(.fractionLength(0...4)))
                    TextField("Average cost per share (\(currency))", value: $unitCost,
                              format: .number.precision(.fractionLength(2...4)))
                        .disabled(costUnknown)
                    Toggle("Purchase price unknown", isOn: $costUnknown)
                } else {
                    LabeledContent("Shares", value: Fmt.quantity(draft.quantity))
                    LabeledContent("Average cost", value: costUnknown ? "unknown" : Fmt.money(draft.unitCost, currency))
                    LabeledContent("Realised gain", value: Fmt.signedMoney(draft.realized, currency))
                }
            }
            .formStyle(.columns)

            tradesSection

            HStack {
                if existing != nil {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 500)
        #else
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.large])
        #endif
        .onAppear(perform: prefill)
        .task(id: query) { await search() }
        .confirmationDialog("Delete this position?", isPresented: $confirmDelete) {
            Button("Delete Position", role: .destructive) {
                if let existing { store.delete(existing.position, from: existing.portfolioID) }
                dismiss()
            }
        }
    }

    /// Purchases and sales with date and price.
    private var tradesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Purchases and sales")
                .font(.headline)
            if trades.isEmpty {
                Text("Optional. Record a purchase or sale with its date and price; shares and average cost are then calculated from these entries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(draft.orderedTrades) { trade in
                            HStack(spacing: 8) {
                                Text((trade.date.map { $0.formatted(date: .numeric, time: .omitted) } ?? "Date unknown")
                                     + (trade.estimated == true ? " est." : ""))
                                    .frame(width: 120, alignment: .leading)
                                Text(trade.kind == .buy ? "Buy" : "Sell")
                                    .foregroundStyle(trade.kind == .buy ? Color.primary : Color.orange)
                                    .frame(width: 34, alignment: .leading)
                                Text("\(Fmt.quantity(trade.quantity)) × \(Fmt.money(trade.price, currency))")
                                Spacer()
                                Button {
                                    // Move the entry into the fields below to correct it.
                                    tradeKind = trade.kind
                                    tradeDate = trade.date ?? Date()
                                    tradeQuantity = trade.quantity
                                    tradePrice = trade.price
                                    trades.removeAll { $0.id == trade.id }
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Correct this entry")
                                Button {
                                    removeTrade(trade)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this entry")
                            }
                            .font(.system(size: 12).monospacedDigit())
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            HStack(spacing: 8) {
                Picker("", selection: $tradeKind) {
                    Text("Buy").tag(Trade.Kind.buy)
                    Text("Sell").tag(Trade.Kind.sell)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
                DatePicker("", selection: $tradeDate, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                TextField("Shares", value: $tradeQuantity, format: .number.precision(.fractionLength(0...4)))
                TextField("Price (\(currency))", value: $tradePrice, format: .number.precision(.fractionLength(2...4)))
                Button("Add") { addTrade() }
                    .buttonStyle(.glass)
                    .disabled(!canAddTrade)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private func addTrade() {
        guard let amount = tradeQuantity, let price = tradePrice else { return }
        var position = draft
        position.record(Trade(kind: tradeKind, day: Trade.dayFormatter.string(from: tradeDate), quantity: amount, price: price))
        trades = position.trades
        tradeQuantity = nil
        tradePrice = nil
    }

    private func removeTrade(_ trade: Trade) {
        // Keep what is held when the last entry goes away.
        var position = draft
        position.trades.removeAll { $0.id == trade.id }
        if let summary = position.tradeSummary {
            trades = position.trades
            quantity = summary.quantity
            unitCost = summary.unitCost
        } else {
            quantity = draft.quantity
            unitCost = draft.unitCost
            trades = []
        }
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name, symbol or ISIN", text: $query)
                    .textFieldStyle(.plain)
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            if !symbol.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.up)
                    Text(symbol).font(.headline)
                    Text(name).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(results) { result in
                            Button {
                                symbol = result.symbol
                                name = result.name
                            } label: {
                                HStack {
                                    Text(result.symbol)
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(width: 90, alignment: .leading)
                                    Text(result.name)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(result.exchange)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 5)
                                .padding(.horizontal, 6)
                                .background(result.symbol == symbol ? Color.accentColor.opacity(0.18) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
    }

    private func prefill() {
        if let existing {
            symbol = existing.position.symbol
            name = existing.position.name
            quantity = existing.position.quantity
            unitCost = existing.position.costUnknown ? nil : existing.position.unitCost
            currency = existing.position.currency
            costUnknown = existing.position.costUnknown
            trades = existing.position.trades
            portfolioID = existing.portfolioID
        } else {
            portfolioID = store.selectedPortfolioID ?? store.portfolios.first?.id
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        if let found = try? await Yahoo.search(text), !Task.isCancelled {
            results = found
        }
    }

    private func save() {
        guard let portfolioID, canSave else { return }
        if let existing {
            store.update(draft, in: existing.portfolioID, movingTo: portfolioID)
        } else {
            store.add(draft, to: portfolioID)
            store.selectedSymbol = symbol
        }
        dismiss()
    }
}
