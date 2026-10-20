import SwiftUI
import AppKit
import CoreAudio
import AVFoundation
import Combine

// Requires macOS 14.2+ and an Info.plist key:
//   NSAudioCaptureUsageDescription  ("Privacy - Audio Capture Usage Description")

// MARK: - Recorder

enum TapError: LocalizedError {
    case osStatus(String, OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .osStatus(let what, let code): return "\(what) failed (OSStatus \(code))"
        case .message(let text): return text
        }
    }
}

final class SystemAudioTapRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var status = "Idle"

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var fileURL: URL?
    private let ioQueue = DispatchQueue(label: "system-audio-tap-io")

    // MARK: Start

    func start(in folder: URL) {
        do {
            // 1. Describe the tap: all system audio, excluding nothing.
            //    (Pass your own process's AudioObjectID in the array to exclude it.)
            let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            tapDesc.uuid = UUID()
            tapDesc.name = "SystemAudioTapRecorder"
            tapDesc.muteBehavior = .unmuted   // .muted silences the speakers while tapping
            tapDesc.isPrivate = true

            // 2. Create the tap (this is what triggers the permission prompt)
            var status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
            guard status == noErr else { throw TapError.osStatus("Create process tap", status) }

            // 3. Read the tap's audio format
            var asbd = try tapFormat(tapID)
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw TapError.message("Unsupported tap format")
            }

            // 4. Wrap the tap in a private aggregate device. It has no sub-devices,
            //    so it runs on the tap's own clock and sample rate, independent of
            //    whatever output device (speakers, Bluetooth, …) is in use.
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SystemAudioTapRecorder",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: tapDesc.uuid.uuidString]
                ]
            ]
            status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
            guard status == noErr else { throw TapError.osStatus("Create aggregate device", status) }

            // 5. Open the output file (16-bit PCM WAV; AVAudioFile converts on write)
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = folder.appendingPathComponent("Recording \(df.string(from: Date())).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            fileURL = url

            // 6. Receive audio buffers from the aggregate device
            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
                [weak self] _, inInputData, _, _, _ in
                guard let self, let file = self.audioFile,
                      let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData)
                else { return }
                try? file.write(from: pcm)
            }
            guard status == noErr else { throw TapError.osStatus("Create IO proc", status) }

            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw TapError.osStatus("Start device", status) }

            set(recording: true, status: "Recording…")
        } catch {
            teardown()
            set(recording: false, status: "Error: \(error.localizedDescription)")
        }
    }

    // MARK: Stop

    func stop() {
        let name = fileURL?.lastPathComponent ?? ""
        teardown()
        set(recording: false, status: "Saved: \(name)")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)

        // Serialize with the IO queue, then release the file so it gets finalized
        ioQueue.sync { audioFile = nil }
    }

    // MARK: Core Audio helpers

    private func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw TapError.osStatus("Read tap format", status) }
        return asbd
    }

    private func set(recording: Bool, status: String) {
        DispatchQueue.main.async {
            self.isRecording = recording
            self.status = status
        }
    }
}

// MARK: - Settings

enum AppMode: String, CaseIterable, Identifiable {
    case window = "Window"
    case menuBarOnly = "Menu bar only"

    var id: String { rawValue }

    /// Dock icon in window mode, none in menu bar only mode.
    func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(self == .window ? .regular : .accessory)
    }
}

enum Settings {
    static let modeKey = "appMode"
    static let folderKey = "saveFolderPath"
    /// True until the window SwiftUI opens at launch has appeared. Lets us close
    /// that one in menu bar mode without closing windows the user opens later.
    static var launchWindowPending = true
    static let defaultFolderPath = FileManager.default
        .urls(for: .musicDirectory, in: .userDomainMask).first!.path

    /// The saved folder if it still exists, otherwise ~/Music.
    static func validFolderPath(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? path : defaultFolderPath
    }
}

/// Shows an open panel and returns the chosen folder path, or nil if cancelled.
private func chooseFolderPath() -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url?.path : nil
}

// MARK: - UI

struct ModePicker: View {
    @AppStorage(Settings.modeKey) private var mode = AppMode.window
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Picker("Mode", selection: $mode) {
            ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .onChange(of: mode) { _, newMode in
            newMode.applyActivationPolicy()
            if newMode == .window {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } else {
                dismissWindow(id: "main")
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var recorder: SystemAudioTapRecorder
    @AppStorage(Settings.folderKey) private var folderPath = Settings.defaultFolderPath
    @AppStorage(Settings.modeKey) private var mode = AppMode.window
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            Text(folderPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Choose Folder…") {
                if let path = chooseFolderPath() { folderPath = path }
            }
            .disabled(recorder.isRecording)

            Button(recorder.isRecording ? "Stop" : "Record") {
                if recorder.isRecording {
                    recorder.stop()
                } else {
                    folderPath = Settings.validFolderPath(folderPath)
                    recorder.start(in: URL(fileURLWithPath: folderPath))
                }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            Text(recorder.status)
                .font(.footnote)

            ModePicker()
                .pickerStyle(.segmented)
                .frame(width: 240)
        }
        .padding(24)
        .frame(width: 360)
        .onAppear {
            // Menu bar only: the scene opens a window at launch; close just that one.
            // Later appearances (e.g. "Show Window") must stay open.
            guard Settings.launchWindowPending else { return }
            Settings.launchWindowPending = false
            if mode == .menuBarOnly { dismissWindow(id: "main") }
        }
    }
}

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

@main
struct SystemAudioTapRecorderApp: App {
    @StateObject private var recorder = SystemAudioTapRecorder()

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
