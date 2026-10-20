import AVFoundation
import Foundation
@testable import AudioRecorder

/// A recorder that never touches Core Audio.
final class FakeRecorder: AudioRecording {
    var startError: Error?
    var peak: Float = 0
    private(set) var startedWith: (source: ResolvedSource, fileURL: URL)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(source: ResolvedSource, fileURL: URL) throws {
        startCount += 1
        if let startError { throw startError }
        startedWith = (source, fileURL)
    }

    func stop() { stopCount += 1 }
    func takePeak() -> Float { peak }
}

/// A scratch folder that is deleted when the test ends.
struct TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// UserDefaults that don't touch the real preferences.
func makeTestDefaults() -> UserDefaults {
    UserDefaults(suiteName: "AudioRecorderTests." + UUID().uuidString)!
}

/// Writes a 16-bit stereo WAV whose samples ramp from 0 up to `amplitude`.
func writeTestWAV(in folder: URL, name: String = "test.wav", frames: Int, sampleRate: Double = 48_000, amplitude: Float = 0.5) throws -> URL {
    let url = folder.appendingPathComponent(name)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]
    var file: AVAudioFile? = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    if frames > 0 {
        let buffer = AVAudioPCMBuffer(pcmFormat: file!.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<frames { samples[i] = amplitude * Float(i) / Float(frames) }
        }
        try file?.write(from: buffer)
    }
    file = nil   // finalise the file
    return url
}

func frameCount(of url: URL) throws -> Int {
    Int(try AVAudioFile(forReading: url).length)
}
