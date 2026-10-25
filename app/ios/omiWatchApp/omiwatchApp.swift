import SwiftUI

@main
struct omiwatch_Watch_AppApp: App {
    @StateObject private var viewModel = WatchAudioRecorderViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if viewModel.isRecording || viewModel.isStarting {
                    WatchRecorderView(viewModel: viewModel)
                } else {
                    WatchQuickCaptureView(capture: viewModel.quickCapture, recorder: viewModel)
                }
            }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { viewModel.retryRecoveryTransfers() }
                }
        }
    }
}
