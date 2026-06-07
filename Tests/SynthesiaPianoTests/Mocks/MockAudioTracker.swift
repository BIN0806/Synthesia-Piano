//
//  MockAudioTracker.swift
//  SynthesiaPianoTests
//
//  Test double for the audio DSP layer. Conforms to `PitchDetecting` exactly
//  like `AudioTrackerEngine`, but instead of opening a microphone it replays a
//  scripted array of `PitchEvent`s into its `AsyncStream` on a controlled timer
//  — deterministically simulating live mic input.
//

import Foundation
@testable import SynthesiaPiano

actor MockAudioTracker: PitchDetecting {

    /// Mirror the real engine's MVP capability.
    nonisolated let capability: DetectionCapability = .monophonic

    nonisolated let pitchStream: AsyncStream<PitchEvent>
    private let continuation: AsyncStream<PitchEvent>.Continuation

    /// The events to replay, in order.
    private let scriptedEvents: [PitchEvent]

    /// Real-time delay between successive emissions (gives the consumer time to
    /// drain the `.bufferingNewest(1)` stream so no scripted event is dropped).
    private let interval: TimeInterval

    private var emitTask: Task<Void, Never>?

    init(script: [PitchEvent], interval: TimeInterval = 0.02) {
        self.scriptedEvents = script
        self.interval = interval
        var cont: AsyncStream<PitchEvent>.Continuation!
        self.pitchStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            cont = $0
        }
        self.continuation = cont
    }

    /// Convenience: build from (frequency, amplitude) pairs at a fixed cadence.
    init(
        tones: [(frequency: Double, amplitude: Double)],
        interval: TimeInterval = 0.02,
        timestampStep: TimeInterval = 0.05
    ) {
        var events: [PitchEvent] = []
        var t: TimeInterval = 0
        for tone in tones {
            events.append(
                PitchEvent(
                    frequencies: tone.frequency > 0 ? [tone.frequency] : [],
                    amplitude: tone.amplitude,
                    timestamp: t
                )
            )
            t += timestampStep
        }
        self.scriptedEvents = events
        self.interval = interval
        var cont: AsyncStream<PitchEvent>.Continuation!
        self.pitchStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            cont = $0
        }
        self.continuation = cont
    }

    // MARK: PitchDetecting

    func start() async throws {
        guard emitTask == nil else { return }
        emitTask = Task { [scriptedEvents, interval, continuation] in
            for event in scriptedEvents {
                if Task.isCancelled { break }
                continuation.yield(event)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            continuation.finish()
        }
    }

    func stop() async {
        emitTask?.cancel()
        emitTask = nil
        continuation.finish()
    }
}
