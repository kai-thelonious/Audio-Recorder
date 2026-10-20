import SwiftUI

@main
struct AudioRecorderApp: App {
    @State private var settings: AppSettings
    @State private var recorder: RecorderViewModel
    /// True until the window SwiftUI opens at launch has appeared, so menu bar
    /// mode can close that one without closing windows opened later.
    @State private var launchWindowPending = true

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _recorder = State(initialValue: RecorderViewModel(settings: settings))
        settings.mode.applyActivationPolicy()
    }

    var body: some Scene {
        Window("AudioRecorder", id: "main") {
            ContentView(recorder: recorder, launchWindowPending: $launchWindowPending)
                .environment(settings)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent(recorder: recorder)
                .environment(settings)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform")
                .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
        }
    }
}
