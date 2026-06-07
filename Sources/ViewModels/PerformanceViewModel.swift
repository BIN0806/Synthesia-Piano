//
//  PerformanceViewModel.swift
//  SynthesiaPiano
//
//  ViewModel layer (the VM in MVVM-C).
//
//  This is the ONLY place Combine appears. Everything upstream uses actors and
//  AsyncStream; here we bridge the follower's `AsyncStream<FollowState>` to
//  `@Published` properties that SwiftUI observes on the main actor.
//

import Foundation
import Combine

@MainActor
public final class PerformanceViewModel: ObservableObject {

    // MARK: Published UI state

    /// DISCRETE position — bound by `VexFlowWebView` (sheet music jumps).
    @Published public private(set) var currentIndex: Int = 0

    /// CONTINUOUS position in seconds — bound by `SynthesiaSpriteView` so the
    /// falling notes scroll smoothly at 60 FPS.
    @Published public private(set) var currentTimePosition: TimeInterval = 0

    /// 0...1 progress through the piece.
    @Published public private(set) var progress: Double = 0

    /// Most recently matched pitch (for an optional HUD / debugging).
    @Published public private(set) var currentPitch: MIDINote?

    /// Whether the mic pipeline is active.
    @Published public private(set) var isListening: Bool = false

    /// The static score, exposed so views can lay out note sprites / staves.
    public let notes: [NoteEvent]

    // MARK: Dependencies

    private let detector: any PitchDetecting
    private let follower: any ScoreFollowing

    private var followTask: Task<Void, Never>?

    // MARK: Init

    public init(
        score: ScoreProviding,
        detector: any PitchDetecting,
        follower: any ScoreFollowing
    ) {
        self.notes = score.notes
        self.detector = detector
        self.follower = follower
    }

    // MARK: Lifecycle

    public func start() {
        guard !isListening else { return }
        isListening = true

        // Subscribe to follower state BEFORE starting audio so we don't miss
        // the first frames.
        let stream = follower.stateStream
        followTask = Task { [weak self] in
            for await state in stream {
                self?.apply(state)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.follower.start()
            do {
                try await self.detector.start()
            } catch {
                await MainActor.run { self.handleStartFailure(error) }
            }
        }
    }

    public func stop() {
        guard isListening else { return }
        isListening = false
        followTask?.cancel()
        followTask = nil
        Task { [detector, follower] in
            await detector.stop()
            await follower.stop()
        }
    }

    // MARK: Private

    /// Runs on the main actor (enclosing class is `@MainActor`).
    private func apply(_ state: FollowState) {
        currentIndex = state.currentIndex
        currentTimePosition = state.currentTimePosition
        progress = state.progress
        if let pitch = state.matchedPitch {
            currentPitch = pitch
        }
    }

    private func handleStartFailure(_ error: Error) {
        isListening = false
        // A production build would surface this to the UI; for the foundation we
        // just log it.
        print("[PerformanceViewModel] audio start failed: \(error)")
    }
}
