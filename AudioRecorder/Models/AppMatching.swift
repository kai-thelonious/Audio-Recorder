import Foundation

/// A running app, reduced to what's needed to match audio processes to it.
struct RunningApp: Equatable {
    let bundleID: String
    let pid: pid_t
}

enum AppMatching {
    /// How many ancestors of an audio process are checked when its bundle ID
    /// doesn't match any app.
    static let maxProcessTreeHops = 8

    /// The app an audio-producing process belongs to:
    /// 1. an app with the same process ID;
    /// 2. otherwise the app whose bundle ID equals the process's, or is a prefix
    ///    of it followed by a dot (`com.google.Chrome` owns `com.google.Chrome.helper`),
    ///    with the longest such bundle ID winning, plus WebKit's shared helpers
    ///    (`com.apple.WebKit.*`) for Safari;
    /// 3. otherwise an app found by walking up the process tree.
    static func owner(
        ofProcessWithBundleID id: String,
        pid processPID: pid_t,
        in apps: [RunningApp],
        parentOf: (pid_t) -> pid_t
    ) -> RunningApp? {
        var best: RunningApp?
        var bestLength = 0
        for app in apps {
            if app.pid == processPID { return app }
            let matches = id == app.bundleID || id.hasPrefix(app.bundleID + ".")
                || (app.bundleID == "com.apple.Safari" && id.hasPrefix("com.apple.WebKit."))
            if matches, app.bundleID.count > bestLength { best = app; bestLength = app.bundleID.count }
        }
        if let best { return best }

        // Helpers with unrelated bundle IDs: look for an ancestor process that is an app.
        var pid = parentOf(processPID)
        var hops = 0
        while pid > 1, hops < maxProcessTreeHops {
            if let app = apps.first(where: { $0.pid == pid }) { return app }
            pid = parentOf(pid)
            hops += 1
        }
        return nil
    }
}
