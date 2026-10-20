import AppKit

/// Shows an open panel and returns the chosen folder path, or nil if cancelled.
func chooseFolderPath() -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url?.path : nil
}
