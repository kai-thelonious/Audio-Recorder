import Foundation

enum Settings {
    static let modeKey = "appMode"
    static let folderKey = "saveFolderPath"
    /// True until the window SwiftUI opens at launch has appeared. Lets us close
    /// that one in menu bar mode without closing windows the user opens later.
    static var launchWindowPending = true
    static let defaultFolderPath = FileManager.default
        .urls(for: .musicDirectory, in: .userDomainMask).first!.path

    /// The saved folder if it still exists, otherwise ~/Music.
    static func validFolderPath(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? path : defaultFolderPath
    }
}
