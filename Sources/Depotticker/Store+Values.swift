// Figures derived from prices and holdings, all in EUR (see Valuation).
import Foundation
import SwiftUI
import WidgetKit

extension Store {
    // MARK: Derived values (all in EUR, see `Valuation`)

    var valuation: Valuation { Valuation(quotes: quotes, meta: meta, fx: fx, fxPrevious: fxPrevious) }

    func priceEUR(_ symbol: String) -> Double? { valuation.price(symbol) }

    /// Price in the listing's own currency.
    func nativePrice(_ symbol: String) -> Double? {
        guard let quote = quotes[symbol], let m = meta[symbol] else { return nil }
        return quote.price * m.scale
    }

    /// Pre-market or after-hours price in the listing's currency, if any.
    func extendedPrice(_ symbol: String) -> Double? {
        guard let extended = quotes[symbol]?.extendedPrice, let m = meta[symbol] else { return nil }
        return extended * m.scale
    }

    func dayPct(_ symbol: String) -> Double? { quotes[symbol]?.changePct }
    func value(_ holding: Holding) -> Double? { valuation.value(holding) }
    func dayChange(_ holding: Holding) -> Double? { valuation.dayChange(holding) }
    func cost(_ holding: Holding) -> Double? { valuation.cost(holding) }
    func unitCost(_ holding: Holding) -> Double? { valuation.unitCost(holding) }
    func gain(_ holding: Holding) -> Double? { valuation.gain(holding) }
    func gainPct(_ holding: Holding) -> Double? { valuation.gainPct(holding) }
    func realized(_ holding: Holding) -> Double? { valuation.realized(holding) }

    func holdings(in portfolioID: UUID?) -> [Holding] {
        // A source that could not name the listing reports the symbol; the name on record is better.
        let names = meta.compactMapValues { $0.name == $0.symbol ? nil : $0.name }
        return Holding.group(portfolios.filter { portfolioID == nil || $0.id == portfolioID }, names: names)
    }

    var visibleHoldings: [Holding] { holdings(in: selectedPortfolioID) }

    func holding(_ symbol: String) -> Holding? {
        visibleHoldings.first { $0.symbol == symbol } ?? holdings(in: nil).first { $0.symbol == symbol }
    }

    func totals(in portfolioID: UUID?) -> Totals { valuation.totals(holdings(in: portfolioID)) }

    var visibleTotals: Totals { totals(in: selectedPortfolioID) }

    var selectedPortfolioName: String {
        portfolios.first { $0.id == selectedPortfolioID }?.name ?? "All Portfolios"
    }

    /// Text for the menu bar item, or nil to show only the icon.
    var menuBarTitle: String? {
        let totals = totals(in: nil)
        guard totals.value > 0 else { return nil }
        // While sharing is likely, fall back to the percentage, which reveals no amounts.
        let mode = amountsHidden && menuBarMode.showsAmounts ? MenuBarMode.percent : menuBarMode
        let arrow = totals.day >= 0 ? "▲" : "▼"
        let pct = (abs(totals.dayPct) / 100).formatted(.percent.precision(.fractionLength(2)))
        let change = Fmt.money(abs(totals.day), decimals: 0)
        switch mode {
        case .icon: return nil
        case .percent: return "\(arrow) \(pct)"
        case .change: return "\(arrow) \(change)"
        case .changeAndPercent: return "\(arrow) \(change) · \(pct)"
        case .value: return "\(Fmt.compactEUR(totals.value)) \(arrow) \(pct)"
        }
    }
}
