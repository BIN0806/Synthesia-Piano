//
//  ScoreFollowerTests.swift
//  SynthesiaPianoTests
//
//  Exercises the alignment engine end-to-end through its real AsyncStream
//  boundary, driven by MockAudioTracker. Scores use intervals >= 2 semitones so
//  the linear-distance matcher (tolerance 1 semitone) advances unambiguously.
//

import XCTest
@testable import SynthesiaPiano

final class ScoreFollowerTests: XCTestCase {

    /// Intervals are all >= 3 semitones so the 1-semitone tolerance never makes
    /// adjacent notes ambiguous.
    private let melody = [60, 64, 67, 72] // C4, E4, G4, C5

    // MARK: Test 1 - Perfect Match

    /// Feeding the exact frequencies of the score advances currentIndex all the
    /// way to the final note.
    func testPerfectMatchAdvancesThroughAllNotes() async {
        let score = makeScore(melody)
        let recorder = await runFollower(score: score, script: makeScript(midis: melody))

        let last = await recorder.last
        let maxIndex = await recorder.maxIndex

        XCTAssertEqual(maxIndex, melody.count - 1, "follower should reach the final note index")
        XCTAssertEqual(last, melody.count - 1, "follower should end on the final note index")
    }

    // MARK: Test 2 - Silence / Noise

    /// Correct pitch but BELOW the silence gate must not advance the score —
    /// proves the amplitude gate is respected.
    func testSilenceBelowGateDoesNotAdvance() async {
        let score = makeScore(melody)
        // Correct frequencies, but amplitude 0.01 < follower's 0.05 floor.
        let silent = makeScript(midis: melody, amplitude: 0.01)
        let recorder = await runFollower(score: score, script: silent)

        let maxIndex = await recorder.maxIndex
        XCTAssertEqual(maxIndex, 0, "silent (gated) input must not advance the score")
    }

    /// Loud but un-pitched / wrong noise that never matches expected or next
    /// note must not advance the score.
    func testNoiseDoesNotAdvance() async {
        let score = makeScore(melody)
        // Loud, wildly fluctuating frequencies far from any melody note.
        let noiseFreqs = [1500.0, 1850.0, 1500.0, 1850.0, 1500.0, 1850.0, 1500.0, 1850.0]
        var t: TimeInterval = 0
        let noise = noiseFreqs.map { f -> PitchEvent in
            defer { t += 0.05 }
            return PitchEvent(frequencies: [f], amplitude: 0.7, timestamp: t)
        }
        let recorder = await runFollower(score: score, script: noise)

        let maxIndex = await recorder.maxIndex
        XCTAssertEqual(maxIndex, 0, "un-pitched noise must not advance the score")
    }

    // MARK: Test 3 - Hysteresis / Tolerance

    /// Slightly sharp playing (+10 cents) still snaps to the nearest MIDI note
    /// and advances fully.
    func testSlightlySharpStillAdvances() async {
        let score = makeScore(melody)
        let recorder = await runFollower(score: score, script: makeScript(midis: melody, cents: 10))

        let last = await recorder.last
        XCTAssertEqual(last, melody.count - 1, "+10 cent detune should still advance fully")
    }

    /// Slightly flat playing (-10 cents) still snaps to the nearest MIDI note
    /// and advances fully.
    func testSlightlyFlatStillAdvances() async {
        let score = makeScore(melody)
        let recorder = await runFollower(score: score, script: makeScript(midis: melody, cents: -10))

        let last = await recorder.last
        XCTAssertEqual(last, melody.count - 1, "-10 cent detune should still advance fully")
    }

    /// Focused, synchronous check that the cent-detuning used above really does
    /// resolve to the intended MIDI note (the core of the tolerance behavior).
    func testNearestMIDINoteSnapsWithinTolerance() {
        for midi in melody {
            let sharp = MIDINote(frequency: frequency(midi: midi, cents: 10))
            let flat = MIDINote(frequency: frequency(midi: midi, cents: -10))
            XCTAssertEqual(sharp?.number, UInt8(midi), "+10 cents should round to MIDI \(midi)")
            XCTAssertEqual(flat?.number, UInt8(midi), "-10 cents should round to MIDI \(midi)")
        }
    }
}
