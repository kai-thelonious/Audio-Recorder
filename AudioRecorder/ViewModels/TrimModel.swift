import Combine
import AVFoundation

@MainActor
final class TrimModel: ObservableObject {
    let sourceURL: URL
    @Published var data: WaveformData?
    @Published var errorText: String?
    @Published var start: Double = 0        // seconds
    @Published var end: Double = 0          // seconds
    @Published var playhead: Double = 0     // seconds
    @Published var isPlaying = false
    @Published var isSaving = false
    @Published var savedURL: URL?

    private var player: AVAudioPlayer?
    private var timer: Timer?

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
