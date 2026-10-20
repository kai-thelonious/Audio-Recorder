import AppKit
import Foundation
import Testing
@testable import AudioRecorder

struct RecorderViewModelTests {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private let allAudio = ResolvedSource(processObjects: nil, appName: nil)
    private let fixedDate = Calendar.current.date(from: DateComponents(
        year: 2026, month: 10, day: 20, hour: 21, minute: 40, second: 5))!

    /// A view model wired to a fake recorder and a scratch save folder.
    private func makeModel(
        resolve: @escaping @MainActor (String) throws -> ResolvedSource = { _ in
            ResolvedSource(processObjects: nil, appName: nil)
        },
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000) }
    ) throws -> (model: RecorderViewModel, recorder: FakeRecorder, settings: AppSettings, folder: TempFolder) {
        let folder = try TempFolder()
        let settings = AppSettings(defaults: makeTestDefaults())
        settings.folderPath = folder.url.path
        let recorder = FakeRecorder()
        let model = RecorderViewModel(settings: settings, recorder: recorder, resolveSource: resolve, now: now)
        return (model, recorder, settings, folder)
    }

    @Test func startsIdle() throws {
        let t = try makeModel(); defer { t.folder.remove() }
        #expect(!t.model.isRecording)
        #expect(t.model.status == "Idle")
        #expect(t.model.lastFileURL == nil)
    }

    @Test func startRecordsAllSystemAudioIntoTheSavedFolder() throws {
        let fixed = fixedDate
        let t = try makeModel(now: { fixed }); defer { t.folder.remove() }
        t.model.start()
        #expect(t.model.isRecording)
        #expect(t.model.status == "Recording all system audio…")
        let started = try #require(t.recorder.startedWith)
        #expect(started.fileURL.lastPathComponent == "Recording 2026-10-20 21.40.05.wav")
        #expect(started.fileURL.deletingLastPathComponent().path == t.folder.url.path)
        t.model.stop()
    }

    @Test func singleAppRecordingUsesTheAppNameAndTheSavedChoice() throws {
        var requested: String?
        let t = try makeModel(resolve: { id in
            requested = id
            return ResolvedSource(processObjects: [42], appName: "Spotify")
        }); defer { t.folder.remove() }
        t.settings.sourceBundleID = "com.spotify.client"
        t.model.start()
        #expect(requested == "com.spotify.client")
        #expect(t.model.status == "Recording Spotify…")
        let started = try #require(t.recorder.startedWith)
        #expect(started.source.processObjects == [42])
        #expect(started.fileURL.lastPathComponent.hasPrefix("Recording Spotify "))
        t.model.stop()
    }

    @Test func stopSavesAndRemembersTheFile() throws {
        let t = try makeModel(); defer { t.folder.remove() }
        t.model.start()
        let url = try #require(t.recorder.startedWith?.fileURL)
        t.model.stop()
        #expect(!t.model.isRecording)
        #expect(t.recorder.stopCount == 1)
        #expect(t.model.lastFileURL == url)
        #expect(t.model.status == "Saved: \(url.lastPathComponent)")
    }

    @Test func toggleStartsThenStops() throws {
        let t = try makeModel(); defer { t.folder.remove() }
        t.model.toggleRecording()
        #expect(t.model.isRecording)
        t.model.toggleRecording()
        #expect(!t.model.isRecording)
        #expect(t.recorder.startCount == 1)
        #expect(t.recorder.stopCount == 1)
    }

    @Test func sourceErrorShowsAMessageAndDoesNotStartTheRecorder() throws {
        let t = try makeModel(resolve: { _ in throw Failure() }); defer { t.folder.remove() }
        t.model.start()
        #expect(!t.model.isRecording)
        #expect(t.model.status == "Error: boom")
        #expect(t.recorder.startCount == 0)
        #expect(t.model.lastFileURL == nil)
    }

    @Test func recorderErrorShowsAMessageAndStaysStopped() throws {
        let t = try makeModel(); defer { t.folder.remove() }
        t.recorder.startError = Failure()
        t.model.start()
        #expect(!t.model.isRecording)
        #expect(t.model.status == "Error: boom")
    }

    @Test func startWhileRecordingIsIgnored() throws {
        let t = try makeModel(); defer { t.folder.remove() }
        t.model.start()
        t.model.start()
        #expect(t.recorder.startCount == 1)
        t.model.stop()
    }

    @Test func stopWhenNotRecordingDoesNothing() throws {
        let t = try makeModel(); defer { t.folder.remove() }
        t.model.stop()
        #expect(t.recorder.stopCount == 0)
        #expect(t.model.status == "Idle")
    }

    @Test func missingSaveFolderFallsBackToMusic() throws {
        let t = try makeModel(); defer { t.folder.remove() }
        t.settings.folderPath = "/no/such/folder/\(UUID().uuidString)"
        t.model.start()
        let started = try #require(t.recorder.startedWith)
        #expect(started.fileURL.deletingLastPathComponent().path == AppSettings.defaultFolderPath)
        #expect(t.settings.folderPath == AppSettings.defaultFolderPath)
        t.model.stop()
    }

    @Test func twoRecordingsInTheSameSecondDoNotShareAFile() throws {
        let fixed = fixedDate
        let t = try makeModel(now: { fixed }); defer { t.folder.remove() }
        t.model.start()
        let first = try #require(t.recorder.startedWith?.fileURL)
        try Data().write(to: first)   // the first recording's file now exists
        t.model.stop()
        t.model.start()
        let second = try #require(t.recorder.startedWith?.fileURL)
        #expect(second != first)
        #expect(second.lastPathComponent == "Recording 2026-10-20 21.40.05 2.wav")
        t.model.stop()
    }

    @Test func aWriteFailureStopsTheRecordingAndKeepsTheFile() throws {
        let t = try makeModel(); defer { t.folder.remove() }
        t.model.start()
        let url = try #require(t.recorder.startedWith?.fileURL)
        t.recorder.pendingError = Failure()
        t.model.tick()
        #expect(!t.model.isRecording)
        #expect(t.recorder.stopCount == 1)
        #expect(t.model.lastFileURL == url)
        #expect(t.model.status == "Recording stopped: boom Saved: \(url.lastPathComponent)")
    }

    @Test func quittingTheAppFinishesTheRecording() throws {
        let center = NotificationCenter()
        let folder = try TempFolder(); defer { folder.remove() }
        let settings = AppSettings(defaults: makeTestDefaults())
        settings.folderPath = folder.url.path
        let recorder = FakeRecorder()
        let model = RecorderViewModel(settings: settings, recorder: recorder, notificationCenter: center)
        model.finishRecordingOnQuit()
        model.start()
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(!model.isRecording)
        #expect(recorder.stopCount == 1)
    }

    @Test func quittingWhileIdleDoesNothing() throws {
        let center = NotificationCenter()
        let folder = try TempFolder(); defer { folder.remove() }
        let settings = AppSettings(defaults: makeTestDefaults())
        let recorder = FakeRecorder()
        let model = RecorderViewModel(settings: settings, recorder: recorder, notificationCenter: center)
        model.finishRecordingOnQuit()
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(recorder.stopCount == 0)
        #expect(model.status == "Idle")
    }

    @Test func savingATrimUpdatesTheLastFileAndStatus() throws {
        let t = try makeModel(); defer { t.folder.remove() }
        let trimmed = t.folder.url.appendingPathComponent("Recording (trimmed).wav")
        t.model.didSaveTrim(trimmed)
        #expect(t.model.lastFileURL == trimmed)
        #expect(t.model.status == "Saved: Recording (trimmed).wav")
    }

    @Test func tickFeedsTheLevelMeterAndTimer() throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let t = try makeModel(now: { clock }); defer { t.folder.remove() }
        t.model.start()
        t.recorder.peak = 1
        clock = clock.addingTimeInterval(2.5)
        t.model.tick()
        #expect(t.model.levels.last == 1)
        #expect(t.model.levels.count == WaveBars.barCount)
        #expect(t.model.elapsed == 2.5)
        t.model.stop()
        #expect(t.model.levels.allSatisfy { $0 == 0 })
    }
}
