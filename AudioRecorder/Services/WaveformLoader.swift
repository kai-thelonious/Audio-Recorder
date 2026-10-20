import AVFoundation

/// Downsampled peak data for drawing a waveform, plus the file facts the trim editor needs.
struct WaveformData: Sendable {
    var peaks: [Float]  // 0...1, one value per bucket
    var duration: TimeInterval
    var sampleRate: Double
    var frameCount: AVAudioFramePosition
}

enum TrimError: LocalizedError {
    case emptySelection
    case message(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection: return "The selection is empty"
        case .message(let m): return m
        }
    }
}

enum WaveformLoader {
    /// Reads the whole file in chunks and keeps the max absolute sample per bucket. Call off the main thread.
    nonisolated static func load(url: URL, buckets: Int = 600) throws -> WaveformData {
        let file = try AVAudioFile(forReading: url)
        let total = file.length
        guard total > 0 else { throw TrimError.message("The recording is empty") }

        let framesPerBucket = max(1, Int(total) / buckets)
        let bucketCount = Int((total + Int64(framesPerBucket) - 1) / Int64(framesPerBucket))
        var peaks = [Float](repeating: 0, count: bucketCount)

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
            throw TrimError.message("Could not allocate an audio buffer")
        }
        var position = 0
        while position < Int(total) {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            if let channels = buffer.floatChannelData {
                for c in 0..<Int(buffer.format.channelCount) {
                    let samples = channels[c]
                    for i in 0..<n {
                        let bucket = min((position + i) / framesPerBucket, bucketCount - 1)
                        let v = abs(samples[i])
                        if v > peaks[bucket] { peaks[bucket] = v }
                    }
                }
            }
            position += n
        }

        // Normalise so quiet recordings are still readable.
        if let top = peaks.max(), top > 0 {
            peaks = peaks.map { min(1, $0 / top) }
        }
        let rate = file.processingFormat.sampleRate
        return WaveformData(peaks: peaks, duration: Double(total) / rate, sampleRate: rate, frameCount: total)
    }

    /// Writes frames [start, end) to "<name> (trimmed).wav" next to the original, as 16-bit PCM WAV.
    /// Never overwrites: picks "(trimmed 2)", "(trimmed 3)"… if the name is taken.
    nonisolated static func exportTrim(of url: URL, startFrame: AVAudioFramePosition, endFrame: AVAudioFramePosition)
        throws -> URL
    {
        guard endFrame > startFrame else { throw TrimError.emptySelection }
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat

        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent("\(base) (trimmed).wav")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) (trimmed \(counter)).wav")
            counter += 1
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        var output: AVAudioFile? = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        source.framePosition = startFrame
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw TrimError.message("Could not allocate an audio buffer")
        }
        var remaining = endFrame - startFrame
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(chunk), remaining))
            try source.read(into: buffer, frameCount: count)
            if buffer.frameLength == 0 { break }
            try output?.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
        output = nil  // finalize the file
        return destination
    }
}
