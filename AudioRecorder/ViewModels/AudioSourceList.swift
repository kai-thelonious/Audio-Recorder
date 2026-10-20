import Combine

/// Apps currently producing audio, refreshed on demand.
@MainActor
final class AudioSourceList: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []

    func refresh() { apps = AudioSources.appsPlayingAudio() }
}
