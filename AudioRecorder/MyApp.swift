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

// MARK: - UI

struct ContentView: View {
    @StateObject private var recorder = SystemAudioTapRecorder()
    @State private var folder: URL = FileManager.default
        .urls(for: .musicDirectory, in: .userDomainMask).first!

    var body: some View {
        VStack(spacing: 16) {
            Text(folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Choose Folder…") { chooseFolder() }
                .disabled(recorder.isRecording)

            Button(recorder.isRecording ? "Stop" : "Record") {
                if recorder.isRecording {
                    recorder.stop()
                } else {
                    recorder.start(in: folder)
                }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            Text(recorder.status)
                .font(.footnote)
        }
        .padding(24)
        .frame(width: 360)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
    }
}

@main
struct SystemAudioTapRecorderApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
