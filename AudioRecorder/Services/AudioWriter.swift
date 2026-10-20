import AVFoundation
import CoreAudio

/// Everything the audio thread touches while recording: the output file, the
/// level meter and the failure flag.
///
/// It is deliberately *not* main-actor isolated. Core Audio calls the block from
/// `ioBlock()` on `queue`, never on the main thread, and a main-actor closure
/// run off the main thread is a data race (and a runtime trap in Swift 6).
///
/// Thread rules, which is why `@unchecked Sendable` is justified:
/// - `file` is only used on `queue` once the writer exists; `close()` clears it
///   with `queue.sync`, so it never races with a buffer being written.
/// - The meter and failure box have their own locks, so `takePeak()` and
///   `takeError()` are safe to call from the main thread.
nonisolated final class AudioWriter: @unchecked Sendable {
    /// The queue Core Audio delivers buffers on.
    let queue = DispatchQueue(label: "system-audio-tap-io")

    private let format: AVAudioFormat
    private var file: AVAudioFile?
    private let meter = PeakMeter()
    private let failure = FailureBox()

    /// Opens `url` for writing as 16-bit PCM WAV (`AVAudioFile` converts on write).
    /// Throws if the file can't be created.
    init(url: URL, format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        self.format = format
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    /// The block to give Core Audio; it runs on `queue`.
    func ioBlock() -> AudioDeviceIOBlock {
        { [self] _, inputData, _, _, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData) else { return }
            write(pcm)
        }
    }

    /// Writes one buffer. Must be called on `queue`. After the first failure
    /// (a full disk, say) nothing more is written and the error waits in `takeError()`.
    func write(_ pcm: AVAudioPCMBuffer) {
        guard let file, !failure.hasFailed else { return }
        meter.record(pcm)
        do { try file.write(from: pcm) } catch { failure.record(error) }
    }

    /// The loudest sample since the last call (0…1).
    func takePeak() -> Float { meter.takePeak() }

    /// The first error raised while writing, once.
    func takeError() -> Error? { failure.take() }

    /// Waits for any buffer being written, then releases the file so it is finalised.
    func close() {
        queue.sync { file = nil }
    }
}
