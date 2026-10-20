import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import AudioRecorder

/// Runs `block` the way Core Audio does: on the writer's queue, off the main thread.
/// `nonisolated` so the closure handed to the queue isn't main-actor isolated; in
/// Swift 6 mode a main-actor closure run on another thread would trap.
private nonisolated func deliver(_ pcm: AVAudioPCMBuffer, to block: AudioDeviceIOBlock, on queue: DispatchQueue) {
    queue.sync {
        var stamp = AudioTimeStamp()
        let output = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        output.initialize(to: AudioBufferList())
        defer { output.deallocate() }
        withUnsafePointer(to: &stamp) { time in
            block(time, pcm.audioBufferList, time, output, time)
        }
    }
}

struct AudioWriterTests {
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!

    private func buffer(frames: Int, amplitude: Float) -> AVAudioPCMBuffer {
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for i in 0..<frames { pcm.floatChannelData![channel][i] = amplitude }
        }
        return pcm
    }

    @Test func buffersDeliveredByTheIOBlockEndUpInTheFile() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("out.wav")
        let writer = try AudioWriter(url: url, format: format)
        let block = writer.ioBlock()
        for _ in 0..<3 { deliver(buffer(frames: 4_800, amplitude: 0.25), to: block, on: writer.queue) }
        writer.close()
        #expect(try frameCount(of: url) == 14_400)
    }

    @Test func closeFinalisesTheFileHeader() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("out.wav")
        let writer = try AudioWriter(url: url, format: format)
        deliver(buffer(frames: 48_000, amplitude: 0.1), to: writer.ioBlock(), on: writer.queue)
        writer.close()
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 48_000)
        #expect(file.processingFormat.sampleRate == 48_000)
        #expect(file.processingFormat.channelCount == 2)
    }

    @Test func peakReportsTheLoudestSampleThenResets() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let writer = try AudioWriter(url: temp.url.appendingPathComponent("out.wav"), format: format)
        let block = writer.ioBlock()
        #expect(writer.takePeak() == 0)
        deliver(buffer(frames: 480, amplitude: 0.2), to: block, on: writer.queue)
        deliver(buffer(frames: 480, amplitude: 0.6), to: block, on: writer.queue)
        deliver(buffer(frames: 480, amplitude: 0.3), to: block, on: writer.queue)
        #expect(abs(writer.takePeak() - 0.6) < 0.0001)
        #expect(writer.takePeak() == 0)
        writer.close()
    }

    @Test func theFileIsReadableWhileStillRecording() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("live.wav")
        // Refresh the header after every buffer so the test doesn't need a second of audio.
        let writer = try AudioWriter(url: url, format: format, headerUpdateInterval: 0.01)
        let block = writer.ioBlock()
        for _ in 0..<20 { deliver(buffer(frames: 4_800, amplitude: 0.3), to: block, on: writer.queue) }
        // Not closed yet, as if the app had just crashed: the audio so far is already readable.
        let readable = try frameCount(of: url)
        #expect(readable > 0)
        #expect(readable <= 96_000)
        writer.close()
        #expect(try frameCount(of: url) == 96_000)
    }

    @Test func writingAfterCloseDoesNothing() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("out.wav")
        let writer = try AudioWriter(url: url, format: format)
        let block = writer.ioBlock()
        deliver(buffer(frames: 4_800, amplitude: 0.5), to: block, on: writer.queue)
        writer.close()
        deliver(buffer(frames: 4_800, amplitude: 0.5), to: block, on: writer.queue)
        #expect(try frameCount(of: url) == 4_800)
        #expect(writer.takeError() == nil)
    }

    @Test func nothingHasFailedAfterNormalWriting() throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let writer = try AudioWriter(url: temp.url.appendingPathComponent("out.wav"), format: format)
        deliver(buffer(frames: 480, amplitude: 0.5), to: writer.ioBlock(), on: writer.queue)
        #expect(writer.takeError() == nil)
        writer.close()
    }

    @Test func theMainThreadCanReadWhileTheAudioQueueWrites() async throws {
        let temp = try TempFolder()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("out.wav")
        let writer = try AudioWriter(url: url, format: format)
        deliverRepeatedly(count: 200, frames: 480, amplitude: 0.4, to: writer)
        var heard = false
        for _ in 0..<200 {
            if writer.takePeak() > 0.39 { heard = true }
            _ = writer.takeError()
            try await Task.sleep(for: .milliseconds(1))
        }
        writer.close()
        #expect(heard)
        #expect(try frameCount(of: url) == 96_000)
    }

    @Test func anUnwritableLocationThrows() {
        let url = URL(fileURLWithPath: "/no/such/folder/\(UUID().uuidString)/out.wav")
        #expect(throws: (any Error).self) { try AudioWriter(url: url, format: format) }
    }
}

/// Delivers `count` buffers from the writer's queue, asynchronously, the way the
/// audio thread would while the main thread keeps reading. Builds its own buffer
/// so nothing non-Sendable crosses threads.
private nonisolated func deliverRepeatedly(count: Int, frames: Int, amplitude: Float, to writer: AudioWriter) {
    writer.queue.async {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for i in 0..<frames { pcm.floatChannelData![channel][i] = amplitude }
        }
        let block = writer.ioBlock()
        var stamp = AudioTimeStamp()
        let output = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        output.initialize(to: AudioBufferList())
        defer { output.deallocate() }
        withUnsafePointer(to: &stamp) { time in
            for _ in 0..<count { block(time, pcm.audioBufferList, time, output, time) }
        }
    }
}
