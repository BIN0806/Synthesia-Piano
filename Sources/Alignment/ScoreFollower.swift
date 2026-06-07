//
//  ScoreFollower.swift
//  SynthesiaPiano
//
//  Alignment layer. Consumes the live pitch stream and the reference score,
//  decides "where in the piece is the player right now", and emits FollowState.
//
//  The matcher here is a deliberately simple LINEAR DISTANCE + THRESHOLD scheme.
//  It is a placeholder for a real Dynamic Time Warping (DTW) / HMM score
//  follower — the protocol boundary lets us upgrade the algorithm later without
//  touching the view model or views.
//

import Foundation

// MARK: - FollowState

/// The follower's published position.
///
/// Carries BOTH representations on purpose:
///   - `currentIndex` is DISCRETE — perfect for VexFlow's sheet music, which
///     jumps from note head to note head.
///   - `currentTimePosition` is CONTINUOUS — required by the SpriteKit falling-
///     notes view so it can scroll smoothly at 60 FPS instead of snapping
///     between indices.
public struct FollowState: Sendable, Equatable {

    /// Index of the currently-expected note in `ScoreProviding.notes`.
    public let currentIndex: Int

    /// Continuously interpolated playback position in seconds. Advances between
    /// discrete matches so the animation never stalls.
    public let currentTimePosition: TimeInterval

    /// Progress through the whole piece, 0...1 (convenience for progress bars).
    public let progress: Double

    /// The note the follower believes was just matched, if any.
    public let matchedPitch: MIDINote?

    /// Confidence of the most recent match, 0...1.
    public let confidence: Double

    public static let idle = FollowState(
        currentIndex: 0,
        currentTimePosition: 0,
        progress: 0,
        matchedPitch: nil,
        confidence: 0
    )

    public init(
        currentIndex: Int,
        currentTimePosition: TimeInterval,
        progress: Double,
        matchedPitch: MIDINote?,
        confidence: Double
    ) {
        self.currentIndex = currentIndex
        self.currentTimePosition = currentTimePosition
        self.progress = progress
        self.matchedPitch = matchedPitch
        self.confidence = confidence
    }
}

// MARK: - ScoreFollowing

public protocol ScoreFollowing: Actor {
    /// Stream of position updates for the UI layer to consume.
    ///
    /// `nonisolated` so the view model can subscribe synchronously through the
    /// `any ScoreFollowing` existential (backed by an immutable `let`).
    nonisolated var stateStream: AsyncStream<FollowState> { get }

    /// Begin consuming `detector.pitchStream` and aligning against the score.
    func start() async

    /// Stop following and finish the stream.
    func stop() async
}

// MARK: - ScoreFollower

