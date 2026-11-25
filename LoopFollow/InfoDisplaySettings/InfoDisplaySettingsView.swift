// LoopFollow
// InfoDisplaySettingsView.swift

import SwiftUI

struct InfoDisplaySettingsView: View {
    @ObservedObject var viewModel: InfoDisplaySettingsViewModel
    @State private var selectedID: Int?
    // Observed so the placement picker redraws when it is changed.
    @ObservedObject private var hideInfoTable = Storage.shared.hideInfoTable
    @ObservedObject private var infoTableOnHome = Storage.shared.infoTableOnHome

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "On Home", table: "Home", comment: "Setting: where Home shows the information table"), selection: Binding(
                    get: { InfoTablePlacement.current },
                    set: { $0.apply() }
                )) {
                    ForEach(InfoTablePlacement.allCases) { placement in
                        Text(placement.title).tag(placement)
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text(String(localized: "Home shows active insulin, active carbs, basal and the forecast. The rows below are the full table.", table: "Home", comment: "Footer of the information table placement setting"))
            }

            Section(
                header: Text("Information Display Settings"),
                footer: Text("Drag to reorder. Tap a row to set its visibility and colors.")
            ) {
                // The list stays in edit mode so rows are always draggable; a
                // Button (unlike NavigationLink) still receives taps in edit
                // mode, so reordering and navigation work at the same time.
                ForEach(viewModel.items) { item in
                    Button {
                        selectedID = item.id
                    } label: {
                        rowLabel(for: item)
                    }
                    .buttonStyle(.plain)
                }
                .onMove(perform: viewModel.move)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationDestination(isPresented: Binding(
            get: { selectedID != nil },
            set: { if !$0 { selectedID = nil } }
        )) {
            if let id = selectedID {
                InfoRowSettingsView(item: viewModel.binding(for: id))
            }
        }
        .onDisappear {
            NotificationCenter.default.post(name: NSNotification.Name("refresh"), object: nil)
        }
        .preferredColorScheme(Storage.shared.appearanceMode.value.colorScheme)
        .navigationBarTitle("Information Display Settings", displayMode: .inline)
    }

    private func rowLabel(for item: InfoDisplayItem) -> some View {
        HStack {
            Text(item.type.name)
            Spacer()
            if item.type.isColorable, item.coloring.enabled {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Coloring enabled")
            }
            Text(item.isVisible ? String(localized: "On") : String(localized: "Off"))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// Where Home shows the information table. Stored in the two settings that
/// already existed, so «Hide Information Table» keeps its meaning.
enum InfoTablePlacement: String, CaseIterable, Identifiable {
    /// Behind a tap on the four numbers (the default).
    case behindTap
    /// As a card of its own on Home.
    case card
    /// Not at all.
    case hidden

    var id: String { rawValue }

    static var current: InfoTablePlacement {
        if Storage.shared.hideInfoTable.value { return .hidden }
        return Storage.shared.infoTableOnHome.value ? .card : .behindTap
    }

    func apply() {
        Storage.shared.hideInfoTable.value = self == .hidden
        Storage.shared.infoTableOnHome.value = self == .card
    }

    var title: String {
        switch self {
        case .behindTap: return String(localized: "Tap the numbers", table: "Home", comment: "Information table placement: opens with a tap on Home's four numbers")
        case .card: return String(localized: "Always shown", table: "Home", comment: "Information table placement: a card on Home")
        case .hidden: return String(localized: "Hidden", table: "Home", comment: "Information table placement: not shown")
        }
    }
}
