import Foundation
import Testing
@testable import AudioRecorder

struct RecordingFileNameTests {
    private let folder = URL(fileURLWithPath: "/tmp/recordings")
    private let date = Calendar.current.date(from: DateComponents(
        year: 2026, month: 10, day: 20, hour: 21, minute: 40, second: 5))!

    @Test func allSystemAudioHasNoAppName() {
        let url = RecordingFileName.url(in: folder, appName: nil, date: date)
        #expect(url.lastPathComponent == "Recording 2026-10-20 21.40.05.wav")
        #expect(url.deletingLastPathComponent().path == "/tmp/recordings")
    }

    @Test func singleAppNameIsIncluded() {
        let url = RecordingFileName.url(in: folder, appName: "Spotify", date: date)
        #expect(url.lastPathComponent == "Recording Spotify 2026-10-20 21.40.05.wav")
    }

    @Test func slashesAndColonsInAppNamesAreReplaced() {
        let url = RecordingFileName.url(in: folder, appName: "AC/DC: Live", date: date)
        #expect(url.lastPathComponent == "Recording AC-DC- Live 2026-10-20 21.40.05.wav")
    }

    @Test func extensionIsWav() {
        #expect(RecordingFileName.url(in: folder, appName: nil, date: date).pathExtension == "wav")
    }
}
