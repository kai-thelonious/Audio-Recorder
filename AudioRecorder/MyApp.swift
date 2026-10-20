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

/// Tracks the loudest sample seen since the last read. Written from the audio
/// thread, read from the UI timer.
nonisolated final class PeakMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func record(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        // Interleaved buffers keep every channel in channels[0].
        let (planes, count) = buffer.format.isInterleaved ? (1, frames * channelCount) : (channelCount, frames)
        var loudest: Float = 0
        for plane in 0..<planes {
            let samples = channels[plane]
            for i in 0..<count { loudest = max(loudest, abs(samples[i])) }
        }
        lock.lock()
        peak = max(peak, loudest)
        lock.unlock()
    }

    func takePeak() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
    }
}

final class SystemAudioTapRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var status = "Idle"
    @Published var levels = [Float](repeating: 0, count: WaveBars.barCount)
    @Published var elapsed: TimeInterval = 0
    @Published var lastFileURL: URL?

    private let meter = PeakMeter()
    private var uiTimer: Timer?
    private var startDate = Date()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var fileURL: URL?
    private let ioQueue = DispatchQueue(label: "system-audio-tap-io")

    // MARK: Start

    func start(in folder: URL) {
        do {
            // 1. Describe the tap: one app's processes if a source is chosen,
            //    otherwise all system audio (see AudioSources.swift).
            //    (Pass your own process's AudioObjectID in the array to exclude it.)
            let source = try AudioSources.resolve(
                bundleID: UserDefaults.standard.string(forKey: AudioSources.defaultsKey) ?? "")
            let tapDesc: CATapDescription
            if let objects = source.processObjects {
                tapDesc = CATapDescription(stereoMixdownOfProcesses: objects)
            } else {
                tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            }
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
            let appPart = source.appName.map { " " + $0.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") } ?? ""
            let url = folder.appendingPathComponent("Recording\(appPart) \(df.string(from: Date())).wav")
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
                self.meter.record(pcm)
                try? file.write(from: pcm)
            }
            guard status == noErr else { throw TapError.osStatus("Create IO proc", status) }

            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw TapError.osStatus("Start device", status) }

            startDate = Date()
            DispatchQueue.main.async { self.beginMetering() }
            set(recording: true, status: "Recording \(source.appName ?? "all system audio")…")
        } catch {
            teardown()
            set(recording: false, status: "Error: \(error.localizedDescription)")
        }
    }

    // MARK: Stop

    func stop() {
        let name = fileURL?.lastPathComponent ?? ""
        teardown()
        lastFileURL = fileURL
        set(recording: false, status: "Saved: \(name)")
    }

    private func teardown() {
        uiTimer?.invalidate()
        uiTimer = nil
        levels = [Float](repeating: 0, count: WaveBars.barCount)
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

    // MARK: Metering

    private func beginMetering() {
        guard isRecording || audioFile != nil else { return }
        elapsed = 0
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        // Map -50 dB…0 dB onto 0…1, with a quick attack and a gentle decay.
        let db = 20 * log10(max(meter.takePeak(), 1e-5))
        let fresh = max(0, min(1, (db + 50) / 50))
        let level = max(fresh, (levels.last ?? 0) * 0.8)
        levels.removeFirst()
        levels.append(level)
        elapsed = Date().timeIntervalSince(startDate)
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

/// The nine bars of the app icon. Shows the logo at rest and a live level meter while recording.
struct WaveBars: View {
    static let barCount = 9
    private static let profile: [CGFloat] = [140, 260, 420, 560, 380, 500, 300, 200, 120].map { $0 / 560 }
    static let coral = Color(red: 0.949, green: 0.420, blue: 0.290)

    /// nil shows the logo shape.
    var levels: [Float]?
    var height: CGFloat = 72

    var body: some View {
        HStack(spacing: height * 0.085) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                Capsule()
                    .fill(Self.coral)
                    .frame(width: height * 0.1, height: barHeight(i))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.1), value: levels)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let shape = Self.profile[i]
        guard let levels else { return height * shape }
        let level = CGFloat(levels[i])
        return height * (0.1 + 0.9 * level * (0.5 + 0.5 * shape))
    }
}

private extension View {
    /// Translucent window background where the OS supports it.
    @ViewBuilder func glassWindowBackground() -> some View {
        if #available(macOS 15, *) {
            self.containerBackground(.regularMaterial, for: .window)
        } else {
            self
        }
    }

    /// Liquid Glass on macOS 26+, a flat tinted circle before that.
    @ViewBuilder func recordButtonBackground(recording: Bool) -> some View {
        let tint = recording ? Color.red.opacity(0.85) : Color.red
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: .circle)
        } else {
            self.background(Circle().fill(tint))
        }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

private func formatElapsed(_ t: TimeInterval) -> String {
    let total = Int(t)
    return String(format: "%02d:%02d", total / 60, total % 60)
}

struct ContentView: View {
    @ObservedObject var recorder: SystemAudioTapRecorder
    @AppStorage(Settings.folderKey) private var folderPath = Settings.defaultFolderPath
    @AppStorage(Settings.modeKey) private var mode = AppMode.window
    @Environment(\.dismissWindow) private var dismissWindow

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
                toggleRecording()
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
        .onAppear {
            // Menu bar only: the scene opens a window at launch; close just that one.
            // Later appearances (e.g. "Show Window") must stay open.
            guard Settings.launchWindowPending else { return }
            Settings.launchWindowPending = false
            if mode == .menuBarOnly { dismissWindow(id: "main") }
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            folderPath = Settings.validFolderPath(folderPath)
            recorder.start(in: URL(fileURLWithPath: folderPath))
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
