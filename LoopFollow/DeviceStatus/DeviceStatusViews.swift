// LoopFollow
// DeviceStatusViews.swift

import SwiftUI

// MARK: - Current state

/// What Nightscout currently says about the sensor and the pod, read from the
/// values the Nightscout fetches keep in Storage.
struct DeviceStatusSnapshot {
    var sensorKind: SensorKind
    var sensorID: String?
    var sensor: DeviceLifecycle?

    var pumpKind: PumpKind
    var pumpModel: String?
    var pod: DeviceLifecycle?
    /// Units left, nil when the pump only reports "50+".
    var reservoir: Double?

    static var current: DeviceStatusSnapshot {
        let storage = Storage.shared
        let sensorID = storage.sageSensorID.value
        let sensorKind = SensorKind.detect(deviceName: storage.cgmDeviceName.value, sensorID: sensorID)
        let sensorStart = storage.sageInsertTime.value
        let pumpKind = PumpKind.detect(model: storage.pumpModel.value)
        let podStart = storage.cageInsertTime.value

        return DeviceStatusSnapshot(
            sensorKind: sensorKind,
            sensorID: sensorID,
            sensor: sensorStart > 0 ? sensorKind.lifecycle(startingAt: Date(timeIntervalSince1970: sensorStart)) : nil,
            pumpKind: pumpKind,
            pumpModel: storage.pumpModel.value,
            pod: podStart > 0 ? pumpKind.lifecycle(startingAt: Date(timeIntervalSince1970: podStart)) : nil,
            reservoir: storage.lastPumpReservoirU.value
        )
    }

    var reservoirText: String? {
        if let reservoir {
            return Localizer.formatToLocalizedString(reservoir, maxFractionDigits: 0) + " " + DeviceStatusFormat.unitsSymbol
        }
        // A pump that reports no level has more than 50 U left (Omnipod) — but only
        // say so once a device status with a pump in it has been seen.
        return pumpModel == nil ? nil : "50+ " + DeviceStatusFormat.unitsSymbol
    }

    /// Fill fraction for the reservoir drawing; Omnipod reports levels up to 50 U.
    var reservoirFill: Double {
        guard let reservoir else { return 1 }
        return min(1, max(0, reservoir / 50))
    }

    var reservoirLevel: DeviceLifecycle.Level {
        let level = reservoir ?? 50
        let config = InfoType.pump.colorConfig
        if level <= (config?.defaultUrgent ?? 10) { return .critical }
        if level <= (config?.defaultWarning ?? 20) { return .warning }
        return .normal
    }
}

enum DeviceStatusFormat {
    static let unitsSymbol = String(localized: "U", table: "DeviceStatus", comment: "Symbol for insulin units")

    /// "1d 6h" — the short form used on the home screen tiles.
    static func short(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = interval >= 3600 ? [.day, .hour] : [.minute]
        return formatter.string(from: max(60, interval)) ?? ""
    }

    /// "6 d 22 h ago" style text for how long ago something was put on.
    static func ago(_ date: Date, now: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute]
        let elapsed = formatter.string(from: max(60, now.timeIntervalSince(date))) ?? ""
        return String(localized: "\(elapsed) ago", table: "DeviceStatus", comment: "How long ago a sensor or pod was put on, e.g. '6d 22h ago'")
    }

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMMjjmm")
        return formatter
    }()

    /// Splits a remaining time into the big number + unit pairs Loop shows on its
    /// pod screen: days and hours, then hours and minutes for the last two hours.
    static func components(_ interval: TimeInterval) -> [(value: Int, unit: String)] {
        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        var parts: [(Int, NSCalendar.Unit)] = []
        if days > 0 { parts.append((days, .day)) }
        if interval >= 3600 { parts.append((hours, .hour)) }
        if interval < 2 * 3600 { parts.append((minutes, .minute)) }
        return parts.map { ($0.0, unitWord($0.0, $0.1)) }
    }

    /// The localized unit word for a value ("dag"/"dager"), taken from the system's
    /// own duration formatting so plurals come out right in every language.
    private static func unitWord(_ value: Int, _ unit: NSCalendar.Unit) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [unit]
        var components = DateComponents()
        switch unit {
        case .day: components.day = value
        case .hour: components.hour = value
        default: components.minute = value
        }
        let text = formatter.string(from: components) ?? ""
        return String(text.drop(while: { $0.isNumber || $0.isWhitespace }))
    }
}

