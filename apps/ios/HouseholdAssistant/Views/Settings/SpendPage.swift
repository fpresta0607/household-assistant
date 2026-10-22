// Spend: what the household's one OpenRouter key spent this month, the same on both
// phones. The month's total over one graph of it by day, the 1st on the left and the
// month's last day on the right, rising from zero to the total; then a line each for Corey
// and Denise, each led by its face in the ring its person picked, one for the rest of what
// used the key, and the total under them, their names and their amounts each in one
// column. Dollars only: no key, token or account detail reaches here.

import Charts
import SwiftUI

struct SpendPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// The day whose point was tapped, as `2026-10-07`, kept once the finger lifts.
    @State private var shownDay: String?
    /// The day under the finger, as the chart's own selection reports it.
    @State private var touchedDay: String?

    /// The screenshot tests open it with a day tapped.
    init(shownDay: String? = nil) {
        _shownDay = State(initialValue: shownDay)
    }

    var body: some View {
        let settings = model.assistantSettings
        SettingsPage("Spend") {
            if let spend = settings.spend {
                let month = SpendMonth(spend)
                let selected = month?.point(shownDay)
                SettingsGroup {
                    VStack(spacing: 14) {
                        VStack(spacing: 2) {
                            Text(Dollars.amount(selected?.spent ?? spend.total))
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .foregroundStyle(Palette.text)
                                .contentTransition(.numericText())
                            Text(selected.map { "By \($0.words)" } ?? "\(spend.monthName ?? spend.month) so far")
                                .font(.subheadline)
                                .foregroundStyle(Palette.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("spend.summary")
                        if let month {
                            graph(of: month)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                }
                SettingsGroup(note: "From OpenRouter, for the key the household shares, read every ten minutes. Other is what used it beyond both assistants' answers, voice and pictures. Starts again on \(spend.resetsOnWords ?? spend.resetsOn).") {
                    ForEach(spend.lines) { line in
                        amount(line.name, line.amount) {
                            if line.isAssistant {
                                ParticipantAvatar(participant: model.room.participant(line.id), size: Self.faceSize)
                            } else {
                                faceSpace
                            }
                        }
                    }
                    amount("Total", spend.total, isTotal: true) {
                        faceSpace
                    }
                }
            } else if settings.spendErrorText == nil {
                SettingsGroup {
                    SettingsRow("Reading this month's spend") {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            refreshStatus(settings)
        }
        .task(id: scenePhase == .active && model.connection.state == .connected) {
            if scenePhase == .active && model.connection.state == .connected {
                await settings.watchSpend()
            }
        }
        .refreshable {
            await settings.loadSpend()
        }
        .onChange(of: settings.spend?.month) { old, new in
            if old != new {
                shownDay = nil
                touchedDay = nil
            }
        }
    }

    private func refreshStatus(_ settings: AssistantSettingsModel) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let spend = settings.spend {
                        Text("Updated \(spend.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Spend isn't available yet")
                    }
                    Spacer(minLength: 8)
                    if settings.isLoadingSpend {
                        ProgressView().controlSize(.small)
                    }
                    Button("Refresh") {
                        Task { await settings.loadSpend() }
                    }
                    .disabled(settings.isLoadingSpend || model.connection.state != .connected)
                    .accessibilityIdentifier("spend.refresh")
                }
                if let error = settings.spendErrorText {
                    Text("Couldn't refresh spend. \(error)")
                } else if model.connection.state != .connected {
                    Text("Waiting for a connection to update spend.")
                } else if settings.spend?.isStale(at: context.date) == true {
                    Text("The spend source hasn't updated recently. Showing its last reading.")
                }
            }
            .font(.caption)
            .foregroundStyle(Palette.secondaryText)
            .accessibilityIdentifier("spend.update-status")
        }
    }

    private static let faceSize: CGFloat = 32

    /// Where a face would be, so the lines without one keep their names in the same column.
    private var faceSpace: some View {
        Color.clear
            .frame(width: Self.faceSize, height: Self.faceSize)
    }

    /// One line of the month, `leading` before its name and its amount at the end where
    /// every line's lines up.
    private func amount<Leading: View>(_ title: String, _ dollars: Double, isTotal: Bool = false, @ViewBuilder leading: () -> Leading) -> some View {
        SettingsRow(title, leading: leading) {
            Text(Dollars.amount(dollars))
                .font(isTotal ? Font.callout.weight(.semibold) : Font.callout)
                .monospacedDigit()
                .foregroundStyle(isTotal ? Palette.text : Palette.secondaryText)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }

    /// The month's total by the end of each day, from zero on the 1st to the total today,
    /// on an axis from zero to just above it, with the days still to come left empty. A tap
    /// or a drag across it shows a day's date and its total in the headline; with none
    /// shown, the month's first and last days sit at its ends.
    private func graph(of month: SpendMonth) -> some View {
        let shown = month.point(shownDay)
        let drawn = month.days.filter { $0.spent != nil }
        // Today's point marks where the month has got to, until a day is shown instead.
        let marked = shown ?? drawn.last
        return VStack(spacing: 8) {
            Chart {
                ForEach(drawn) { day in
                    AreaMark(x: .value("Day", day.id), y: .value("Dollars", day.spent ?? 0))
                        .foregroundStyle(LinearGradient(
                            colors: [Palette.highlight.opacity(0.35), Palette.highlight.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        .interpolationMethod(.monotone)
                        .accessibilityHidden(true)
                    LineMark(x: .value("Day", day.id), y: .value("Dollars", day.spent ?? 0))
                        .foregroundStyle(Palette.highlight)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                        .accessibilityLabel(Text(day.words))
                        .accessibilityValue(Text(Dollars.amount(day.spent ?? 0)))
                }
                if let shown {
                    RuleMark(x: .value("Day", shown.id))
                        .foregroundStyle(Palette.secondaryText.opacity(0.4))
                        .accessibilityHidden(true)
                }
                if let marked, let spent = marked.spent {
                    PointMark(x: .value("Day", marked.id), y: .value("Dollars", spent))
                        .foregroundStyle(Palette.highlight)
                        .symbolSize(70)
                        .accessibilityHidden(true)
                }
            }
            // The axis is every day of the month in date order, so each point takes its
            // place by its date and the days still to come keep theirs, and it runs from
            // zero to just above the month's total.
            .chartXScale(domain: month.days.map(\.id))
            .chartYScale(domain: 0...month.top)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, month.top / 2, month.top]) { value in
                    AxisGridLine()
                        .foregroundStyle(Palette.secondaryText.opacity(0.2))
                    AxisValueLabel {
                        if let dollars = value.as(Double.self) {
                            Text(Dollars.price(dollars))
                                .font(.caption2)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                }
            }
            // Save the selection as it arrives. Observing touchedDay with onChange can
            // miss a quick tap when the chart sets and clears it in the same update.
            .chartXSelection(value: Binding<String?>(
                get: { touchedDay },
                set: { id in
                    touchedDay = id
                    if let id {
                        shownDay = month.selecting(id, showing: shownDay)
                    }
                }
            ))
            .chartGesture { proxy in
                // One continuous gesture handles a quick touch and scrubbing alike.
                // An exclusive tap/drag pair can let the surrounding scroll view
                // win after the tap fails, leaving the first day's value selected.
                DragGesture(minimumDistance: 0)
                    .onChanged { proxy.selectXValue(at: $0.location.x) }
                    .onEnded { proxy.selectXValue(at: $0.location.x) }
            }
            .frame(height: 150)
            .accessibilityLabel("This month's spend by day")
            .accessibilityIdentifier("spend.chart")
            HStack {
                if shown != nil {
                    Button("Show month total") {
                        shownDay = nil
                        touchedDay = nil
                    }
                    .accessibilityIdentifier("spend.show-month")
                    Spacer()
                    Text(Dollars.amount(month.total))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(Palette.text)
                } else if let first = month.days.first, let last = month.days.last {
                    Text(first.words)
                    Spacer()
                    Text(last.words)
                }
            }
            .font(.caption)
            .foregroundStyle(Palette.secondaryText)
            .accessibilityElement(children: .contain)
        }
        .animation(Motion.flip(reduced: reduceMotion), value: shownDay)
        .haptic(.selection, trigger: shownDay)
    }
}