public actor ScoreFollower: ScoreFollowing {

    // MARK: Tuning

    /// Max semitone distance for a live note to count as matching the expected
    /// note. 0 = exact; 1 tolerates a half-step error.
    private static let matchToleranceSemitones = 1

    /// A match must persist for at least this long before we advance, providing
    /// hysteresis against transient mis-detections (placeholder for DTW's more
    /// principled path cost).
    private static let confirmDuration: TimeInterval = 0.04

    /// Silence floor passed through to `PitchEvent.isVoiced`.
    private static let amplitudeFloor: Double = 0.05

    // MARK: Dependencies

    private let score: ScoreProviding
    private let detector: any PitchDetecting

    // MARK: Stream plumbing

    public nonisolated let stateStream: AsyncStream<FollowState>
    private let continuation: AsyncStream<FollowState>.Continuation

    // MARK: Mutable following state

    private var currentIndex = 0
    private var consumeTask: Task<Void, Never>?

    /// Wall-clock at which the current note was matched, used to interpolate
    /// `currentTimePosition` continuously between discrete matches.
    private var lastMatchUptime: TimeInterval?
    private var lastMatchOnset: TimeInterval = 0

    /// Tracks a candidate match awaiting confirmation (hysteresis).
    private var pendingMatchSince: TimeInterval?

    public init(score: ScoreProviding, detector: any PitchDetecting) {
        self.score = score
        self.detector = detector
        var cont: AsyncStream<FollowState>.Continuation!
        self.stateStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            cont = $0
        }
        self.continuation = cont
    }

    // MARK: ScoreFollowing

    public func start() async {
        guard consumeTask == nil else { return }
        let stream = detector.pitchStream
        consumeTask = Task { [weak self] in
            for await event in stream {
                await self?.process(event)
            }
        }
        emit(matchedPitch: nil, confidence: 0)
    }

    public func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        continuation.finish()
    }

    // MARK: Matching (DTW placeholder)

    private func process(_ event: PitchEvent) {
        // Keep the continuous clock advancing even on unvoiced frames so the
        // SpriteKit view glides instead of freezing during rests/legato.
        defer { emitInterpolated() }

        guard event.isVoiced(amplitudeFloor: Self.amplitudeFloor),
              let live = event.nearestMIDINote,
              let expected = score.note(at: currentIndex) else {
            pendingMatchSince = nil
            return
        }

        // --- Linear distance + threshold (placeholder for DTW) -----------
        // A true follower would search a local window of the score with a
        // cumulative path cost. Here we only test the single expected note and
        // its immediate successor (to allow skipping a missed note).
        let costExpected = distance(live, expected.pitch)

        if costExpected <= Self.matchToleranceSemitones {
            confirmMatch(at: currentIndex, now: event.timestamp, cost: costExpected)
            return
        }

        // Allow jumping ahead one note if the player skipped/rushed.
        if let next = score.note(at: currentIndex + 1),
           distance(live, next.pitch) <= Self.matchToleranceSemitones {
            confirmMatch(at: currentIndex + 1, now: event.timestamp, cost: distance(live, next.pitch))
            return
        }

        // Wrong note — reset the pending confirmation timer.
        pendingMatchSince = nil
    }

    /// Semitone distance — the local cost function a future DTW would accumulate.
    private func distance(_ live: MIDINote, _ expected: MIDINote) -> Int {
        abs(Int(live.number) - Int(expected.number))
    }

    /// Advance to `index` once the candidate has persisted past `confirmDuration`.
    private func confirmMatch(at index: Int, now: TimeInterval, cost: Int) {
        if pendingMatchSince == nil { pendingMatchSince = now }
        guard let since = pendingMatchSince, now - since >= Self.confirmDuration else {
            return
        }
        pendingMatchSince = nil

        currentIndex = min(index, max(score.count - 1, 0))
        lastMatchUptime = now
        lastMatchOnset = score.note(at: currentIndex)?.onset ?? lastMatchOnset

        let confidence = 1.0 - Double(cost) / Double(Self.matchToleranceSemitones + 1)
        emit(matchedPitch: score.note(at: currentIndex)?.pitch, confidence: confidence)
    }

    // MARK: Emission

    /// Emit using the live interpolated time position (called every frame).
    private func emitInterpolated() {
        emit(matchedPitch: score.note(at: currentIndex)?.pitch, confidence: 0, interpolatedOnly: true)
    }

    private func emit(matchedPitch: MIDINote?, confidence: Double, interpolatedOnly: Bool = false) {
        let time = interpolatedTimePosition()
        let progress = score.duration > 0 ? min(time / score.duration, 1) : 0
        let state = FollowState(
            currentIndex: currentIndex,
            currentTimePosition: time,
            progress: progress,
            matchedPitch: matchedPitch,
            confidence: interpolatedOnly ? 0 : confidence
        )
        continuation.yield(state)
    }

    /// Continuous playback clock: the matched note's onset plus the wall-clock
    /// elapsed since the match, clamped so we never overshoot the next onset.
    private func interpolatedTimePosition() -> TimeInterval {
        guard let matchedAt = lastMatchUptime else { return lastMatchOnset }
        let elapsed = ProcessInfo.processInfo.systemUptime - matchedAt
        let nextOnset = score.note(at: currentIndex + 1)?.onset ?? (lastMatchOnset + 1)
        return min(lastMatchOnset + max(elapsed, 0), nextOnset)
    }
}
