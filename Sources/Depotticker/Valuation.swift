import Foundation

/// Every money figure the app shows (value, today's change, cost, gain), computed in one place from
/// the latest prices and exchange rates. The app, the widget and the MCP server all use it, so the
/// three can never disagree. All results are in EUR.
struct Valuation {
    var quotes: [String: LiveQuote] = [:]
    var meta: [String: SymbolMeta] = [:]
    /// EUR value of one unit of each currency.
    var fx: [String: Double] = ["EUR": 1]
    /// The same rates at the previous close, so today's change includes the currency move.
    var fxPrevious: [String: Double] = ["EUR": 1]

    /// Price of one share in EUR.
    func price(_ symbol: String) -> Double? {
        guard let quote = quotes[symbol], let m = meta[symbol], let rate = fx[m.currency] else { return nil }
        return quote.price * m.scale * rate
    }

    func value(_ holding: Holding) -> Double? {
        price(holding.symbol).map { $0 * holding.quantity }
    }

    /// Today's change: value now minus value at the previous close, each at its own exchange rate.
    func dayChange(_ holding: Holding) -> Double? {
        guard let quote = quotes[holding.symbol], let m = meta[holding.symbol], let rate = fx[m.currency] else { return nil }
        let previousRate = fxPrevious[m.currency] ?? rate
        return (quote.price * rate - quote.previousClose * previousRate) * m.scale * holding.quantity
    }

    /// Amount paid at today's exchange rates, over the lots whose purchase price is known. Nil when
    /// no lot has a known price or a rate is missing.
    func cost(_ holding: Holding) -> Double? {
        var total = 0.0
        var known = false
        for lot in holding.lots where !lot.position.costUnknown {
            guard let rate = fx[lot.position.currency] else { return nil }
            total += lot.position.cost * rate
            known = true
        }
        return known ? total : nil
    }

    /// Average purchase price per share.
    func unitCost(_ holding: Holding) -> Double? {
        guard let cost = cost(holding), holding.costedQuantity > 0 else { return nil }
        return cost / holding.costedQuantity
    }

    /// Value minus cost of the shares whose purchase price is known. Bought in a foreign currency,
    /// this is the broker's own gain converted at today's rate.
    func gain(_ holding: Holding) -> Double? {
        guard let price = price(holding.symbol), let cost = cost(holding) else { return nil }
        return price * holding.costedQuantity - cost
    }

    func gainPct(_ holding: Holding) -> Double? {
        guard let gain = gain(holding), let cost = cost(holding), cost > 0 else { return nil }
        return gain / cost * 100
    }

    /// Profit already taken through recorded sales, at today's exchange rates. Nil when it cannot be
    /// stated: a sale out of shares of unknown cost, or a missing exchange rate.
    func realized(_ holding: Holding) -> Double? {
        var total = 0.0
        for lot in holding.lots where lot.position.hasSales {
            guard let realized = lot.position.realized, let rate = fx[lot.position.currency] else { return nil }
            total += realized * rate
        }
        return total
    }

    /// Sums over holdings. A holding without a price is counted as missing and adds nothing.
    func totals(_ holdings: [Holding]) -> Totals {
        var totals = Totals()
        for holding in holdings {
            totals.count += 1
            guard let value = value(holding) else {
                totals.missing += 1
                continue
            }
            totals.value += value
            totals.cost += cost(holding) ?? 0
            totals.gain += gain(holding) ?? 0
            totals.day += dayChange(holding) ?? 0
            if holding.lots.contains(where: { $0.position.costUnknown }) { totals.uncosted += 1 }
        }
        return totals
    }
}

extension Holding {
    /// One holding per symbol across the given portfolios, in the order the symbols first appear.
    /// `names` gives a better display name where one is known.
    static func group(_ portfolios: [Portfolio], names: [String: String] = [:]) -> [Holding] {
        var order: [String] = []
        var bySymbol: [String: Holding] = [:]
        for portfolio in portfolios {
            for position in portfolio.positions {
                let lot = Lot(portfolioID: portfolio.id, portfolioName: portfolio.name, position: position)
                if bySymbol[position.symbol] == nil {
                    order.append(position.symbol)
                    bySymbol[position.symbol] = Holding(symbol: position.symbol, name: names[position.symbol] ?? position.name,
                                                        lots: [lot])
                } else {
                    bySymbol[position.symbol]?.lots.append(lot)
                }
            }
        }
        return order.compactMap { bySymbol[$0] }
    }

    /// A single position seen as a holding.
    init(_ position: Position, in portfolio: Portfolio) {
        self.init(symbol: position.symbol, name: position.name,
                  lots: [Lot(portfolioID: portfolio.id, portfolioName: portfolio.name, position: position)])
    }
}
