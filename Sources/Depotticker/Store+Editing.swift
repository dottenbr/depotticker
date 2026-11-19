// Changes the user makes: price source, import and export, portfolios and positions.
import Foundation
import SwiftUI
import WidgetKit

extension Store {
    // MARK: Price source

    /// Switches the price source or stores an API key, then reloads everything from the new source.
    func setSource(_ source: DataSource, key: String? = nil, supplement: DataSource? = nil) {
        var config = sourceConfig
        config.source = source
        config.supplement = source == .boerse ? supplement : nil
        let keyed = source == .boerse ? supplement : source
        if let key, let keyed { config.keys[keyed.rawValue] = key.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard config != sourceConfig else { return }
        config.save(to: repository.directory)
        MarketData.config = config
        sourceConfig = config
        quotes.removeAll()
        supplementedSeen = []
        // Listing currency and venue differ between sources; each has its own cached facts.
        meta = repository.loadMeta()
        lastError = nil
        WidgetCenter.shared.reloadAllTimelines()
        invalidateHistories(reload: true)
        Task {
            if source == .boerse { await resolveISINs() }
            await refresh()
        }
    }

    /// Looks up the ISIN of every position that has none, in the public registers. Slow (a few
    /// seconds per share) because the registers limit how often they may be asked.
    func resolveISINs() async {
        var seen = Set<String>()
        let open = portfolios.flatMap(\.positions).filter { ($0.isin ?? "").isEmpty && seen.insert($0.symbol).inserted }
        guard !open.isEmpty, isinProgress == nil else { return }
        isinProgress = (0, open.count)
        var missing: [String] = []
        for (index, position) in open.enumerated() {
            let names = [meta[position.symbol]?.name, position.name].compactMap { $0 }
            if let found = await Instruments.isin(for: position.symbol, names: names) {
                for p in portfolios.indices {
                    for i in portfolios[p].positions.indices where portfolios[p].positions[i].symbol == position.symbol {
                        portfolios[p].positions[i].isin = found.isin
                    }
                }
                repository.save(portfolios)
                loadedStamp = repository.stamp()
            } else {
                missing.append(position.symbol)
            }
            isinProgress = (index + 1, open.count)
        }
        isinProgress = nil
        unresolvedISINs = missing
        invalidateHistories(reload: true)
    }

    // MARK: Import and export

    func exportCSV() -> String {
        CSVCodec.export(portfolios, priceEUR: { [self] in priceEUR($0) }, rateEUR: { [self] in fx[$0] })
    }

    /// Applies imported portfolios. Positions go into the portfolio with the same name; `replacing`
    /// drops everything first (the previous state is kept as a backup file).
    func apply(imported: [Portfolio], replacing: Bool) {
        repository.backup(portfolios)
        portfolios = PortfolioMerge.merge(imported, into: portfolios, replacing: replacing).portfolios
        if let selected = selectedPortfolioID, !portfolios.contains(where: { $0.id == selected }) {
            selectedPortfolioID = nil
        }
        save()
        Task {
            if sourceConfig.source == .boerse { await resolveISINs() }
            await refresh()
        }
    }

    /// Adds an estimated purchase date to every position that has a cost but no date. Returns how many.
    @discardableResult
    func estimatePurchaseDates(style: PurchaseEstimator.Style = .single) async -> Int {
        let outcome = await PurchaseEstimator.fillMissingDates(in: portfolios, style: style)
        guard outcome.estimated > 0 else { return 0 }
        repository.backup(portfolios)
        // Keep edits made while the estimate was running.
        for portfolio in outcome.portfolios {
            guard let p = portfolios.firstIndex(where: { $0.id == portfolio.id }) else { continue }
            for position in portfolio.positions where !position.trades.isEmpty {
                if let i = portfolios[p].positions.firstIndex(where: { $0.id == position.id }),
                   portfolios[p].positions[i].needsPurchaseDate {
                    portfolios[p].positions[i] = position
                }
            }
        }
        save()
        return outcome.estimated
    }

    // MARK: Editing

    func addPortfolio(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let portfolio = Portfolio(name: trimmed)
        portfolios.append(portfolio)
        selectedPortfolioID = portfolio.id
        save()
    }

    func renamePortfolio(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = portfolios.firstIndex(where: { $0.id == id }) else { return }
        portfolios[index].name = trimmed
        save()
    }

    func deletePortfolio(_ id: UUID) {
        portfolios.removeAll { $0.id == id }
        if selectedPortfolioID == id { selectedPortfolioID = nil }
        save()
    }

    func add(_ position: Position, to portfolioID: UUID) {
        guard let index = portfolios.firstIndex(where: { $0.id == portfolioID }) else { return }
        portfolios[index].positions.append(position)
        save()
        Task {
            if sourceConfig.source == .boerse { await resolveISINs() }
            await refresh()
        }
    }

    func update(_ position: Position, in portfolioID: UUID, movingTo target: UUID) {
        guard let from = portfolios.firstIndex(where: { $0.id == portfolioID }),
              let index = portfolios[from].positions.firstIndex(where: { $0.id == position.id })
        else { return }
        if target == portfolioID {
            portfolios[from].positions[index] = position
        } else if let to = portfolios.firstIndex(where: { $0.id == target }) {
            portfolios[from].positions.remove(at: index)
            portfolios[to].positions.append(position)
        }
        save()
        Task { await refresh() }
    }

    func delete(_ position: Position, from portfolioID: UUID) {
        guard let index = portfolios.firstIndex(where: { $0.id == portfolioID }) else { return }
        portfolios[index].positions.removeAll { $0.id == position.id }
        save()
    }
}
