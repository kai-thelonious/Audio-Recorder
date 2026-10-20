import AppKit
import Foundation
import Observation

/// The single source of truth for recording state, shared by the window, the
/// menu bar menu and the trim editor.
@Observable
final class RecorderViewModel {
    private(set) var isRecording = false
    private(set) var status = "Idle"
    private(set) var levels = [Float](repeating: 0, count: WaveBars.barCount)
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastFileURL: URL?
    /// Set when a recording has captured nothing but silence for a few seconds.
    /// That happens when nothing is playing, and also when audio capture
    /// permission was denied (macOS then delivers silence instead of an error).
    private(set) var silenceHint: String?

    static let silenceThreshold: Float = 0.0001          // about -80 dB
    static let silenceWarningDelay: TimeInterval = 3     // seconds
    static let silenceMessage = "No audio detected. Is something playing? Check the Privacy settings."
    /// How often (seconds) a single-app recording checks that the app is still running.
    static let appCheckInterval: TimeInterval = 1

    @ObservationIgnored private let recorder: AudioRecording
    @ObservationIgnored private let resolveSource: @MainActor (String) throws -> ResolvedSource
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isAppRunning: (String) -> Bool
    @ObservationIgnored private var recordedApp: (bundleID: String, name: String)?
    @ObservationIgnored private var lastAppCheck = Date()
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var heardAudio = false
    @ObservationIgnored private var startDate = Date()
    @ObservationIgnored private var meterTimer: Timer?

    init(
        settings: AppSettings,
        recorder: AudioRecording = TapRecorder(),
        resolveSource: (@MainActor (String) throws -> ResolvedSource)? = nil,
        now: @escaping () -> Date = Date.init,
        notificationCenter: NotificationCenter = .default,
        isAppRunning: ((String) -> Bool)? = nil
    ) {
        self.recorder = recorder
        self.resolveSource = resolveSource ?? { try AudioSources.resolve(bundleID: $0) }
        self.settings = settings
        self.now = now
        self.notificationCenter = notificationCenter
        self.isAppRunning = isAppRunning ?? { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// Finishes a recording in progress when the app quits, so the WAV header is
    /// written. Without this a quit mid-recording leaves a file that reports 0 seconds.
    func finishRecordingOnQuit() {
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    // MARK: Actions

    func toggleRecording() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        let folder = settings.validatedFolderPath()
        do {
            let source = try resolveSource(settings.sourceBundleID)
            let url = RecordingFileName.uniqueURL(in: URL(fileURLWithPath: folder), appName: source.appName, date: now())
            try recorder.start(source: source, fileURL: url)
            fileURL = url
            // For a single-app recording, remember which app so we notice if it quits.
            recordedApp = source.appName.map { (settings.sourceBundleID, $0) }
            startMetering()
            isRecording = true
            status = "Recording \(source.appName ?? "all system audio")…"
        } catch {
            isRecording = false
            status = "Error: \(error.localizedDescription)"
        }
    }

    func stop() {
        finish(reason: nil)
    }

    /// Stops recording; if `reason` is set, says why recording ended early.
    private func finish(reason: String?) {
        guard isRecording else { return }
        stopMetering()
        recorder.stop()
        lastFileURL = fileURL
        isRecording = false
        let saved = "Saved: \(fileURL?.lastPathComponent ?? "")"
        recordedApp = nil
        status = reason.map { "Recording stopped: \($0) \(saved)" } ?? saved
    }

    /// Called by the trim editor when it has written a trimmed copy.
    func didSaveTrim(_ url: URL) {
        lastFileURL = url
        status = "Saved: \(url.lastPathComponent)"
    }

    // MARK: Metering

    private func startMetering() {
        elapsed = 0
        heardAudio = false
        silenceHint = nil
        startDate = now()
        lastAppCheck = startDate
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        silenceHint = nil
        levels = [Float](repeating: 0, count: WaveBars.barCount)
    }

    func tick() {
        if let failure = recorder.takeError() {
            finish(reason: failure.localizedDescription)
            return
        }
        // A single-app recording can't go on once that app has quit; the tap would
        // just keep delivering silence.
        if let app = recordedApp, now().timeIntervalSince(lastAppCheck) >= Self.appCheckInterval {
            lastAppCheck = now()
            if !isAppRunning(app.bundleID) {
                finish(reason: "\(app.name) quit.")
                return
            }
        }
        let peak = recorder.takePeak()
        let level = Self.meterLevel(peak: peak, previous: levels.last ?? 0)
        levels.removeFirst()
        levels.append(level)
        elapsed = now().timeIntervalSince(startDate)

        // Warn only if nothing at all has been heard since recording started, so
        // a quiet passage in a song never triggers it.
        if peak > Self.silenceThreshold { heardAudio = true }
        silenceHint = !heardAudio && elapsed >= Self.silenceWarningDelay ? Self.silenceMessage : nil
    }

    /// Maps -50 dB…0 dB onto 0…1, with a quick attack and a gentle decay.
    static func meterLevel(peak: Float, previous: Float) -> Float {
        let db = 20 * log10(max(peak, 1e-5))
        let fresh = max(0, min(1, (db + 50) / 50))
        return max(fresh, previous * 0.8)
    }
}
