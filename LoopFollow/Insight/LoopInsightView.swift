// LoopFollow
// LoopInsightView.swift

// The insight tab, laid out like Loop's own: the situation now, today, this week and suggested
// settings, short; the rest behind «Vis detaljer» — as Loop last put it in Nightscout.

import SwiftUI

struct LoopInsightView: View {
    @ObservedObject var store: LoopInsightStore = .shared
    /// False when shown inside the menu's navigation stack.
    var embedsInNavigationStack = true

    private var status: LoopInsightStatus? { store.document?.insight }

    var body: some View {
        if embedsInNavigationStack {
            NavigationStack { content }
        } else {
            content
        }
    }

    @State private var showsDetails = false

    /// Today's text and numbers, only while they are from today.
    private var todayText: LoopInsightText? {
        status?.todayText.flatMap { Calendar.current.isDateInToday($0.createdAt) ? $0 : nil }
    }

    private var today: LoopInsightToday? {
        status?.today.flatMap { Calendar.current.isDateInToday($0.computedAt) ? $0 : nil }
    }

    private var content: some View {
        List {
            nowSection
            todaySection
            weekSection
            if let suggestions = status?.longTermText?.suggestions, !suggestions.isEmpty {
                suggestionsSection(suggestions)
            }
            if hasDetails {
                detailsSection
            }
            updateSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Insight", table: "LoopInsight", comment: "Title of the insight tab"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(force: true)
        }
        .task {
            await store.refresh()
            // Loop updates it at most every half hour; reading every five minutes while open keeps up.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                await store.refresh()
            }
        }
    }

    // MARK: Now

    @ViewBuilder
    private var nowSection: some View {
        Section {
            if let text = todayText, let now = text.now {
                VStack(alignment: .leading, spacing: 10) {
                    Text(now)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = text.action {
                        Label {
                            Text(action).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "hand.point.right.fill").foregroundColor(.orange)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    Text(text.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else if store.document?.aiEnabled == true {
                Text(String(localized: "The AI looks at the situation every half hour from 06:00.", table: "LoopInsight", comment: "Shown before the AI has written about the situation now"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else if store.document == nil {
                Text(String(localized: "Nothing from Loop yet. Loop puts the insight in Nightscout, and it is read from there.", table: "LoopInsight", comment: "Insight tab before anything was read"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text(String(localized: "Now", table: "LoopInsight", comment: "Header of the situation now in the insight tab"))
        }
    }

    // MARK: Today

    @ViewBuilder
    private var todaySection: some View {
        Section {
            if let text = todayText, !text.summary.isEmpty {
                Text(text.summary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let today, let period = today.period {
                PeriodRow(period: period, hoursAboveTen: today.hoursAboveTen)
            } else if store.document != nil, status?.today == nil {
                Text(String(localized: "No numbers yet. Loop reads them from Nightscout.", table: "LoopInsight", comment: "Insight tab: the document has no numbers yet"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text(String(localized: "Today", table: "LoopInsight", comment: "Header of today's section in the insight tab"))
        }
    }

    // MARK: This week

    @ViewBuilder
    private var weekSection: some View {
        Section {
            if let text = status?.longTermText, !text.summary.isEmpty {
                Text(text.summary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.document?.aiEnabled == true {
                Text(String(localized: "The AI looks at the week each night after 04:00.", table: "LoopInsight", comment: "Shown before the AI has written about the week"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if let week = status?.longTerm?.last7Days {
                LabeledValue(label: String(localized: "Last 7 days", table: "LoopInsight", comment: "Insight: last seven days"), value: periodSummary(week))
            }
        } header: {
            Text(String(localized: "This Week", table: "LoopInsight", comment: "Header of the week section in the insight tab"))
        }
    }

    // MARK: Suggested settings

    private func suggestionsSection(_ suggestions: [LoopInsightSuggestion]) -> some View {
        Section {
            ForEach(suggestions, id: \.self) { suggestion in
                SuggestionRow(suggestion: suggestion)
            }
        } header: {
            Text(String(localized: "Suggested Settings", table: "LoopInsight", comment: "Header of the suggested therapy settings changes in the insight tab"))
        } footer: {
            Text(String(localized: "Only patterns seen on at least three days. Talk it over with the diabetes team before changing anything.", table: "LoopInsight", comment: "Footer of the suggested therapy settings changes in the insight tab"))
        }
    }

    // MARK: Details

    private var hasDetails: Bool {
        if let todayText, !todayText.doseHints.isEmpty { return true }
        if let today, today.forecastDeviationMmol != nil || !today.meals.isEmpty { return true }
        if let text = status?.longTermText, !text.points.isEmpty || !text.doseHints.isEmpty { return true }
        if let longTerm = status?.longTerm, !longTerm.dayparts.isEmpty || !longTerm.advice.isEmpty { return true }
        return false
    }

    private var detailsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsDetails) {
                if let text = todayText {
                    hints(text.doseHints)
                }
                if let today, let deviation = today.forecastDeviationMmol {
                    Label {
                        Text(deviationText(deviation)).font(.subheadline)
                    } icon: {
                        Image(systemName: deviation > 0 ? "arrow.up.right" : deviation < 0 ? "arrow.down.right" : "equal")
                            .foregroundColor(abs(deviation) >= 1 ? .orange : .secondary)
                    }
                }
                if let today {
                    ForEach(today.meals, id: \.date) { meal in
                        MealRow(meal: meal)
                    }
                }
                if let text = status?.longTermText {
                    ForEach(text.points, id: \.self) { point in
                        Text(verbatim: "• \(point)")
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    hints(text.doseHints)
                }
                if let longTerm = status?.longTerm {
                    ForEach(longTerm.dayparts, id: \.name) { part in
                        DaypartRow(part: part)
                    }
                    if !longTerm.advice.isEmpty {
                        let accepted = longTerm.advice.filter(\.accepted)
                        LabeledValue(
                            label: String(localized: "AI doses shown / used", table: "LoopInsight", comment: "Insight: AI doses shown and used"),
                            value: "\(longTerm.advice.count) / \(accepted.count)"
                        )
                        ForEach(longTerm.advice.suffix(5).reversed(), id: \.date) { record in
                            AdviceRow(record: record)
                        }
                    }
                }
            } label: {
                Text(String(localized: "Show Details", table: "LoopInsight", comment: "Disclosure for the details behind the insight"))
            }
        }
    }

    private func hints(_ hints: [String]) -> some View {
        ForEach(hints, id: \.self) { hint in
            Label {
                Text(hint).font(.footnote).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lightbulb").foregroundColor(.purple)
            }
        }
    }

    private func deviationText(_ deviation: Double) -> String {
        if deviation >= 1 || deviation <= -1 {
            let value = mmol(abs(deviation))
            return deviation > 0
                ? String(format: NSLocalizedString("Loop is forecasting %@ mmol/L lower than usual today: more insulin is needed than usual.", tableName: "LoopInsight", comment: "Insight: today's forecast deviation, more insulin needed (1: mmol/L)"), value)
                : String(format: NSLocalizedString("Loop is forecasting %@ mmol/L higher than usual today: less insulin is needed than usual.", tableName: "LoopInsight", comment: "Insight: today's forecast deviation, less insulin needed (1: mmol/L)"), value)
        }
        return String(format: NSLocalizedString("Loop's forecast is about as usual today (%@ mmol/L).", tableName: "LoopInsight", comment: "Insight: today's forecast deviation is small (1: signed mmol/L)"), signed(deviation))
    }

    // MARK: Updating

    private var updateSection: some View {
        Section {
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                HStack {
                    Text(String(localized: "Update Now", table: "LoopInsight", comment: "Button reading the insight from Nightscout again"))
                    Spacer()
                    if store.isLoading {
                        ProgressView()
                    }
                }
            }
            .disabled(store.isLoading)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let document = store.document {
                    Text(String(format: NSLocalizedString("From Loop %@.", tableName: "LoopInsight", comment: "Insight: when Loop last uploaded it (1: time)"), document.uploadedAt.formatted(date: Calendar.current.isDateInToday(document.uploadedAt) ? .omitted : .abbreviated, time: .shortened)))
                    if let updated = document.insight.dataUpdatedAt {
                        Text(String(format: NSLocalizedString("Numbers from Nightscout %@.", tableName: "LoopInsight", comment: "Insight: when Loop read the numbers (1: time)"), updated.formatted(date: .omitted, time: .shortened)))
                    }
                    if let error = document.insight.lastError {
                        Text(error).foregroundColor(.orange)
                    }
                    if document.aiEnabled {
                        Text(String(format: NSLocalizedString("AI in Loop today: %1$@ calls, about $%2$@ (about %3$@ kr).", tableName: "LoopInsight", comment: "Insight: OpenAI use today in Loop (1: calls)(2: dollars)(3: kroner)"),
                                    "\(document.aiUsageToday.calls)",
                                    document.aiUsageToday.dollars.formatted(.number.precision(.fractionLength(2))),
                                    (document.aiUsageToday.dollars * 10.5).formatted(.number.precision(.fractionLength(0)))))
                    } else {
                        Text(String(localized: "AI Dose Advice is off in Loop, so only the numbers are shown.", table: "LoopInsight", comment: "Insight: AI is off in Loop"))
                    }
                }
                if let error = store.errorMessage {
                    Text(error).foregroundColor(.red)
                }
            }
        }
    }

    private func periodSummary(_ period: LoopInsightPeriod) -> String {
        String(format: NSLocalizedString("%1$d %% in range · %2$@ mean · %3$d lows", tableName: "LoopInsight", comment: "Insight: a period's summary (1: percent in range)(2: mean mmol/L)(3: low episodes)"),
               period.timeInRangePercent, mmol(period.meanMmol), period.lowEpisodes)
    }
}

// MARK: - Rows

private func mmol(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
}

private func signed(_ value: Double) -> String {
    (value > 0 ? "+" : value < 0 ? "−" : "") + mmol(abs(value))
}

private let unitsSymbol = String(localized: "U", table: "LoopInsight", comment: "Symbol for insulin units")
private let hoursSymbol = String(localized: "h", table: "LoopInsight", comment: "Symbol for hours")

private struct SuggestionRow: View {
    let suggestion: LoopInsightSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(title) \(String(format: "%02d", suggestion.startHour))–\(String(format: "%02d", suggestion.endHour))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(verbatim: "\(value(suggestion.current)) → \(value(suggestion.proposed)) \(unit)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(suggestion.givesMoreInsulin ? .orange : .blue)
            }
            Text(suggestion.reason)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        switch suggestion.setting {
        case .carbRatio: return String(localized: "Carb ratio", table: "LoopInsight", comment: "Insight suggestion: carb ratio")
        case .insulinSensitivity: return String(localized: "Insulin sensitivity", table: "LoopInsight", comment: "Insight suggestion: insulin sensitivity")
        case .basalRate: return String(localized: "Basal rate", table: "LoopInsight", comment: "Insight suggestion: basal rate")
        }
    }

    private var unit: String {
        switch suggestion.setting {
        case .carbRatio: return "g/" + unitsSymbol
        case .insulinSensitivity: return "mmol/L/" + unitsSymbol
        case .basalRate: return unitsSymbol + "/" + hoursSymbol
        }
    }

    private func value(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct PeriodRow: View {
    let period: LoopInsightPeriod
    let hoursAboveTen: Double

    var body: some View {
        HStack {
            stat("\(period.timeInRangePercent) %", String(localized: "in range", table: "LoopInsight", comment: "Insight: time in range label"))
            stat(mmol(period.meanMmol), String(localized: "mean", table: "LoopInsight", comment: "Insight: mean glucose label"))
            stat("\(period.lowEpisodes)", String(localized: "lows", table: "LoopInsight", comment: "Insight: low episodes label"))
            stat(hoursAboveTen.formatted(.number.precision(.fractionLength(1))) + " " + hoursSymbol, String(localized: "over 10", table: "LoopInsight", comment: "Insight: hours above 10 mmol/L label"))
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MealRow: View {
    let meal: LoopInsightMeal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(meal.date.formatted(date: .omitted, time: .shortened)).font(.subheadline.monospacedDigit())
                Text(meal.foods.isEmpty ? "🍽" : meal.foods.joined(separator: " + ")).font(.subheadline).lineLimit(1)
                Spacer()
                Text(verbatim: "\(Int(meal.carbsGrams)) g · \(meal.bolusUnits.formatted(.number.precision(.fractionLength(0 ... 2)))) \(unitsSymbol)")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Text(curve)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var curve: String {
        var parts: [String] = []
        if let start = meal.startMmol { parts.append(mmol(start)) }
        if let peak = meal.peakMmol { parts.append("↑ " + mmol(peak)) }
        if let after = meal.after3hMmol { parts.append("3 \(hoursSymbol) " + mmol(after)) }
        if let lowest = meal.lowestWithin4hMmol, lowest < 3.9 { parts.append("⚠︎ " + mmol(lowest)) }
        var text = parts.joined(separator: " → ")
        let flags = meal.flags.filter { $0 != .unfinished }
        if !flags.isEmpty {
            text += " · " + flags.map(Self.flagText).joined(separator: ", ")
        }
        if meal.flags.contains(.unfinished) {
            text += " · " + Self.flagText(.unfinished)
        }
        return text
    }

    static func flagText(_ flag: LoopInsightMeal.Flag) -> String {
        switch flag {
        case .extraCarbs: return String(localized: "extra carbs", table: "LoopInsight", comment: "Insight meal flag")
        case .correction: return String(localized: "correction", table: "LoopInsight", comment: "Insight meal flag")
        case .treatedLow: return String(localized: "treated low", table: "LoopInsight", comment: "Insight meal flag")
        case .startedLow: return String(localized: "started low", table: "LoopInsight", comment: "Insight meal flag")
        case .unfinished: return String(localized: "still going", table: "LoopInsight", comment: "Insight: a meal less than four hours ago")
        }
    }
}

private struct DaypartRow: View {
    let part: LoopInsightDaypart

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(part.name.capitalized).font(.subheadline.weight(.semibold))
                Spacer()
                if let week = part.last7Days, let month = part.last30Days {
                    Text(String(format: NSLocalizedString("%1$d %% · 30 d %2$d %%", tableName: "LoopInsight", comment: "Insight: time in range last 7 and 30 days (1: 7 days)(2: 30 days)"), week.timeInRangePercent, month.timeInRangePercent))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            details
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// One line of text that wraps as a sentence, with the worrying numbers in colour.
    private var details: Text {
        var parts: [Text] = []
        if let error = part.loopForecastError2hMmol {
            parts.append(Text(verbatim: "Loop\u{00A0}2\u{00A0}\(hoursSymbol)\u{00A0}\(signed(error))").foregroundColor(abs(error) >= 1.5 ? .orange : .secondary))
        }
        if part.cleanMeals > 0 {
            parts.append(Text(String(format: NSLocalizedString("%d meals", tableName: "LoopInsight", comment: "Insight: clean meals in a part of the day"), part.cleanMeals)).foregroundColor(.secondary))
            if let low = part.lowAfterMealPercent {
                parts.append(Text(String(format: NSLocalizedString("low after %d %%", tableName: "LoopInsight", comment: "Insight: share of meals followed by a low"), low)).foregroundColor(low >= 20 ? .red : .secondary))
            }
            if let high = part.highAt3hPercent {
                parts.append(Text(String(format: NSLocalizedString(">10 at 3 h %d %%", tableName: "LoopInsight", comment: "Insight: share of meals above 10 three hours on"), high)).foregroundColor(high >= 40 ? .orange : .secondary))
            }
        }
        guard let first = parts.first else { return Text(verbatim: "") }
        return parts.dropFirst().reduce(first) { $0 + Text(verbatim: "  ·  ").foregroundColor(.secondary) + $1 }
    }
}

private struct AdviceRow: View {
    let record: LoopInsightAdvice

    var body: some View {
        HStack {
            Text(record.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                .font(.footnote.monospacedDigit())
            Spacer()
            Text(verbatim: "AI \(record.suggestedUnits.formatted(.number.precision(.fractionLength(0 ... 2)))) / Loop \((record.loopUnits ?? 0).formatted(.number.precision(.fractionLength(0 ... 2)))) \(unitsSymbol)")
                .font(.footnote)
                .foregroundColor(record.accepted ? .purple : .secondary)
            if let after = record.after3hMmol {
                Text(verbatim: "→ \(mmol(after))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if let lowest = record.lowestWithin4hMmol, lowest < 3.9 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).font(.footnote)
            }
        }
    }
}
