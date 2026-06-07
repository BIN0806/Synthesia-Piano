//
//  PitchDetecting.swift
//  SynthesiaPiano
//
//  Audio DSP boundary. Anything that turns microphone input into a stream of
//  `PitchEvent`s conforms to this. Keeping it protocol-first means the AudioKit
//  implementation can be swapped for:
//    - a mock / file-playback detector in unit tests, or
//    - a future *polyphonic* FFT / CoreML detector for chord support
//  without touching the alignment engine, view model, or views.
//

import Foundation

/// A microphone-driven pitch source, modeled as an actor so its internal audio
/// state is isolated from the main thread.
public protocol PitchDetecting: Actor {

    /// What this detector can resolve. The MVP returns `.monophonic`.
    ///
    /// `nonisolated` because capability is fixed at construction and callers
    /// (e.g. the follower) may need it synchronously without `await`.
    nonisolated var capability: DetectionCapability { get }

    /// Continuous stream of live pitch samples.
    ///
    /// Backed by an `AsyncStream` with newest-value buffering so a slow consumer
    /// never blocks the realtime audio callback (back-pressure safe).
    ///
    /// `nonisolated` so consumers can grab the stream synchronously through the
    /// `any PitchDetecting` existential (it's an immutable `let` under the hood).
    nonisolated var pitchStream: AsyncStream<PitchEvent> { get }

    /// Configure the audio session + graph and begin tapping the mic.
    func start() async throws

    /// Stop the graph and finish the stream.
    func stop() async
}
