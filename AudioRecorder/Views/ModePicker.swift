import SwiftUI
import AppKit

struct ModePicker: View {
    @AppStorage(Settings.modeKey) private var mode = AppMode.window
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Picker("Mode", selection: $mode) {
            ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .onChange(of: mode) { _, newMode in
            newMode.applyActivationPolicy()
            if newMode == .window {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } else {
                dismissWindow(id: "main")
            }
        }
    }
}
