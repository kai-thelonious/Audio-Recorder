import Observation

/// Apps currently producing audio, refreshed on demand.
@MainActor
@Observable
final class AudioSourceList {
    private(set) var apps: [AudioApp] = []

    func refresh() { apps = AudioSources.appsPlayingAudio() }
}
