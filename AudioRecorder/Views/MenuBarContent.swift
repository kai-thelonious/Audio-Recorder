import SwiftUI
import AppKit

struct MenuBarContent: View {
    let recorder: RecorderViewModel
    @AppStorage(Settings.folderKey) private var folderPath = Settings.defaultFolderPath
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(recorder.isRecording ? "Stop Recording" : "Start Recording") {
            recorder.toggleRecording()
        }
        Text(recorder.status)
        SourceMenuSection(isRecording: recorder.isRecording)

        Divider()

        Text("Folder: \((folderPath as NSString).abbreviatingWithTildeInPath)")
        Button("Choose Folder…") {
            if let path = chooseFolderPath() { folderPath = path }
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
