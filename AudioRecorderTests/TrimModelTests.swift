import Foundation
import Testing
@testable import AudioRecorder

struct TrimModelTests {
    private func makeModel(duration: Double = 10) -> TrimModel {
        let model = TrimModel(sourceURL: URL(fileURLWithPath: "/tmp/Take.wav"))
        model.data = WaveformData(peaks: [0.5], duration: duration, sampleRate: 48_000, frameCount: Int64(duration * 48_000))
        model.start = 0
        model.end = duration
        return model
    }

    @Test func startMovesWithinTheSelection() {
        let model = makeModel()
        model.setStart(3)
        #expect(model.start == 3)
        #expect(model.playhead == 3)
    }

    @Test func startCannotGoBelowZero() {
        let model = makeModel()
        model.setStart(-4)
        #expect(model.start == 0)
    }

    @Test func startStopsShortOfTheEnd() {
        let model = makeModel()
        model.setEnd(5)
        model.setStart(9)
        #expect(model.start == 5 - TrimModel.minLength)
    }

    @Test func endCannotPassTheDuration() {
        let model = makeModel()
        model.setEnd(99)
        #expect(model.end == 10)
    }

    @Test func endStaysAfterTheStart() {
        let model = makeModel()
        model.setStart(4)
        model.setEnd(1)
        #expect(model.end == 4 + TrimModel.minLength)
    }

    @Test func dragHandsOverTheOriginalUntilATrimIsSaved() {
        let model = makeModel()
        #expect(model.dragURL.lastPathComponent == "Take.wav")
        model.savedURL = URL(fileURLWithPath: "/tmp/Take (trimmed).wav")
        #expect(model.dragURL.lastPathComponent == "Take (trimmed).wav")
    }
}
