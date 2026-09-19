import SwiftUI

/// Menu-bar app hosting the ccremote daemon. Panels: the status popover under the menu-bar
/// icon, a Pairing window (big QR), a Settings window, and a Log window.
@main
struct HostApp: App {
    @State private var model = HostModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            Image(systemName: model.menuSymbol)
                .onAppear {
                    // The label is the one view alive from launch: a fresh install opens the
                    // pairing window here so the user is not left hunting for a new icon.
                    if model.shouldShowPairingOnLaunch {
                        model.markPairingShown()
                        openWindow(id: WindowID.pairing)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Window("Pair your iPhone", id: WindowID.pairing) {
            PairingWindow(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("ClaudeRemote Host Settings", id: WindowID.settings) {
            SettingsWindow(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("ClaudeRemote Host Log", id: WindowID.log) {
            LogWindow(model: model)
        }
        .defaultSize(width: 720, height: 420)
    }
}

enum WindowID {
    static let pairing = "pairing"
    static let settings = "settings"
    static let log = "log"
}

/// Opens one of the app's windows from the menu-bar panel and brings the app forward
/// (an LSUIElement app does not activate on its own).
struct OpenWindowButton<Label: View>: View {
    let id: String
    @ViewBuilder var label: () -> Label
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            openWindow(id: id)
            NSApp.activate(ignoringOtherApps: true)
            dismiss()
        } label: {
            label()
        }
    }
}
