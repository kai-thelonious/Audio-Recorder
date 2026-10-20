import Foundation
import Observation

/// The user's saved preferences, in one place. Views read and bind to this
/// instead of each using `@AppStorage`, and the view model reads it too.
/// Changes are written to `UserDefaults` straight away.
@Observable
final class AppSettings {
    enum Keys {
        static let mode = "appMode"
        static let folder = "saveFolderPath"
        static let sourceBundleID = "sourceBundleID"
    }

    /// Window with a Dock icon, or menu bar only.
    var mode: AppMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }
    /// Where recordings are saved.
    var folderPath: String {
        didSet { defaults.set(folderPath, forKey: Keys.folder) }
    }
    /// Bundle ID of the app to record, or "" for all system audio.
    var sourceBundleID: String {
        didSet { defaults.set(sourceBundleID, forKey: Keys.sourceBundleID) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .window
        folderPath = defaults.string(forKey: Keys.folder) ?? Self.defaultFolderPath
        sourceBundleID = defaults.string(forKey: Keys.sourceBundleID) ?? ""
    }

    static var defaultFolderPath: String {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!.path
    }

    /// The saved folder if it still exists, otherwise ~/Music.
    static func validFolderPath(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? path : defaultFolderPath
    }

    /// Falls back to ~/Music, and saves that, if the saved folder is gone.
    func validatedFolderPath() -> String {
        let valid = Self.validFolderPath(folderPath)
        folderPath = valid
        return valid
    }
}
