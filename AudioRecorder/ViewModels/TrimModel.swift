import AVFoundation
import Observation

@MainActor
@Observable
final class TrimModel {
    let sourceURL: URL
    var data: WaveformData?
    var errorText: String?
    var start: Double = 0  // seconds
    var end: Double = 0  // seconds
    var playhead: Double = 0  // seconds
    var isPlaying = false
    var isSaving = false
    var savedURL: URL?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    static let minLength = 0.05

    init(sourceURL: URL) { self.sourceURL = sourceURL }

    var duration: Double { data?.duration ?? 0 }
    /// What drag-out hands over: the saved trim if there is one, else the original.
    var dragURL: URL { savedURL ?? sourceURL }

    func load() async {
        let url = sourceURL
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try WaveformLoader.load(url: url)
            }.value
            data = result
            start = 0
            end = result.duration
            playhead = 0
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: Selection

    func setStart(_ value: Double) {
        stopPlayback()
        start = min(max(0, value), end - Self.minLength)
        playhead = start
    }

    func setEnd(_ value: Double) {
        stopPlayback()
        end = max(min(duration, value), start + Self.minLength)
        playhead = start
    }

    /// Moves the start handle by `delta` seconds (used by VoiceOver's adjustable handles).
    func nudgeStart(by delta: Double) { setStart(start + delta) }

    /// Moves the end handle by `delta` seconds.
    func nudgeEnd(by delta: Double) { setEnd(end + delta) }

    // MARK: Preview

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    private func play() {
        guard let player else { return }
        if playhead < start || playhead >= end - 0.01 { playhead = start }
        player.currentTime = playhead
        guard player.play() else { return }
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stopPlayback() {
        pause()
        playhead = start
    }

    private func tick() {
        guard let player else { return }
        playhead = player.currentTime
        if playhead >= end || !player.isPlaying {
            player.pause()
            pause()
            playhead = start
        }
    }

    // MARK: Save

    func save() async -> URL? {
        guard let data else { return nil }
        stopPlayback()
        isSaving = true
        defer { isSaving = false }
        let url = sourceURL
        let rate = data.sampleRate
        let s = AVAudioFramePosition((start * rate).rounded())
        let e = min(data.frameCount, AVAudioFramePosition((end * rate).rounded()))
        do {
            let out = try await Task.detached(priority: .userInitiated) {
                try WaveformLoader.exportTrim(of: url, startFrame: s, endFrame: e)
            }.value
            savedURL = out
            errorText = nil
            return out
        } catch {
            errorText = "Save failed: \(error.localizedDescription)"
            return nil
        }
    }
}
