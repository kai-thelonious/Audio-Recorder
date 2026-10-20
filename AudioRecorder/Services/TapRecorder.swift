import CoreAudio
import AVFoundation

// Requires macOS 14.2+ and an Info.plist key:
//   NSAudioCaptureUsageDescription  ("Privacy - Audio Capture Usage Description")

/// Records audio to a file. The view model talks to this protocol, so it can be
/// tested without touching Core Audio.
protocol AudioRecording: AnyObject {
    /// Starts writing `source` to `fileURL`. Throws if recording could not start.
    func start(source: ResolvedSource, fileURL: URL) throws
    /// Stops recording and finalises the file.
    func stop()
    /// The loudest sample since the last call (0…1), for the level meter.
    func takePeak() -> Float
    /// The first error that happened while recording (for example a full disk), once.
    func takeError() -> Error?
}

/// Core Audio engine: a process tap wrapped in a tap-only aggregate device,
/// written to a 16-bit WAV file by an `AudioWriter`. Holds no UI state.
final class TapRecorder: AudioRecording {
    private var createdFile = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: AudioWriter?

    // MARK: Start

    func start(source: ResolvedSource, fileURL url: URL) throws {
        createdFile = false
        do {
            try startCapture(source: source, fileURL: url)
        } catch {
            teardown()
            // Don't leave an empty recording behind.
            if createdFile { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private func startCapture(source: ResolvedSource, fileURL url: URL) throws {
        // 1. Describe the tap: one app's processes if a source is chosen,
        //    otherwise all system audio (see AudioSources.swift).
        //    (Pass your own process's AudioObjectID in the array to exclude it.)
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

        // 5. Open the output file (16-bit PCM WAV)
        let writer = try AudioWriter(url: url, format: format)
        self.writer = writer
        createdFile = true

        // 6. Receive audio buffers from the aggregate device. The block is made by
        //    the writer, so it never touches this main-actor class from the audio thread.
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, writer.queue, writer.ioBlock())
        guard status == noErr else { throw TapError.osStatus("Create IO proc", status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.osStatus("Start device", status) }
    }

    // MARK: Stop

    func stop() {
        teardown()
    }

    func takePeak() -> Float {
        writer?.takePeak() ?? 0
    }

    func takeError() -> Error? {
        writer?.takeError()
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

        // Wait for any buffer in flight, then release the file so it gets finalized
        writer?.close()
        writer = nil
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
}
