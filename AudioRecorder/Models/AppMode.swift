import AppKit

enum AppMode: String, CaseIterable, Identifiable {
    case window = "Window"
    case menuBarOnly = "Menu bar only"

    var id: String { rawValue }

    /// Dock icon in window mode, none in menu bar only mode.
    func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(self == .window ? .regular : .accessory)
    }
}
