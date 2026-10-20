import AVFoundation

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
