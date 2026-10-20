import Foundation
import Testing

@testable import AudioRecorder

struct AppSettingsTests {
    @Test func startsWithDefaults() {
        let settings = AppSettings(defaults: makeTestDefaults())
        #expect(settings.mode == .window)
        #expect(settings.sourceBundleID == "")
        #expect(settings.folderPath == AppSettings.defaultFolderPath)
    }

    @Test func changesAreSavedToUserDefaults() {
        let defaults = makeTestDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.mode = .menuBarOnly
        settings.folderPath = "/tmp/somewhere"
        settings.sourceBundleID = "com.spotify.client"
        #expect(defaults.string(forKey: "appMode") == "Menu bar only")
        #expect(defaults.string(forKey: "saveFolderPath") == "/tmp/somewhere")
        #expect(defaults.string(forKey: "sourceBundleID") == "com.spotify.client")
    }

    @Test func savedValuesAreLoaded() {
        let defaults = makeTestDefaults()
        defaults.set("Menu bar only", forKey: "appMode")
        defaults.set("/tmp/saved", forKey: "saveFolderPath")
        defaults.set("com.apple.Safari", forKey: "sourceBundleID")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.mode == .menuBarOnly)
        #expect(settings.folderPath == "/tmp/saved")
        #expect(settings.sourceBundleID == "com.apple.Safari")
    }

    @Test func unknownModeFallsBackToWindow() {
        let defaults = makeTestDefaults()
        defaults.set("something else", forKey: "appMode")
        #expect(AppSettings(defaults: defaults).mode == .window)
    }

    @Test func existingFolderIsKept() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        #expect(AppSettings.validFolderPath(temp.url.path) == temp.url.path)
    }

    @Test func missingFolderFallsBackToDefault() {
        #expect(AppSettings.validFolderPath("/no/such/folder/\(UUID().uuidString)") == AppSettings.defaultFolderPath)
    }

    @Test func aFileIsNotAValidFolder() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let file = temp.url.appendingPathComponent("file.txt")
        try Data().write(to: file)
        #expect(AppSettings.validFolderPath(file.path) == AppSettings.defaultFolderPath)
    }

    @Test func validatingAMissingFolderSavesTheFallback() {
        let defaults = makeTestDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.folderPath = "/no/such/folder/\(UUID().uuidString)"
        let result = settings.validatedFolderPath()
        #expect(result == AppSettings.defaultFolderPath)
        #expect(settings.folderPath == AppSettings.defaultFolderPath)
        #expect(defaults.string(forKey: "saveFolderPath") == AppSettings.defaultFolderPath)
    }
}
