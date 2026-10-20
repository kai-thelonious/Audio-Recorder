import AppKit
import SwiftUI

struct ModePicker: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var settings = settings
        Picker("Mode", selection: $settings.mode) {
            ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .onChange(of: settings.mode) { _, newMode in
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
