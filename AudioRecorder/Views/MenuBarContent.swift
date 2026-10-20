import SwiftUI
import AppKit

struct MenuBarContent: View {
    @ObservedObject var recorder: SystemAudioTapRecorder
    @AppStorage(Settings.folderKey) private var folderPath = Settings.defaultFolderPath
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(recorder.isRecording ? "Stop Recording" : "Start Recording") {
            if recorder.isRecording {
                recorder.stop()
            } else {
                folderPath = Settings.validFolderPath(folderPath)
                recorder.start(in: URL(fileURLWithPath: folderPath))
            }
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
