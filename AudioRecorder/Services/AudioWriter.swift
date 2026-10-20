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
///
/// While recording, the WAV header is refreshed about once a second (see
/// `WAVHeaderUpdater`), so a crash or force-quit loses at most the last couple of
/// seconds instead of leaving a file that reports zero length.
nonisolated final class AudioWriter: @unchecked Sendable {
    /// The queue Core Audio delivers buffers on.
    let queue = DispatchQueue(label: "system-audio-tap-io")

    private let format: AVAudioFormat
    private var file: AVAudioFile?
    private let meter = PeakMeter()
    private let failure = FailureBox()
    private var headerUpdater: WAVHeaderUpdater?
    private let framesPerHeaderUpdate: AVAudioFrameCount
    private var framesSinceHeaderUpdate: AVAudioFrameCount = 0

    /// Opens `url` for writing as 16-bit PCM WAV (`AVAudioFile` converts on write).
    /// Throws if the file can't be created. `headerUpdateInterval` is how many
    /// seconds of audio pass between header refreshes.
    init(url: URL, format: AVAudioFormat, headerUpdateInterval: TimeInterval = 1) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        self.format = format
        framesPerHeaderUpdate = AVAudioFrameCount(max(1, format.sampleRate * headerUpdateInterval))
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        // Best effort: a recording without crash protection is better than none.
        headerUpdater = try? WAVHeaderUpdater(url: url)
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

        framesSinceHeaderUpdate += pcm.frameLength
        if framesSinceHeaderUpdate >= framesPerHeaderUpdate {
            framesSinceHeaderUpdate = 0
            try? headerUpdater?.update()
        }
    }

    /// The loudest sample since the last call (0…1).
    func takePeak() -> Float { meter.takePeak() }

    /// The first error raised while writing, once.
    func takeError() -> Error? { failure.take() }

    /// Waits for any buffer being written, then releases the file so it is finalised.
    func close() {
        queue.sync {
            file = nil  // AVAudioFile writes the exact final sizes as it closes
            headerUpdater?.close()
            headerUpdater = nil
        }
    }
}
