//
//  AudioTrackerEngine.swift
//  SynthesiaPiano
//
//  Audio DSP layer. Wraps AudioKit's microphone graph + PitchTap (YIN/MPM) and
//  republishes results as a Swift-Concurrency `AsyncStream<PitchEvent>`.
//
//  ============================================================================
//  DEPENDENCY / PROJECT SETUP (not generated here — sources only):
//    1. Add AudioKit via SPM:
//         https://github.com/AudioKit/AudioKit            (AudioKit)
//         https://github.com/AudioKit/AudioKitEX          (PitchTap lives here)
//         https://github.com/AudioKit/SoundpipeAudioKit   (DSP nodes)
//    2. Info.plist:
//         NSMicrophoneUsageDescription = "Used to listen to your playing."
//    3. Enable the "Audio" background mode if you want tracking to continue
//       while backgrounded (optional for the MVP).
//
//  If AudioKit is not yet linked, the `import` lines below will fail to compile.
//  ============================================================================
//
//  ----------------------------------------------------------------------------
//  MVP LIMITATION — MONOPHONIC ONLY
//  PitchTap (YIN / MPM) resolves a SINGLE fundamental frequency. A piano is
//  polyphonic, so chords are explicitly OUT OF SCOPE for the MVP. This engine
//  therefore reports `capability == .monophonic` and fills `PitchEvent` with at
//  most one frequency.
//
//  Polyphony swap path (no downstream changes required):
//    - Replace `PitchTap` with an `FFTTap` + spectral peak picker, OR a CoreML
//      audio-classification model, and emit multiple `frequencies`.
//    - Flip `capability` to `.polyphonic(maxVoices:)`.
//  ----------------------------------------------------------------------------
//

import Foundation
import AVFoundation
import AudioKit
import AudioKitEX
import SoundpipeAudioKit

public actor AudioTrackerEngine: PitchDetecting {

    // MARK: Capability

    /// MVP: single-fundamental detection only. See file header for the swap path.
    public nonisolated let capability: DetectionCapability = .monophonic

    // MARK: Tuning constants

    /// "Goldilocks" IO buffer: ~23 ms ≈ 1024 frames @ 44.1 kHz.
    ///
    /// Why not smaller? A 256-frame (~6 ms) buffer feels instantaneous but is
    /// too short to capture the long wavelengths of low piano notes (e.g. C2 ≈
    /// 65 Hz, ~16 ms period), causing missed bass notes. ~23 ms is the sweet
    /// spot: fast enough to feel realtime, long enough to resolve the low
    /// register.
    private static let preferredBufferDuration: TimeInterval = 0.023

    /// Frames below this RMS amplitude are treated as silence and skipped.
    private static let amplitudeFloor: Double = 0.05

    // MARK: Audio graph

    private let engine = AudioEngine()
    private var mic: Node?
    private var tap: PitchTap?
    /// A silent mixer keeps the graph pulling without monitoring the mic to the
    /// speakers (which would feed back).
    private var silence: Fader?

    // MARK: Stream plumbing

    public nonisolated let pitchStream: AsyncStream<PitchEvent>
    private let continuation: AsyncStream<PitchEvent>.Continuation
    private var isRunning = false

    // MARK: Init

    public init() {
        // `.bufferingNewest(1)` => if the consumer (follower) falls behind, we
        // drop stale frames rather than block the realtime audio callback.
        var cont: AsyncStream<PitchEvent>.Continuation!
        self.pitchStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            cont = $0
        }
        self.continuation = cont
    }

    // MARK: PitchDetecting

    public func start() async throws {
        guard !isRunning else { return }

        try configureSession()

        guard let input = engine.input else {
            throw AudioTrackerError.microphoneUnavailable
        }
        self.mic = input

        // Tap the mic for pitch + amplitude. The callback runs on AudioKit's
        // realtime audio thread — keep it allocation-free and non-blocking.
        let tap = PitchTap(input) { [weak self] pitches, amplitudes in
            let frequency = Double(pitches.first ?? 0)
            let amplitude = Double(amplitudes.first ?? 0)
            // Hop onto the actor to mutate/emit safely off the audio thread.
            Task { [weak self] in
                await self?.ingest(frequency: frequency, amplitude: amplitude)
            }
        }
        self.tap = tap

        // Route mic -> silent fader -> output so the engine keeps running
        // without audible monitoring.
        let silence = Fader(input, gain: 0)
        self.silence = silence
        engine.output = silence

        try engine.start()
        tap.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        tap?.stop()
        engine.stop()
        tap = nil
        silence = nil
        mic = nil
        isRunning = false
        continuation.finish()
    }

    // MARK: Internals

    /// Configure AVAudioSession for low-latency measurement-grade capture and
    /// request the Goldilocks buffer size.
    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                 mode: .measurement,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        // Ask CoreAudio for ~23 ms IO buffers (best-effort; hardware may round).
        try session.setPreferredIOBufferDuration(Self.preferredBufferDuration)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Convert a raw tap callback into a gated `PitchEvent` on the actor.
    private func ingest(frequency: Double, amplitude: Double) {
        guard isRunning else { return }

        // Silence gate: emit unvoiced frames as empty so the follower can tell
        // "playing nothing" from "playing the wrong note".
        let voiced = amplitude >= Self.amplitudeFloor && frequency > 0
        let event = PitchEvent(
            frequencies: voiced ? [frequency] : [],
            amplitude: amplitude,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        continuation.yield(event)
    }
}

// MARK: - Errors

public enum AudioTrackerError: Error, Sendable {
    case microphoneUnavailable
}
