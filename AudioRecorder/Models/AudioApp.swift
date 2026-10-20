import AppKit
import CoreAudio

/// An app that can be chosen as the recording source.
struct AudioApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    var icon: NSImage? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
            let icon = app.icon
        else { return nil }
        let small = icon.copy() as! NSImage
        small.size = NSSize(width: 16, height: 16)
        return small
    }
}

/// What to record: all system audio, or the processes of one app.
struct ResolvedSource {
    /// nil for "All system audio".
    let processObjects: [AudioObjectID]?
    /// nil for "All system audio".
    let appName: String?
}
