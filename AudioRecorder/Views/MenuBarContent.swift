import AppKit
import SwiftUI

struct MenuBarContent: View {
    let recorder: RecorderViewModel
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(recorder.isRecording ? "Stop Recording" : "Start Recording") {
            recorder.toggleRecording()
        }
        Text(recorder.status)
        if let hint = recorder.silenceHint { Text(hint) }
        SourceMenuSection(isRecording: recorder.isRecording)

        Divider()

        Text("Folder: \((settings.folderPath as NSString).abbreviatingWithTildeInPath)")
        Button("Choose Folder…") {
            if let path = chooseFolderPath() { settings.folderPath = path }
        }
        .disabled(recorder.isRecording)

        Divider()

        ModePicker()
        Button("Show Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit AudioRecorder") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
