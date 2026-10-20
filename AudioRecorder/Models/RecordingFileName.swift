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
}
