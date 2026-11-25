// LoopFollow
// HomeNumbersCard.swift

import SwiftUI

/// Four labelled numbers under the HUD: insulin on board, carbs on board, the
/// basal rate running now and where Loop expects the glucose in 30 minutes.
/// Tapping the card opens the full information table, unless it is hidden or
/// already on Home.
struct HomeNumbersCard: View {
    @ObservedObject var infoManager: InfoManager
    /// The information table is available behind a tap on the card.
    var opensInfoTable: Bool
    var timeZoneOverride: String?

    @ObservedObject private var loopPrediction = Observable.shared.loopPrediction
    @ObservedObject private var predictionText = Observable.shared.predictionText
    @ObservedObject private var retro = RetroSelection.shared

    @State private var showingInfoTable = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(alignment: .top, spacing: 6) {
                number(label: String(localized: "Active insulin", table: "Home", comment: "Home: insulin on board"),
                       value: value(.iob).flatMap { HomeNumbers.withUnit($0, DeviceStatusFormat.unitsSymbol) },
                       tint: HomePalette.insulin)
                number(label: String(localized: "Active carbs", table: "Home", comment: "Home: carbs on board"),
                       value: value(.cob).flatMap { HomeNumbers.withUnit($0, String(localized: "g", table: "Home", comment: "Symbol for grams")) },
                       tint: HomePalette.carbs)
                number(label: String(localized: "Basal", table: "Home", comment: "Home: the basal rate running now"),
                       value: value(.basal).flatMap(HomeNumbers.currentBasal(fromInfoValue:)).map {
                           $0 + " " + String(localized: "U/hr", table: "DeviceStatus")
                       },
                       tint: HomePalette.basal)
                prediction(now: context.date)
                if opensInfoTable {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 12)
                        .accessibilityHidden(true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .homeCard(padding: 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if opensInfoTable { showingInfoTable = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(opensInfoTable ? .isButton : [])
        .accessibilityHint(opensInfoTable ? String(localized: "Shows all values", table: "Home") : "")
        .sheet(isPresented: $showingInfoTable) {
            NavigationStack {
                InfoTableView(infoManager: infoManager, timeZoneOverride: timeZoneOverride)
                    .padding(.horizontal, 12)
                    .navigationTitle(String(localized: "All values", table: "Home", comment: "Title of the information table opened from Home"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done", table: "Home")) { showingInfoTable = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// The live value of an info row, or the value at the scrubbed time while the chart is scrubbed.
    private func value(_ type: InfoType) -> String? {
        if let snapshot = retro.snapshot {
            return snapshot.rows[type]?.value
        }
        guard type.rawValue < infoManager.tableData.count else { return nil }
        let value = infoManager.tableData[type.rawValue].value
        return value.isEmpty ? nil : value
    }

    @ViewBuilder
    private func prediction(now: Date) -> some View {
        let inThirty = retro.snapshot == nil ? loopPrediction.value?.value(at: now.addingTimeInterval(30 * 60)) : nil
        if let inThirty {
            number(label: String(localized: "In 30 min", table: "Home", comment: "Home: Loop's forecast 30 minutes from now"),
                   value: Localizer.formatQuantity(inThirty),
                   tint: HomePalette.prediction)
        } else {
            // Other systems (and the scrubbed past) only give where the glucose ends up.
            let eventual = retro.snapshot?.predictionText ?? predictionText.value
            number(label: String(localized: "Forecast", table: "Home", comment: "Home: where the forecast ends up, when there is no 30-minute value"),
                   value: eventual.isEmpty ? nil : eventual,
                   tint: HomePalette.prediction)
        }
    }

    private func number(label: String, value: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value ?? "—")
                .font(.callout.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The information table as a card on Home, in two columns, for those who
/// choose to keep it on screen.
struct HomeInfoTableCard: View {
    @ObservedObject var infoManager: InfoManager
    var timeZoneOverride: String?
    @ObservedObject private var retro = RetroSelection.shared

    private struct Row: Identifiable {
        let id: Int
        let name: String
        let value: String
        let color: Color?
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if let timeZoneOverride {
            rows.append(Row(id: -1, name: String(localized: "Time Zone"), value: timeZoneOverride, color: nil))
        }
        for item in infoManager.visibleRows {
            let type = InfoType(rawValue: item.id)
            let value: String
            let numeric: Double?
            if let snapshot = retro.snapshot {
                let retroRow = type.flatMap { snapshot.rows[$0] }
                value = retroRow?.value ?? ""
                numeric = retroRow?.numericValue
            } else {
                value = item.value
                numeric = item.numericValue
            }
            rows.append(Row(id: item.id, name: item.name, value: value.isEmpty ? "—" : value, color: color(type, numeric)))
        }
        return rows
    }

    private func color(_ type: InfoType?, _ numeric: Double?) -> Color? {
        guard let type, let numeric, let config = type.colorConfig else { return nil }
        return Storage.shared.infoDisplayItems.value.item(for: type)?
            .coloring.color(for: numeric, direction: config.direction)
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                HStack(spacing: 4) {
                    Text(row.name)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Text(row.value)
                        .fontWeight(.medium)
                        .foregroundStyle(row.color ?? .primary)
                }
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .homeCard(padding: 10)
    }
}
