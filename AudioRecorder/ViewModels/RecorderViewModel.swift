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

    @ObservationIgnored private let recorder: AudioRecording
    @ObservationIgnored private let resolveSource: @MainActor (String) throws -> ResolvedSource
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var startDate = Date()
    @ObservationIgnored private var meterTimer: Timer?

    init(
        settings: AppSettings,
        recorder: AudioRecording = TapRecorder(),
        resolveSource: (@MainActor (String) throws -> ResolvedSource)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.recorder = recorder
        self.resolveSource = resolveSource ?? { try AudioSources.resolve(bundleID: $0) }
        self.settings = settings
        self.now = now
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
            let url = RecordingFileName.url(in: URL(fileURLWithPath: folder), appName: source.appName, date: now())
            try recorder.start(source: source, fileURL: url)
            fileURL = url
            startMetering()
            isRecording = true
            status = "Recording \(source.appName ?? "all system audio")…"
        } catch {
            isRecording = false
            status = "Error: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording else { return }
        stopMetering()
        recorder.stop()
        lastFileURL = fileURL
        isRecording = false
        status = "Saved: \(fileURL?.lastPathComponent ?? "")"
    }

    /// Called by the trim editor when it has written a trimmed copy.
    func didSaveTrim(_ url: URL) {
        lastFileURL = url
        status = "Saved: \(url.lastPathComponent)"
    }

    // MARK: Metering

    private func startMetering() {
        elapsed = 0
        startDate = now()
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        levels = [Float](repeating: 0, count: WaveBars.barCount)
    }

    func tick() {
        let level = Self.meterLevel(peak: recorder.takePeak(), previous: levels.last ?? 0)
        levels.removeFirst()
        levels.append(level)
        elapsed = now().timeIntervalSince(startDate)
    }

    /// Maps -50 dB…0 dB onto 0…1, with a quick attack and a gentle decay.
    static func meterLevel(peak: Float, previous: Float) -> Float {
        let db = 20 * log10(max(peak, 1e-5))
        let fresh = max(0, min(1, (db + 50) / 50))
        return max(fresh, previous * 0.8)
    }
}
