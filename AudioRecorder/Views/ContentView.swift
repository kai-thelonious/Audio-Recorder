import SwiftUI
import AppKit

private func formatElapsed(_ t: TimeInterval) -> String {
    let total = Int(t)
    return String(format: "%02d:%02d", total / 60, total % 60)
}

struct ContentView: View {
    let recorder: RecorderViewModel
    @AppStorage(Settings.folderKey) private var folderPath = Settings.defaultFolderPath
    @AppStorage(Settings.modeKey) private var mode = AppMode.window
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var trimSource: TrimSource?

    var body: some View {
        VStack(spacing: 20) {
            WaveBars(levels: recorder.isRecording ? recorder.levels : nil)
                .padding(.top, 8)

            VStack(spacing: 4) {
                Text(recorder.isRecording ? formatElapsed(recorder.elapsed) : "Ready")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(recorder.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button {
                recorder.toggleRecording()
            } label: {
                ZStack {
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 22, height: 22)
                    }
                }
                .frame(width: 72, height: 72)
                .recordButtonBackground(recording: recorder.isRecording)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .help(recorder.isRecording ? "Stop recording" : "Start recording")

            SourcePicker(isRecording: recorder.isRecording)
                .labelsHidden()
                .frame(width: 220)

            HStack(spacing: 8) {
                Button {
                    if let path = chooseFolderPath() { folderPath = path }
                } label: {
                    Label((folderPath as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .disabled(recorder.isRecording)
                .help("Choose where recordings are saved")

                if let url = recorder.lastFileURL, !recorder.isRecording {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Show in Finder", systemImage: "magnifyingglass")
                    }

                    Button {
                        trimSource = TrimSource(url: url)
                    } label: {
                        Label("Trim", systemImage: "scissors")
                    }
                }
            }
            .glassButton()
            .controlSize(.small)

            ModePicker()
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
        }
        .padding(28)
        .frame(width: 360)
        .animation(.snappy, value: recorder.isRecording)
        .glassWindowBackground()
        .sheet(item: $trimSource) { TrimEditorView(source: $0, recorder: recorder) }
        .onAppear {
            // Menu bar only: the scene opens a window at launch; close just that one.
            // Later appearances (e.g. "Show Window") must stay open.
            guard Settings.launchWindowPending else { return }
            Settings.launchWindowPending = false
            if mode == .menuBarOnly { dismissWindow(id: "main") }
        }
    }
}
