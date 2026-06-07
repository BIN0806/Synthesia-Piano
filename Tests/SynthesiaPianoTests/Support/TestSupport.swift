//
//  TestSupport.swift
//  SynthesiaPianoTests
//
//  Shared helpers for the follower test suite: pitch math (including cent
//  detuning), script + score builders, and a race-free index recorder.
//
//  NOTE: adjust the module name in `@testable import` below if your app target
//  is not named `SynthesiaPiano`.
//

import Foundation
@testable import SynthesiaPiano

// MARK: - Pitch math

/// Equal-temperament frequency for a MIDI note, optionally detuned by `cents`.
/// 100 cents == one semitone. Used to simulate slightly flat/sharp playing.
func frequency(midi: Int, cents: Double = 0) -> Double {
    let base = 440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
    return base * pow(2.0, cents / 1200.0)
}

// MARK: - Builders

/// Build a `ScoreManager` from MIDI note numbers, half-second beats apart.
func makeScore(_ midis: [Int]) -> ScoreManager {
    let beat: TimeInterval = 0.5
    let notes = midis.enumerated().map { index, midi in
        NoteEvent(
            pitch: MIDINote(number: midi),
            onset: TimeInterval(index) * beat,
            duration: beat * 0.9,
            velocity: 90
        )
    }
    return ScoreManager(notes: notes)
}

/// Build a scripted sequence of `PitchEvent`s for the mock to emit.
///
/// Each note is repeated `repeatsPerNote` times and the per-event `timestamp`
/// advances by `step`. Because `ScoreFollower` confirms a match using the event
/// timestamps (not wall-clock), `step` controls whether the >= 0.04s
/// confirmation window is satisfied. `repeatsPerNote: 4` with `step: 0.05`
/// reliably clears it while leaving `pendingMatchSince` reset between notes.
func makeScript(
    midis: [Int],
    cents: Double = 0,
    amplitude: Double = 0.5,
    repeatsPerNote: Int = 4,
    step: TimeInterval = 0.05,
    startTimestamp: TimeInterval = 0
) -> [PitchEvent] {
    var events: [PitchEvent] = []
    var t = startTimestamp
    for midi in midis {
        let freq = frequency(midi: midi, cents: cents)
        for _ in 0..<repeatsPerNote {
            events.append(PitchEvent(frequencies: [freq], amplitude: amplitude, timestamp: t))
            t += step
        }
    }
    return events
}

// MARK: - IndexRecorder

/// Actor-isolated collector for `FollowState.currentIndex` values, so the test's
/// stream-consuming task never races with assertions.
actor IndexRecorder {
    private(set) var indices: [Int] = []

    func record(_ index: Int) { indices.append(index) }

    var last: Int { indices.last ?? 0 }
    var maxIndex: Int { indices.max() ?? 0 }
}

// MARK: - Harness

/// Wire a `ScoreFollower` to a `MockAudioTracker`, play the script, and return
/// the recorder once playback + a settle window have elapsed.
@discardableResult
func runFollower(
    score: ScoreProviding,
    script events: [PitchEvent],
    interval: TimeInterval = 0.02,
    settle: TimeInterval = 0.4
) async -> IndexRecorder {
    let mock = MockAudioTracker(script: events, interval: interval)
    let follower = ScoreFollower(score: score, detector: mock)
    let recorder = IndexRecorder()

    await follower.start()

    let consume = Task {
        for await state in follower.stateStream {
            await recorder.record(state.currentIndex)
        }
    }

    try? await mock.start()

    let playback = TimeInterval(events.count) * interval
    try? await Task.sleep(nanoseconds: UInt64((playback + settle) * 1_000_000_000))

    consume.cancel()
    await follower.stop()
    await mock.stop()
    return recorder
}
