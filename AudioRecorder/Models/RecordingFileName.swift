import Foundation

enum RecordingFileName {
    /// `Recording <date>.wav`, or `Recording <app> <date>.wav` for a single-app recording.
    static func url(in folder: URL, appName: String?, date: Date) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let appPart = appName.map {
            " " + $0.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        } ?? ""
        return folder.appendingPathComponent("Recording\(appPart) \(df.string(from: date)).wav")
    }

    /// Like `url`, but never a file that already exists: two recordings started in
    /// the same second get `… 2.wav`, `… 3.wav`, so one can't overwrite the other.
    static func uniqueURL(
        in folder: URL, appName: String?, date: Date,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let first = url(in: folder, appName: appName, date: date)
        guard exists(first) else { return first }
        let base = first.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(number).wav")
            if !exists(candidate) { return candidate }
            number += 1
        }
    }
}