extension DeviceLifecycle.Level {
    func color(normal: Color) -> Color {
        switch self {
        case .normal: return normal
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private let sensorTint = Color.teal
private let podTint = Color.blue

// MARK: - Home screen strip

/// Two tiles under the glucose display — sensor and pod — each with the time
/// left and a lifecycle bar, like the HUD at the top of Loop. Tapping one opens
/// the Loop-style detail screen for it.
struct DeviceStatusStrip: View {
    @ObservedObject var infoManager: InfoManager

    @ObservedObject private var sageInsertTime = Storage.shared.sageInsertTime
    @ObservedObject private var sageSensorID = Storage.shared.sageSensorID
    @ObservedObject private var cgmDeviceName = Storage.shared.cgmDeviceName
    @ObservedObject private var cageInsertTime = Storage.shared.cageInsertTime
    @ObservedObject private var pumpModel = Storage.shared.pumpModel
    @ObservedObject private var reservoir = Storage.shared.lastPumpReservoirU

    @State private var shown: DeviceSheet?

    enum DeviceSheet: String, Identifiable {
        case sensor, pod
        var id: String { rawValue }
    }

    var body: some View {
        let snapshot = DeviceStatusSnapshot.current
        if snapshot.sensor != nil || snapshot.pod != nil {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 8) {
                    Button { shown = .sensor } label: {
                        sensorTile(snapshot, now: context.date)
                    }
                    Button { shown = .pod } label: {
                        podTile(snapshot, now: context.date)
                    }
                }
                .buttonStyle(.plain)
            }
            .sheet(item: $shown) { sheet in
                NavigationStack {
                    switch sheet {
                    case .sensor: SensorDetailView()
                    case .pod: PodDetailView(infoManager: infoManager)
                    }
                }
            }
        }
    }

    private func sensorTile(_ snapshot: DeviceStatusSnapshot, now: Date) -> some View {
        DeviceTile(
            imageName: snapshot.sensorKind.imageName,
            symbolName: "sensor.tag.radiowaves.forward.fill",
            title: String(localized: "Sensor", table: "DeviceStatus", comment: "Title of the sensor tile on the home screen"),
            lifecycle: snapshot.sensor,
            tint: sensorTint,
            now: now
        )
    }

    private func podTile(_ snapshot: DeviceStatusSnapshot, now: Date) -> some View {
        DeviceTile(
            imageName: snapshot.pumpKind.imageName,
            symbolName: "cross.vial.fill",
            title: snapshot.pumpKind.shortName,
            lifecycle: snapshot.pod,
            tint: podTint,
            now: now,
            trailing: snapshot.reservoirText.map { text in
                AnyView(
                    HStack(spacing: 3) {
                        ReservoirGauge(fill: snapshot.reservoirFill,
                                       color: snapshot.reservoirLevel.color(normal: podTint))
                            .frame(width: 11, height: 15)
                        Text(text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(snapshot.reservoirLevel.color(normal: .primary))
                    }
                )
            }
        )
    }
}

private struct DeviceTile: View {
    let imageName: String?
    let symbolName: String
    let title: String
    let lifecycle: DeviceLifecycle?
    let tint: Color
    let now: Date
    var trailing: AnyView? = nil

    var body: some View {
        let level = lifecycle?.level(at: now) ?? .normal
        let barColor = lifecycle == nil ? Color.secondary : level.color(normal: tint)

        HStack(spacing: 8) {
            icon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Text(remainingText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(level == .normal ? .primary : barColor)
                    if let trailing {
                        Text("·").foregroundStyle(.secondary)
                        trailing
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                ProgressView(value: lifecycle?.progress(at: now) ?? 0)
                    .tint(barColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var icon: some View {
        if let imageName {
            Image(imageName)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
        }
    }

    private var remainingText: String {
        guard let lifecycle else { return "—" }
        switch lifecycle.phase(at: now) {
        case .warmup:
            return "⏳ " + DeviceStatusFormat.short(lifecycle.remaining(at: now) ?? 0)
        case .active, .grace:
            return DeviceStatusFormat.short(lifecycle.remaining(at: now) ?? 0)
        case .expired:
            return String(localized: "Expired", table: "DeviceStatus", comment: "Tile text when a sensor or pod is past its end")
        }
    }
}

// MARK: - Shared detail pieces

/// Loop's lifecycle header: a label, the time left in big numbers, and the bar.
private struct LifecycleProgress: View {
    let label: String
    let lifecycle: DeviceLifecycle
    let tint: Color
    let now: Date

    var body: some View {
        let level = lifecycle.level(at: now)
        VStack(spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(label)
                    .foregroundStyle(level == .critical ? Color.red : .secondary)
                Spacer()
                if let remaining = lifecycle.remaining(at: now) {
                    ForEach(Array(DeviceStatusFormat.components(remaining).enumerated()), id: \.offset) { _, part in
                        Text(String(part.value))
                            .font(.system(size: 28, weight: .heavy))
                            .monospacedDigit()
                        Text(part.unit)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ProgressView(value: lifecycle.progress(at: now))
                .tint(level.color(normal: tint))
        }
        .padding(.vertical, 4)
    }
}

private struct DeviceHeaderImage: View {
    let imageName: String?
    let symbolName: String
    let tint: Color

    var body: some View {
        Group {
            if let imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: symbolName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint)
                    .padding(20)
            }
        }
        .frame(height: 100)
        .frame(maxWidth: .infinity)
    }
}

/// The pod reservoir drawing from OmnipodKit, filled to the level left.
struct ReservoirGauge: View {
    let fill: Double
    let color: Color

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let offset = geometry.size.height * 0.05
                let fillHeight = geometry.size.height * 0.81
                Rectangle()
                    .fill(color)
                    .mask(Image("pod_reservoir_mask_swiftui").resizable().scaledToFit())
                    .mask(
                        Rectangle().path(in: CGRect(x: 0,
                                                    y: offset + fillHeight - fillHeight * fill,
                                                    width: geometry.size.width,
                                                    height: fillHeight * fill))
                    )
            }
            Image("pod_reservoir_swiftui")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
        }
    }
}

private struct DateRow: View {
    let title: String
    let date: Date
    var subtitle: String? = nil

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(DeviceStatusFormat.dateTime.string(from: date))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

private func doneButton(_ dismiss: DismissAction) -> some ToolbarContent {
    ToolbarItem(placement: .confirmationAction) {
        Button(String(localized: "Done", table: "DeviceStatus", comment: "Closes the sensor or pod screen")) { dismiss() }
    }
}

// MARK: - Sensor screen

/// The sensor as Loop shows it on its Dexcom G7 screen.
struct SensorDetailView: View {
    @ObservedObject private var sageInsertTime = Storage.shared.sageInsertTime
    @ObservedObject private var sageSensorID = Storage.shared.sageSensorID
    @ObservedObject private var cgmDeviceName = Storage.shared.cgmDeviceName
    @ObservedObject private var bgText = Observable.shared.bgText
    @ObservedObject private var bgTextColor = Observable.shared.bgTextColor
    @ObservedObject private var directionText = Observable.shared.directionText
    @ObservedObject private var minAgoText = Observable.shared.minAgoText

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let snapshot = DeviceStatusSnapshot.current
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                Section {
                    VStack(spacing: 8) {
                        DeviceHeaderImage(imageName: snapshot.sensorKind.imageName,
                                          symbolName: "sensor.tag.radiowaves.forward.fill",
                                          tint: sensorTint)
                        if let sensor = snapshot.sensor {
                            LifecycleProgress(label: label(for: sensor, now: context.date),
                                              lifecycle: sensor, tint: sensorTint, now: context.date)
                        }
                    }
                }

                if let sensor = snapshot.sensor {
                    Section {
                        DateRow(title: String(localized: "Sensor Start", table: "DeviceStatus", comment: "Row: when the sensor was started"),
                                date: sensor.start,
                                subtitle: DeviceStatusFormat.ago(sensor.start, now: context.date))
                        DateRow(title: String(localized: "Sensor Expiration", table: "DeviceStatus", comment: "Row: when the sensor's lifetime ends"),
                                date: sensor.expiration)
                        if sensor.grace > 0 {
                            DateRow(title: String(localized: "Grace Period End", table: "DeviceStatus", comment: "Row: when the sensor's grace period ends and it stops"),
                                    date: sensor.graceEnd)
                        }
                        if let sensorID = snapshot.sensorID {
                            ValueRow(title: String(localized: "Sensor ID", table: "DeviceStatus", comment: "Row: the sensor's ID"),
                                     value: sensorID)
                        }
                    }
                } else {
                    Section {
                        Text(String(localized: "Nightscout has no sensor start yet.", table: "DeviceStatus", comment: "Shown when no Sensor Start treatment was found"))
                            .foregroundStyle(.secondary)
                    }
                }

                Section(String(localized: "Last Reading", table: "DeviceStatus", comment: "Section header for the latest glucose reading")) {
                    HStack {
                        Text(String(localized: "Glucose", table: "DeviceStatus", comment: "Row: latest glucose value"))
                        Spacer()
                        Text("\(bgText.value) \(directionText.value)")
                            .foregroundStyle(bgTextColor.value)
                    }
                    ValueRow(title: String(localized: "Time", table: "DeviceStatus", comment: "Row: how old the latest reading is"),
                             value: minAgoText.value)
                }

                Section {
                } footer: {
                    Text(String(localized: "Worked out from the sensor start Loop uploads to Nightscout.", table: "DeviceStatus", comment: "Footer on the sensor screen explaining where the times come from"))
                }
            }
        }
        .navigationTitle(snapshot.sensorKind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { doneButton(dismiss) }
    }

    private func label(for sensor: DeviceLifecycle, now: Date) -> String {
        switch sensor.phase(at: now) {
        case .warmup:
            return String(localized: "Warmup completes in", table: "DeviceStatus", comment: "Sensor lifecycle label during warmup")
        case .active:
            return String(localized: "Sensor expires in", table: "DeviceStatus", comment: "Sensor lifecycle label while the sensor is in its lifetime")
        case .grace:
            return String(localized: "Grace period remaining", table: "DeviceStatus", comment: "Sensor lifecycle label in the grace period")
        case .expired:
            return String(localized: "Sensor expired", table: "DeviceStatus", comment: "Sensor lifecycle label after the grace period")
        }
    }
}

// MARK: - Pod screen

/// The pod as Loop shows it on its Omnipod screen.
struct PodDetailView: View {
    @ObservedObject var infoManager: InfoManager

    @ObservedObject private var cageInsertTime = Storage.shared.cageInsertTime
    @ObservedObject private var pumpModel = Storage.shared.pumpModel
    @ObservedObject private var reservoir = Storage.shared.lastPumpReservoirU

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let snapshot = DeviceStatusSnapshot.current
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                Section {
                    VStack(spacing: 8) {
                        DeviceHeaderImage(imageName: snapshot.pumpKind.imageName,
                                          symbolName: "cross.vial.fill",
                                          tint: podTint)
                        if let pod = snapshot.pod {
                            LifecycleProgress(label: label(for: pod, kind: snapshot.pumpKind, now: context.date),
                                              lifecycle: pod, tint: podTint, now: context.date)
                        }
                        HStack(alignment: .top) {
                            basalStatus
                            Spacer()
                            reservoirStatus(snapshot)
                        }
                        .padding(.top, 4)
                    }
                }

                if let pod = snapshot.pod {
                    Section {
                        DateRow(title: snapshot.pumpKind == .omnipod
                                    ? String(localized: "Activation", table: "DeviceStatus", comment: "Row: when the pod was put on")
                                    : String(localized: "Changed", table: "DeviceStatus", comment: "Row: when the infusion set was changed"),
                                date: pod.start,
                                subtitle: DeviceStatusFormat.ago(pod.start, now: context.date))
                        DateRow(title: String(localized: "Expiration", table: "DeviceStatus", comment: "Row: when the pod expires"),
                                date: pod.expiration)
                        if pod.grace > 0 {
                            DateRow(title: String(localized: "No Delivery", table: "DeviceStatus", comment: "Row: when the pod stops delivering insulin"),
                                    date: pod.graceEnd)
                        }
                    }
                } else {
                    Section {
                        Text(String(localized: "Nightscout has no pod change yet.", table: "DeviceStatus", comment: "Shown when no Site Change treatment was found"))
                            .foregroundStyle(.secondary)
                    }
                }

                if let model = snapshot.pumpModel {
                    Section {
                        ValueRow(title: String(localized: "Pump", table: "DeviceStatus", comment: "Row: pump model"), value: model)
                    } footer: {
                        Text(String(localized: "Worked out from the pod changes Loop uploads to Nightscout. Loop records a change when the cannula is in, so times can be a few minutes later than in Loop.", table: "DeviceStatus", comment: "Footer on the pod screen explaining where the times come from"))
                    }
                }
            }
        }
        .navigationTitle(snapshot.pumpModel ?? snapshot.pumpKind.shortName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { doneButton(dismiss) }
    }

    private var basalStatus: some View {
        let basal = infoManager.tableData[InfoType.basal.rawValue].value
        return VStack(alignment: .leading, spacing: 5) {
            Text(String(localized: "Basal", table: "DeviceStatus", comment: "Header for the current basal rate on the pod screen"))
                .foregroundStyle(.secondary)
            Text(basal.isEmpty ? "—" : basal + " " + String(localized: "U/hr", table: "DeviceStatus", comment: "Unit for the basal rate on the pod screen"))
                .font(.system(size: 22, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    private func reservoirStatus(_ snapshot: DeviceStatusSnapshot) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(String(localized: "Insulin Remaining", table: "DeviceStatus", comment: "Header for insulin left in the pod"))
                .foregroundStyle(.secondary)
            HStack {
                let color = snapshot.reservoirLevel.color(normal: podTint)
                ReservoirGauge(fill: snapshot.reservoirFill, color: color)
                    .frame(width: 23, height: 32)
                Text(snapshot.reservoirText ?? "—")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(snapshot.reservoirLevel == .normal ? .primary : color)
                    .fixedSize()
            }
        }
    }

    private func label(for pod: DeviceLifecycle, kind: PumpKind, now: Date) -> String {
        switch (pod.phase(at: now), kind) {
        case (.warmup, _), (.active, .omnipod):
            return String(localized: "Pod expires in", table: "DeviceStatus", comment: "Pod lifecycle label while the pod is in its 72 hours")
        case (.active, .other):
            return String(localized: "Change due in", table: "DeviceStatus", comment: "Infusion set lifecycle label")
        case (.grace, _):
            return String(localized: "Pod expired, delivery stops in", table: "DeviceStatus", comment: "Pod lifecycle label between 72 and 80 hours")
        case (.expired, .omnipod):
            return String(localized: "Pod expired", table: "DeviceStatus", comment: "Pod lifecycle label after 80 hours")
        case (.expired, .other):
            return String(localized: "Change overdue", table: "DeviceStatus", comment: "Infusion set lifecycle label when past due")
        }
    }
}
