import Charts
import SwiftUI

/// Range picker plus an interactive line chart with optional indicators.
/// Pinch changes the time range, drag measures between two points, hover inspects a point.
struct ChartPanel: View {
    var points: [ChartPoint]
    /// Dashed reference line (previous close), if any.
    var baseline: Double?
    var color: Color
    /// The owner's average purchase price in the chart's currency, if it applies.
    var averageCost: Double?
    /// Benchmark lines, aligned with `points`.
    var comparisons: [ChartComparison] = []
    var ranges: [ChartRange] = ChartRange.allCases
    var error: String?
    @Binding var range: ChartRange
    @Binding var hoverIndex: Int?
    @Binding var dragStart: Int?

    @AppStorage("chartVolume") private var showVolume = true
    @AppStorage("chartAverage") private var showAverage = false
    @AppStorage("chartExtremes") private var showExtremes = true
    @AppStorage("chartCost") private var showCost = true
    @AppStorage("chartSessions") private var showSessions = true
    @AppStorage("chartCompare") private var showComparisons = true
    @State private var pinchHandled = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var hasVolume: Bool { points.contains { ($0.volume ?? 0) > 0 } }

    var body: some View {
        VStack(spacing: 12) {
            rangePicker
            chart
                .frame(height: 300)
                .gesture(pinch)
            if showVolume, hasVolume, points.count > 1 {
                volumeChart
                    .frame(height: 54)
            }
            HStack {
                if sizeClass != .compact {
                    Text("Pinch to change the time range · drag across the chart to measure a move")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                indicatorMenu
            }
        }
    }

    // MARK: Controls

    private var rangePicker: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: sizeClass == .compact ? 3 : 6) {
                ForEach(ranges) { item in
                    Button {
                        withAnimation(.snappy) { range = item }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: sizeClass == .compact ? 11 : 12, weight: range == item ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(range == item ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(range == item ? .regular.tint(Color.accentColor).interactive() : .regular.interactive(),
                                 in: .capsule)
                }
            }
        }
    }

