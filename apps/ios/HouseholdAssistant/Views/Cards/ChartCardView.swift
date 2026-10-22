// A bar or line chart drawn with Swift Charts, in the soft rainbow: one hue per bar when
// there is one series of no more bars than the rainbow has hues, one hue for them all past
// that, and one per series when there are more. A line passes through every value and
// never beyond it, so it shows no reading that was not taken. Past a few labels the x axis
// names a readable few, and VoiceOver reads every label with its values.
//
// A chart that arrives in a live reply draws itself in: the bars grow one after another,
// the line draws from left to right. One already in the conversation is simply there,
// and with Reduce Motion nothing moves.

import Charts
import SwiftUI

struct ChartCardView: View {
    let chart: ChartCard
    let isArriving: Bool

    @Environment(\.reducesMotion) private var reduceMotion
    /// How many labels' bars have grown.
    @State private var grown: Int
    /// How much of the line has drawn, from nothing to all of it.
    @State private var drawn: CGFloat

    init(chart: ChartCard, isArriving: Bool) {
        self.chart = chart
        self.isArriving = isArriving
        _grown = State(initialValue: isArriving ? 0 : chart.labels.count)
        _drawn = State(initialValue: isArriving ? 0 : 1)
    }

    /// One value of one series, for the marks.
    private struct Point: Identifiable {
        let id: Int
        let series: String
        let label: String
        let labelIndex: Int
        let value: Double
    }

    private var points: [Point] {
        chart.series.enumerated().flatMap { seriesIndex, series in
            series.values.enumerated().map { labelIndex, value in
                Point(
                    id: seriesIndex * chart.labels.count + labelIndex,
                    series: series.name,
                    label: chart.labels[labelIndex],
                    labelIndex: labelIndex,
                    value: value
                )
            }
        }
    }

    private var isSingleSeries: Bool {
        chart.series.count == 1
    }

    /// Sky blue's place in the rainbow: the one hue of a single series with more bars than
    /// the rainbow has hues.
    private static let manyBarsHue = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = chart.title {
                Text(title)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(CardStyle.ink.opacity(0.75))
                    .accessibilityAddTraits(.isHeader)
            }
            Group {
                switch chart.kind {
                case .bar:
                    bars
                case .line:
                    line
                }
            }
            .frame(height: 160)
            .chartXAxis {
                AxisMarks(values: chart.axisLabels) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CardStyle.secondaryInk)
                }
            }
            .chartYAxis {
                if !chart.showsValuesOnBars {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                            .foregroundStyle(CardStyle.hairline)
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(chart.text(for: number))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(CardStyle.secondaryInk)
                    }
                }
            }
            .chartForegroundStyleScale(domain: chart.series.map(\.name), range: chart.series.indices.map(CardStyle.hue))
            .chartLegend(isSingleSeries ? .hidden : .visible)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chart.kind == .bar ? "Bar chart" : "Line chart")
            .accessibilityValue(chart.readings.joined(separator: ". "))
        }
        .padding(12)
        .cardPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chart.title ?? "Chart")
        .task {
            await drawIn()
        }
    }

    private var bars: some View {
        let highest = max(points.map(\.value).max() ?? 0, 0)
        let lowest = min(points.map(\.value).min() ?? 0, 0)
        return Chart(points) { point in
            bar(point)
                .cornerRadius(6)
                .position(by: .value("Series", point.series))
                .annotation(position: .top, spacing: 3) {
                    if chart.showsValuesOnBars, point.labelIndex < grown {
                        Text(chart.text(for: point.value))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(CardStyle.ink)
                    }
                }
        }
        .chartYScale(domain: lowest...(highest > 0 ? highest * 1.2 : 1))
    }

    /// One series: each bar its own hue, deepening toward its base, or past the rainbow's
    /// seven every bar sky blue, rather than the rainbow over and over. More: each series
    /// its own hue, named in the legend.
    @ChartContentBuilder
    private func bar(_ point: Point) -> some ChartContent {
        let shown = point.labelIndex < grown ? point.value : 0
        if isSingleSeries {
            let hue = chart.labels.count <= CardStyle.rainbow.count ? point.labelIndex : Self.manyBarsHue
            BarMark(x: .value("Label", point.label), y: .value("Value", shown))
                .foregroundStyle(LinearGradient(
                    colors: [CardStyle.lightHue(hue), CardStyle.hue(hue)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
        } else {
            BarMark(x: .value("Label", point.label), y: .value("Value", shown))
                .foregroundStyle(by: .value("Series", point.series))
        }
    }

    private var line: some View {
        let range = chart.lineRange
        let drawn = self.drawn
        return Chart(points) { point in
            if isSingleSeries {
                AreaMark(
                    x: .value("Label", point.label),
                    yStart: .value("Floor", range.lowerBound),
                    yEnd: .value("Value", point.value)
                )
                .foregroundStyle(LinearGradient(colors: [CardStyle.indigo.opacity(0.3), CardStyle.indigo.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Label", point.label),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(LinearGradient(colors: CardStyle.lineRainbow, startPoint: .leading, endPoint: .trailing))
                .lineStyle(StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
                PointMark(
                    x: .value("Label", point.label),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(pointHue(point))
                .symbolSize(50)
            } else {
                LineMark(
                    x: .value("Label", point.label),
                    y: .value("Value", point.value),
                    series: .value("Series", point.series)
                )
                .foregroundStyle(by: .value("Series", point.series))
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
                .symbol(.circle)
            }
        }
        .chartYScale(domain: range)
        // Only the plot draws in: masking the whole chart cut off the axis labels that sit
        // past its edges, the top value's and the last time's.
        .chartPlotStyle { plot in
            plot.mask(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle()
                        .frame(width: proxy.size.width * drawn)
                }
            }
        }
    }

    /// Each point takes its place along the rainbow the single line runs through.
    private func pointHue(_ point: Point) -> Color {
        let hues = CardStyle.lineRainbow
        let last = max(chart.labels.count - 1, 1)
        return hues[point.labelIndex * (hues.count - 1) / last]
    }

    private func drawIn() async {
        guard grown < chart.labels.count || drawn < 1 else {
            return
        }
        guard !reduceMotion else {
            grown = chart.labels.count
            drawn = 1
            return
        }
        switch chart.kind {
        case .bar:
            for bar in grown..<chart.labels.count {
                try? await Task.sleep(for: Motion.growStep)
                withAnimation(Motion.grow) {
                    grown = bar + 1
                }
            }
        case .line:
            withAnimation(Motion.draw) {
                drawn = 1
            }
        }
    }
}
