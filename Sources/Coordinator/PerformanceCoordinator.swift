//
//  PerformanceCoordinator.swift
//  SynthesiaPiano
//
//  The "C" in MVVM-C. Owns object construction and dependency injection so the
//  views and view model never new-up their own collaborators. This is the single
//  place that knows the concrete types (ScoreManager, AudioTrackerEngine,
//  ScoreFollower) — everything else talks to protocols.
//
//  ============================================================================
//  PROJECT REQUIREMENTS (sources-only delivery — wire these up in Xcode):
//    - Swift 5+, iOS 17+
//    - SPM packages: AudioKit, AudioKitEX, SoundpipeAudioKit
//        https://github.com/AudioKit/AudioKit
//    - Info.plist: NSMicrophoneUsageDescription
//    - Add Sources/Resources/vexflow.html to the app target's "Copy Bundle
//      Resources" build phase so VexFlowWebView can load it.
//  ============================================================================
//

import SwiftUI

@MainActor
public final class PerformanceCoordinator {

    private let score: ScoreProviding
    private let detector: any PitchDetecting
    private let follower: any ScoreFollowing
    private let viewModel: PerformanceViewModel

    /// Designated init with full dependency injection (great for tests: pass a
    /// mock `PitchDetecting` / `ScoreFollowing`).
    public init(
        score: ScoreProviding,
        detector: any PitchDetecting,
        follower: any ScoreFollowing
    ) {
        self.score = score
        self.detector = detector
        self.follower = follower
        self.viewModel = PerformanceViewModel(
            score: score,
            detector: detector,
            follower: follower
        )
    }

    /// Convenience factory wiring the production stack from a score.
    public convenience init(score: ScoreProviding) {
        let detector = AudioTrackerEngine()
        let follower = ScoreFollower(score: score, detector: detector)
        self.init(score: score, detector: detector, follower: follower)
    }

    /// Convenience factory using the bundled demo melody.
    public static func demo() -> PerformanceCoordinator {
        PerformanceCoordinator(score: ScoreManager.demo())
    }

    /// Builds the root view for this flow.
    public func makeRootView() -> some View {
        PerformanceView(viewModel: viewModel)
    }
}