    private var indicatorMenu: some View {
        Menu {
            Toggle("Trading volume", isOn: $showVolume)
            Toggle("Moving average (20)", isOn: $showAverage)
            Toggle("High and low", isOn: $showExtremes)
            Toggle("My average cost", isOn: $showCost)
            Toggle("Trading day separators", isOn: $showSessions)
            if !comparisons.isEmpty {
                Toggle("Compare with the market", isOn: $showComparisons)
            }
        } label: {
            Label("Indicators", systemImage: "slider.horizontal.3")
                .font(.caption)
        }
        .compactMenu()
        .help("Choose what the chart shows")
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !pinchHandled, let index = ranges.firstIndex(of: range) else { return }
                if value.magnification > 1.25, index > 0 {
                    pinchHandled = true
                    withAnimation(.snappy) { range = ranges[index - 1] }
                } else if value.magnification < 0.8, index < ranges.count - 1 {
                    pinchHandled = true
                    withAnimation(.snappy) { range = ranges[index + 1] }
                }
            }
            .onEnded { _ in pinchHandled = false }
    }

    // MARK: Derived series

    /// Simple moving average over the last 20 points.
    private var movingAverage: [(index: Int, value: Double)] {
        let window = 20
        guard points.count > window else { return [] }
        var result: [(Int, Double)] = []
        var sum = 0.0
        for (index, point) in points.enumerated() {
            sum += point.price
            if index >= window { sum -= points[index - window].price }
            if index >= window - 1 { result.append((index, sum / Double(window))) }
        }
        return result
    }

    /// Indices where a new trading day starts (only meaningful on intraday multi-day ranges).
    private var sessionStarts: [Int] {
        guard range == .week || range == .month else { return [] }
        let calendar = Calendar.current
        var result: [Int] = []
        for index in points.indices.dropFirst()
        where !calendar.isDate(points[index].date, inSameDayAs: points[index - 1].date) {
            result.append(index)
        }
        return result
    }

    private var extremes: (high: Int, low: Int)? {
        guard points.count > 2,
              let high = points.indices.max(by: { points[$0].price < points[$1].price }),
              let low = points.indices.min(by: { points[$0].price < points[$1].price }),
              high != low
        else { return nil }
        return (high, low)
    }

    // MARK: Price chart

    @ViewBuilder
    private var chart: some View {
        if points.count > 1 {
            let compared = showComparisons ? comparisons.filter { $0.values.count == points.count } : []
            let prices = points.map(\.price) + [baseline].compactMap { $0 } + compared.flatMap(\.values)
            let lo = prices.min() ?? 0
            let hi = prices.max() ?? 1
            let pad = max((hi - lo) * 0.1, hi * 0.0005)
            let floor = lo - pad
            let ceiling = hi + pad
            // Only draw the cost line when it lies inside the visible price range.
            let cost = showCost ? averageCost.flatMap { (floor...ceiling).contains($0) ? $0 : nil } : nil

            Chart {
                priceMarks(floor: floor)
                comparisonMarks(compared)
                overlayMarks(cost: cost)
                selectionMarks
            }
            .chartYScale(domain: floor...ceiling)
            .chartXScale(domain: 0...Double(points.count - 1))
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: ticks(count: points.count)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let raw = value.as(Double.self), points.indices.contains(Int(raw)) {
                            Text(points[Int(raw)].date.formatted(range.axisFormat))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(hi >= 100_000 ? Fmt.compact(raw) : Fmt.number(raw, decimals: hi < 20 ? 2 : (hi < 1000 ? 1 : 0)))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let indexAt: (CGPoint) -> Int? = { location in
                        guard let frame = proxy.plotFrame else { return nil }
                        let x = location.x - geo[frame].origin.x
                        guard let raw = proxy.value(atX: x, as: Double.self) else { return nil }
                        return min(max(Int(raw.rounded()), 0), points.count - 1)
                    }
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                if dragStart == nil, let index = indexAt(location) { hoverIndex = index }
                            case .ended:
                                if dragStart == nil { hoverIndex = nil }
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { value in
                                    if dragStart == nil { dragStart = indexAt(value.startLocation) }
                                    if let index = indexAt(value.location) { hoverIndex = index }
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                }
            }
        } else if let error {
            ContentUnavailableView("Chart unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ChartContentBuilder
    private func priceMarks(floor: Double) -> some ChartContent {
        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
            AreaMark(x: .value("Index", Double(index)),
                     yStart: .value("Floor", floor),
                     yEnd: .value("Price", point.price))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.0)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Index", Double(index)), y: .value("Price", point.price),
                     series: .value("Series", "price"))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
        }
    }

    @ChartContentBuilder
    private func comparisonMarks(_ compared: [ChartComparison]) -> some ChartContent {
        ForEach(compared) { comparison in
            ForEach(Array(comparison.values.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("Index", Double(index)), y: .value("Value", value),
                         series: .value("Series", comparison.name))
                    .foregroundStyle(comparison.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            }
        }
    }

    @ChartContentBuilder
    private func overlayMarks(cost: Double?) -> some ChartContent {
        if showSessions {
            ForEach(sessionStarts, id: \.self) { index in
                RuleMark(x: .value("Index", Double(index) - 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.28))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
        if showAverage {
            ForEach(movingAverage, id: \.index) { item in
                LineMark(x: .value("Index", Double(item.index)), y: .value("Average", item.value),
                         series: .value("Series", "average"))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
        }
        if let baseline {
            RuleMark(y: .value("Previous close", baseline))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("Previous close").font(.system(size: 9)).foregroundStyle(.secondary)
                }
        }
        if let cost {
            RuleMark(y: .value("Average cost", cost))
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("Your average cost").font(.system(size: 9)).foregroundStyle(Color.accentColor)
                }
        }
        if showExtremes, let extremes {
            PointMark(x: .value("Index", Double(extremes.high)), y: .value("Price", points[extremes.high].price))
                .foregroundStyle(Color.primary.opacity(0.7))
                .symbolSize(22)
                .annotation(position: .top) {
                    Text("H \(Fmt.number(points[extremes.high].price))").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            PointMark(x: .value("Index", Double(extremes.low)), y: .value("Price", points[extremes.low].price))
                .foregroundStyle(Color.primary.opacity(0.7))
                .symbolSize(22)
                .annotation(position: .bottom) {
                    Text("L \(Fmt.number(points[extremes.low].price))").font(.system(size: 9)).foregroundStyle(.secondary)
                }
        }
    }

    @ChartContentBuilder
    private var selectionMarks: some ChartContent {
        if let dragStart, let hoverIndex, points.indices.contains(dragStart) {
            RectangleMark(xStart: .value("From", Double(min(dragStart, hoverIndex))),
                          xEnd: .value("To", Double(max(dragStart, hoverIndex))))
                .foregroundStyle(Color.accentColor.opacity(0.14))
            RuleMark(x: .value("Index", Double(dragStart)))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        if let hoverIndex, points.indices.contains(hoverIndex) {
            RuleMark(x: .value("Index", Double(hoverIndex)))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1))
            PointMark(x: .value("Index", Double(hoverIndex)), y: .value("Price", points[hoverIndex].price))
                .foregroundStyle(color)
                .symbolSize(60)
        }
    }

    // MARK: Volume chart

    private var volumeChart: some View {
        let shown = hoverIndex.flatMap { points.indices.contains($0) ? points[$0].volume : nil }
        let total = points.reduce(0) { $0 + ($1.volume ?? 0) }
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                BarMark(x: .value("Index", Double(index)), y: .value("Volume", point.volume ?? 0))
                    .foregroundStyle(barColor(index))
            }
        }
        .chartXScale(domain: 0...Double(points.count - 1))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisValueLabel {
                    if let raw = value.as(Double.self) { Text(Fmt.compact(raw)) }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Text(shown.map { "Volume \(Fmt.compact($0))" } ?? "Volume \(Fmt.compact(total)) in this period")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Green when the price rose against the previous point, red when it fell.
    private func barColor(_ index: Int) -> Color {
        if index == hoverIndex { return .primary }
        guard index > 0 else { return Color.secondary.opacity(0.5) }
        return (points[index].price >= points[index - 1].price ? Color.up : Color.down).opacity(0.55)
    }

    private func ticks(count: Int) -> [Double] {
        guard count > 1 else { return [] }
        return (0..<5).map { Double($0 * (count - 1) / 5) }
    }
}

/// Text for the chart header: a single hovered point or a measured span.
func chartCaption(points: [ChartPoint], hoverIndex: Int?, dragStart: Int?, range: ChartRange) -> String {
    guard let hoverIndex, points.indices.contains(hoverIndex) else { return range.label }
    let end = points[hoverIndex].date.formatted(range.hoverFormat)
    guard let dragStart, points.indices.contains(dragStart) else { return end }
    return "\(points[dragStart].date.formatted(range.hoverFormat)) → \(end)"
}
