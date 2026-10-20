import AVFoundation
import Foundation
import Testing
@testable import AudioRecorder

struct WaveformLoaderTests {
    @Test func loadReportsTheFilesFacts() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = try writeTestWAV(in: temp.url, frames: 48_000)
        let data = try WaveformLoader.load(url: url)
        #expect(data.frameCount == 48_000)
        #expect(data.sampleRate == 48_000)
        #expect(abs(data.duration - 1.0) < 0.0001)
    }

    @Test func peaksAreNormalisedAndFollowTheSignal() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        // A quiet ramp: the loudest bucket should still reach 1.
        let url = try writeTestWAV(in: temp.url, frames: 48_000, amplitude: 0.1)
        let data = try WaveformLoader.load(url: url, buckets: 100)
        #expect(data.peaks.count == 100)
        #expect(data.peaks.max() == 1)
        #expect(data.peaks.first! < data.peaks.last!)
    }

    @Test func emptyRecordingThrows() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = try writeTestWAV(in: temp.url, frames: 0)
        #expect(throws: TrimError.self) { try WaveformLoader.load(url: url) }
    }

    @Test func exportWritesOnlyTheSelectedFrames() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = try writeTestWAV(in: temp.url, name: "Take.wav", frames: 48_000)
        let out = try WaveformLoader.exportTrim(of: url, startFrame: 12_000, endFrame: 36_000)
        #expect(out.lastPathComponent == "Take (trimmed).wav")
        #expect(out.deletingLastPathComponent().path == temp.url.path)
        #expect(try frameCount(of: out) == 24_000)
        #expect(try frameCount(of: url) == 48_000)   // original untouched
    }

    @Test func exportNeverOverwritesAnEarlierTrim() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = try writeTestWAV(in: temp.url, name: "Take.wav", frames: 48_000)
        let first = try WaveformLoader.exportTrim(of: url, startFrame: 0, endFrame: 1_000)
        let second = try WaveformLoader.exportTrim(of: url, startFrame: 0, endFrame: 2_000)
        let third = try WaveformLoader.exportTrim(of: url, startFrame: 0, endFrame: 3_000)
        #expect(first.lastPathComponent == "Take (trimmed).wav")
        #expect(second.lastPathComponent == "Take (trimmed 2).wav")
        #expect(third.lastPathComponent == "Take (trimmed 3).wav")
        #expect(try frameCount(of: first) == 1_000)
    }

    @Test func exportOfAnEmptySelectionThrows() throws {
        let temp = try TempFolder(); defer { temp.remove() }
        let url = try writeTestWAV(in: temp.url, frames: 48_000)
        #expect(throws: TrimError.self) {
            try WaveformLoader.exportTrim(of: url, startFrame: 500, endFrame: 500)
        }
    }
}
