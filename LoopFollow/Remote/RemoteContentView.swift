// LoopFollow
// RemoteContentView.swift

import SwiftUI

struct RemoteContentView: View {
    @ObservedObject private var device = Storage.shared.device
    @ObservedObject private var remoteType = Storage.shared.remoteType
    /// False when pushed onto the Menu's navigation stack, which already has one.
    var embedsInNavigationStack: Bool = true

    var body: some View {
        Group {
            switch remoteType.value {
            case .trc:
                if device.value == "Trio" {
                    TrioRemoteControlView(viewModel: TrioRemoteControlViewModel())
                } else {
                    Text("Trio Remote Control is only supported for 'Trio'")
                }

            case .loopAPNS:
                LoopAPNSRemoteView(embedsInNavigationStack: embedsInNavigationStack)

            case .none:
                Text("Please select a Remote Type in Settings.")
            }
        }
    }
}
