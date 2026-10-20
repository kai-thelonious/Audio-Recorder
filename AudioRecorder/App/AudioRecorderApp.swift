import SwiftUI

@main
struct AudioRecorderApp: App {
    @State private var recorder = RecorderViewModel()

    init() {
        // @AppStorage isn't usable here yet, so read the saved mode directly.
        let saved = UserDefaults.standard.string(forKey: Settings.modeKey)
        (AppMode(rawValue: saved ?? "") ?? .window).applyActivationPolicy()
    }

    var body: some Scene {
        Window("AudioRecorder", id: "main") {
            ContentView(recorder: recorder)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent(recorder: recorder)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform")
                .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
        }
    }
}
