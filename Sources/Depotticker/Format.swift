import SwiftUI

enum Fmt {
    static func money(_ value: Double, _ code: String = "EUR", decimals: Int = 2) -> String {
        value.formatted(.currency(code: code).precision(.fractionLength(decimals)))
    }

    static func signedMoney(_ value: Double, _ code: String = "EUR", decimals: Int = 2) -> String {
        value.formatted(
            .currency(code: code).precision(.fractionLength(decimals)).sign(strategy: .always())
        )
    }

    static func pct(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(2)).sign(strategy: .always()))
    }

    static func plainPct(_ value: Double, decimals: Int = 1) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(decimals)))
    }

    static func quantity(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }

    static func number(_ value: Double, decimals: Int = 2) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)))
    }

    static func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func compactEUR(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000 {
            return (value / 1_000_000).formatted(.number.precision(.fractionLength(2))) + " M €"
        }
        if magnitude >= 10_000 {
            return (value / 1_000).formatted(.number.precision(.fractionLength(1))) + " k €"
        }
        return money(value, decimals: 0)
    }
}

extension Color {
    static let up = Color(red: 0.19, green: 0.78, blue: 0.40)
    static let down = Color(red: 0.96, green: 0.27, blue: 0.27)

    #if os(macOS)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    #else
    static let windowBackground = Color(uiColor: .systemBackground)
    #endif

    static func trend(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        return value >= 0 ? .up : .down
    }
}

/// Tiny intraday line used in the list rows.
struct Sparkline: View {
    var values: [Double]
    var baseline: Double?
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let all = values + (baseline.map { [$0] } ?? [])
            if values.count > 1, let lo = all.min(), let hi = all.max(), hi > lo {
                let y: (Double) -> CGFloat = { geo.size.height * (1 - CGFloat(($0 - lo) / (hi - lo))) }
                let step = geo.size.width / CGFloat(values.count - 1)
                ZStack {
                    if let baseline {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y(baseline)))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y(baseline)))
                        }
                        .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    }
                    Path { path in
                        for (index, value) in values.enumerated() {
                            let point = CGPoint(x: CGFloat(index) * step, y: y(value))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                }
            }
        }
    }
}

/// Coloured capsule showing a change value.
struct ChangePill: View {
    var text: String
    var trend: Double?

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(minWidth: 74, minHeight: 22, alignment: .trailing)
            .background(trend == nil ? Color.gray.opacity(0.5) : Color.trend(trend), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Lays its children out side by side, or stacked when the width is compact (iPhone).
struct AdaptiveStack<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if sizeClass == .compact {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(alignment: .top, spacing: spacing) { content }
        }
    }
}

extension View {
    /// Icon-only pull-down menu without the system chrome.
    @ViewBuilder
    func compactMenu() -> some View {
        #if os(macOS)
        self.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        #else
        self.menuIndicator(.hidden).fixedSize()
        #endif
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// Soft colour wash behind the content so the glass surfaces have something to refract.
struct AmbientBackground: View {
    var trend: Double?

    var body: some View {
        let color = Color.trend(trend)
        ZStack {
            Color.windowBackground
            LinearGradient(colors: [color.opacity(0.26), color.opacity(0.06), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.accentColor.opacity(0.16), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 620)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: (trend ?? 0) >= 0)
    }
}

struct Stat: View {
    var label: String
    var value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
