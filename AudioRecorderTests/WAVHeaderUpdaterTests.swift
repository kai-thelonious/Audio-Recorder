import AVFoundation
import Foundation
import Testing
@testable import AudioRecorder

struct WAVHeaderUpdaterTests {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!

    private func openWriter(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private func buffer(frames: Int) -> AVAudioPCMBuffer {
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 { for i in 0..<frames { pcm.floatChannelData![channel][i] = 0.3 } }
        return pcm
    }

    /// A tiny mono 16-bit WAV whose header claims no audio, followed by `audioBytes` of data.
    private func handBuiltWAV(at url: URL, audioBytes: Int, extraChunk: Bool = false) throws {
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var bytes = Array("RIFF".utf8) + le32(0) + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + le32(16) + [1, 0, 1, 0] + le32(48_000) + le32(96_000) + [2, 0, 16, 0]
        if extraChunk { bytes += Array("LIST".utf8) + le32(3) + [1, 2, 3, 0] }   // odd size: padded to even
        bytes += Array("data".utf8) + le32(0) + [UInt8](repeating: 7, count: audioBytes)
        try Data(bytes).write(to: url)
    }

    private func sizes(of url: URL) throws -> (riff: UInt32, data: UInt32) {
        let data = try Data(contentsOf: url)
        let riff = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        let range = data.range(of: Data("data".utf8))!
        let dataSize = data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: range.upperBound, as: UInt32.self))
        }
        return (riff, dataSize)
    }

    @Test func anUnfinishedFileLooksEmptyUntilTheHeaderIsUpdated() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("open.wav")
        let writer = try openWriter(at: url)          // never closed: like a crash
        let updater = try WAVHeaderUpdater(url: url)
        defer { updater.close() }
        try writer.write(from: buffer(frames: 48_000))
        #expect(try AVAudioFile(forReading: url).length == 0)
        try updater.update()
        let recovered = try AVAudioFile(forReading: url).length
        #expect(recovered > 0 && recovered <= 48_000)
    }

    @Test func updatingWhileWritingDoesNotCorruptTheFinalFile() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("grow.wav")
        var writer: AVAudioFile? = try openWriter(at: url)
        let updater = try WAVHeaderUpdater(url: url)
        for _ in 0..<5 {
            try writer?.write(from: buffer(frames: 9_600))
            try updater.update()
        }
        writer = nil                                   // closes the file
        updater.close()
        #expect(try frameCount(of: url) == 48_000)
    }

    @Test func sizesMatchTheFileLength() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("hand.wav")
        try handBuiltWAV(at: url, audioBytes: 1_000)
        let updater = try WAVHeaderUpdater(url: url)
        try updater.update()
        updater.close()
        let length = try Data(contentsOf: url).count
        let found = try sizes(of: url)
        #expect(Int(found.riff) == length - 8)
        #expect(found.data == 1_000)
    }

    @Test func onlyWholeFramesAreCounted() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("hand.wav")
        try handBuiltWAV(at: url, audioBytes: 1_001)   // mono 16-bit: 2 bytes per frame
        let updater = try WAVHeaderUpdater(url: url)
        try updater.update()
        updater.close()
        #expect(try sizes(of: url).data == 1_000)
    }

    @Test func chunksBeforeTheDataChunkAreSkipped() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("hand.wav")
        try handBuiltWAV(at: url, audioBytes: 400, extraChunk: true)
        let updater = try WAVHeaderUpdater(url: url)
        try updater.update()
        updater.close()
        #expect(try sizes(of: url).data == 400)
    }

    @Test func repeatedUpdatesFollowTheGrowingFile() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("hand.wav")
        try handBuiltWAV(at: url, audioBytes: 100)
        let updater = try WAVHeaderUpdater(url: url)
        defer { updater.close() }
        try updater.update()
        #expect(try sizes(of: url).data == 100)
        let append = try FileHandle(forWritingTo: url)
        try append.seekToEnd()
        try append.write(contentsOf: Data(repeating: 1, count: 300))
        try append.close()
        try updater.update()
        #expect(try sizes(of: url).data == 400)
    }

    @Test func aFileThatIsNotWAVIsRejected() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("not.wav")
        try Data("this is not a wav file at all".utf8).write(to: url)
        #expect(throws: WAVHeaderUpdater.UpdateError.notAWAVFile) { try WAVHeaderUpdater(url: url) }
    }

    @Test func aWAVWithoutADataChunkIsRejected() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = temp.url.appendingPathComponent("nodata.wav")
        let bytes = Array("RIFF".utf8) + [4, 0, 0, 0] + Array("WAVE".utf8)
        try Data(bytes).write(to: url)
        #expect(throws: WAVHeaderUpdater.UpdateError.noDataChunk) { try WAVHeaderUpdater(url: url) }
    }
}
