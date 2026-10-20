import Testing

@testable import AudioRecorder

struct MeterLevelTests {
    @Test func silenceIsZero() {
        #expect(RecorderViewModel.meterLevel(peak: 0, previous: 0) == 0)
    }

    @Test func fullScaleIsOne() {
        #expect(RecorderViewModel.meterLevel(peak: 1, previous: 0) == 1)
    }

    @Test func belowFiftyDecibelsIsZero() {
        // -60 dB
        #expect(RecorderViewModel.meterLevel(peak: 0.001, previous: 0) == 0)
    }

    @Test func minusTwentyFiveDecibelsIsHalf() {
        // -25 dB is halfway between -50 dB and 0 dB.
        let level = RecorderViewModel.meterLevel(peak: 0.0562341325, previous: 0)
        #expect(abs(level - 0.5) < 0.01)
    }

    @Test func fallsOffGraduallyAfterALoudSound() {
        #expect(abs(RecorderViewModel.meterLevel(peak: 0, previous: 1) - 0.8) < 0.0001)
        #expect(abs(RecorderViewModel.meterLevel(peak: 0, previous: 0.5) - 0.4) < 0.0001)
    }

    @Test func risesImmediatelyToANewLoudSound() {
        #expect(RecorderViewModel.meterLevel(peak: 1, previous: 0.2) == 1)
    }

    @Test func staysWithinZeroAndOne() {
        #expect(RecorderViewModel.meterLevel(peak: 50, previous: 0) == 1)
    }
}
