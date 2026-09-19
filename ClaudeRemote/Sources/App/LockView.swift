import SwiftUI

/// Full-screen cover shown when the app is locked; unlocks with Face ID / passcode.
struct LockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill").font(.system(size: 44, weight: .semibold)).foregroundStyle(.secondary)
                Text("ClaudeRemote").font(.title2.weight(.semibold))
                Text("Locked").font(.subheadline).foregroundStyle(.secondary)
                Button {
                    model.unlock()
                } label: {
                    Label("Unlock", systemImage: "faceid").frame(maxWidth: 220)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .onAppear { model.unlock() }   // prompt immediately
    }
}
