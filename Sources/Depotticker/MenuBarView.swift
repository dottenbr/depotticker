#if os(macOS)
import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        if let title = store.menuBarTitle {
            Text(title)
                .monospacedDigit()
        } else {
            Image(systemName: store.totals(in: nil).day >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
        }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject private var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let totals = store.totals(in: nil)
        let hidden = store.amountsHidden
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("All Portfolios")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(hidden ? "••••••" : (totals.value > 0 ? Fmt.money(totals.value) : "—"))
                    .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                Text(hidden ? "\(Fmt.pct(totals.dayPct)) today" : "\(Fmt.signedMoney(totals.day))  \(Fmt.pct(totals.dayPct)) today")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.trend(totals.day))
            }

            Divider()

            ForEach(store.portfolios) { portfolio in
                let sub = store.totals(in: portfolio.id)
                HStack {
                    Text(portfolio.name)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(hidden ? "••••" : Fmt.money(sub.value, decimals: 0))
                        .font(.system(size: 13).monospacedDigit())
                    Text(Fmt.pct(sub.dayPct))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.trend(sub.day))
                        .frame(width: 62, alignment: .trailing)
                }
            }

            Divider()

            Text("Biggest moves today")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(movers, id: \.0.id) { holding, pct in
                Button {
                    store.selectedPortfolioID = nil
                    store.selectedSymbol = holding.symbol
                    showMainWindow()
                } label: {
                    HStack {
                        Text(holding.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 70, alignment: .leading)
                        Text(holding.name)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(Fmt.pct(pct))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.trend(pct))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            Picker("Menu bar shows", selection: $store.menuBarMode) {
                ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
            }
            .font(.system(size: 12))
            if hidden {
                Label("Amounts hidden: call or screen sharing detected", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Open Depotticker") { showMainWindow() }
                Button("Settings…") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var movers: [(Holding, Double)] {
        store.holdings(in: nil)
            .compactMap { holding in store.dayPct(holding.symbol).map { (holding, $0) } }
            .sorted { abs($0.1) > abs($1.1) }
            .prefix(5)
            .map { $0 }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
