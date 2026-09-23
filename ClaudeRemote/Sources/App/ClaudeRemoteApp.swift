import SwiftUI

@main
struct ClaudeRemoteApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(model)
                    .fullScreenCover(item: Bindable(model).imageViewer) { ImageViewer(target: $0) }
                if model.locked {
                    LockView().environment(model).transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.locked)
            .onAppear { WatchBridge.shared.syncActivePairing() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.lockOnBackground(); model.enteredBackground() }
                if phase == .active { WatchBridge.shared.syncActivePairing(); model.enteredForeground() }
            }
        }
    }
}
