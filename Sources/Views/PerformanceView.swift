//
//  PerformanceView.swift
//  SynthesiaPiano
//
//  UI layer. The top-level SwiftUI screen that stacks the two synchronized
//  views and binds them to the PerformanceViewModel.
//
//  Binding contract (the whole point of the dual-position FollowState):
//    - VexFlowWebView      <- currentIndex          (discrete)
//    - SynthesiaSpriteView <- currentTimePosition   (continuous) + currentIndex
//

import SwiftUI

public struct PerformanceView: View {

    @StateObject private var viewModel: PerformanceViewModel

    /// Inject a fully-wired view model (see `PerformanceCoordinator`).
    public init(viewModel: PerformanceViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top: standard sheet music with the smoothing tracker line.
            VexFlowWebView(currentIndex: viewModel.currentIndex)
                .frame(height: 180)
                .background(Color(.systemBackground))

            Divider()

            // Bottom: Synthesia-style falling notes at 60 FPS.
            SynthesiaSpriteView(
                notes: viewModel.notes,
                currentTimePosition: viewModel.currentTimePosition,
                currentIndex: viewModel.currentIndex
            )
            .background(Color.black.opacity(0.9))

            controlBar
        }
        .onDisappear { viewModel.stop() }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button {
                viewModel.isListening ? viewModel.stop() : viewModel.start()
            } label: {
                Label(
                    viewModel.isListening ? "Stop" : "Listen",
                    systemImage: viewModel.isListening ? "stop.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if let pitch = viewModel.currentPitch {
                Text(pitch.name)
                    .font(.system(.title3, design: .monospaced))
                    .frame(width: 64)
            }
        }
        .padding()
    }
}
