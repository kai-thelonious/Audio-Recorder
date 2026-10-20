import CoreAudio
import AVFoundation
import Combine

// Requires macOS 14.2+ and an Info.plist key:
//   NSAudioCaptureUsageDescription  ("Privacy - Audio Capture Usage Description")

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
