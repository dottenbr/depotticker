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
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var confirmDelete = false

    private var existing: (portfolioID: UUID, position: Position)? {
        if case .edit(let portfolioID, let position) = context { return (portfolioID, position) }
        return nil
    }

    private var canSave: Bool {
        !symbol.isEmpty && (quantity ?? 0) > 0 && (unitCost ?? -1) >= 0 && portfolioID != nil
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
                TextField("Shares", value: $quantity, format: .number.precision(.fractionLength(0...4)))
                TextField("Average cost per share (€)", value: $unitCost,
                          format: .number.precision(.fractionLength(2...4)))
            }
            .formStyle(.columns)

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
        .frame(width: 460)
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
            unitCost = existing.position.unitCost
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
        guard let quantity, let unitCost, let portfolioID else { return }
        if let existing {
            var position = existing.position
            position.quantity = quantity
            position.unitCost = unitCost
            store.update(position, in: existing.portfolioID, movingTo: portfolioID)
        } else {
            store.add(Position(symbol: symbol, name: name, quantity: quantity, unitCost: unitCost), to: portfolioID)
            store.selectedSymbol = symbol
        }
        dismiss()
    }
}
