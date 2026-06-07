//
//  SynthesiaSpriteView.swift
//  SynthesiaPiano
//
//  UI layer. Wraps an SKView running a 60 FPS "falling notes" (Synthesia-style)
//  scene.
//
//  Smoothness contract:
//    The scene scrolls based on CONTINUOUS time (`currentTimePosition`), NOT the
//    discrete `currentIndex`. Driving the scroll off an integer index would make
//    the notes snap/stall; driving off continuous time gives buttery 60 FPS
//    motion. The discrete `currentIndex` is used ONLY to highlight the note
//    that is currently active.
//

import SwiftUI
import SpriteKit

// MARK: - SwiftUI wrapper

public struct SynthesiaSpriteView: UIViewRepresentable {

    public let notes: [NoteEvent]

    /// CONTINUOUS playback position (seconds). Drives the scroll.
    public let currentTimePosition: TimeInterval

    /// DISCRETE active-note index. Drives the highlight only.
    public let currentIndex: Int

    public init(notes: [NoteEvent], currentTimePosition: TimeInterval, currentIndex: Int) {
        self.notes = notes
        self.currentTimePosition = currentTimePosition
        self.currentIndex = currentIndex
    }

    public func makeUIView(context: Context) -> SKView {
        let view = SKView(frame: .zero)
        view.backgroundColor = .clear
        view.preferredFramesPerSecond = 60
        view.ignoresSiblingOrder = true

        let scene = FallingNotesScene(notes: notes)
        scene.scaleMode = .resizeFill
        view.presentScene(scene)

        context.coordinator.scene = scene
        return view
    }

    public func updateUIView(_ view: SKView, context: Context) {
        if view.bounds.size != context.coordinator.scene?.size {
            context.coordinator.scene?.size = view.bounds.size
        }
        // Feed the scene the latest position; it tweens between updates itself.
        context.coordinator.scene?.update(
            timePosition: currentTimePosition,
            activeIndex: currentIndex
        )
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var scene: FallingNotesScene?
    }
}

// MARK: - Scene

/// Renders notes as bars falling toward a hit line. Position is a pure function
/// of `currentTimePosition`, so its own `update(_:)` loop can interpolate
/// smoothly at 60 FPS between the (less frequent) ViewModel updates.
public final class FallingNotesScene: SKScene {

    // MARK: Layout constants

    /// Seconds of lookahead visible above the hit line.
    private let visibleWindow: TimeInterval = 3.0

    /// Vertical position of the "now" hit line, as a fraction from the bottom.
    private let hitLineFraction: CGFloat = 0.15

    private let notes: [NoteEvent]
    private var noteNodes: [UUID: SKSpriteNode] = [:]
    private var hitLine: SKShapeNode?

    // Latest values pushed from SwiftUI; the render loop reads these.
    private var targetTime: TimeInterval = 0
    private var renderTime: TimeInterval = 0
    private var activeIndex: Int = -1

    private let pitchRange: ClosedRange<UInt8>

    public init(notes: [NoteEvent]) {
        self.notes = notes
        let pitches = notes.map(\.pitch.number)
        self.pitchRange = (pitches.min() ?? 48)...(pitches.max() ?? 84)
        super.init(size: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: External input

    /// Called from `updateUIView`. We store the target; the render loop eases
    /// `renderTime` toward it so playback stays smooth even if updates are bursty.
    func update(timePosition: TimeInterval, activeIndex: Int) {
        self.targetTime = timePosition
        self.activeIndex = activeIndex
    }

    // MARK: Scene lifecycle

    public override func didMove(to view: SKView) {
        backgroundColor = .clear
        buildHitLine()
        buildNotes()
    }

    private func buildHitLine() {
        let line = SKShapeNode(rectOf: CGSize(width: size.width, height: 2))
        line.fillColor = .systemBlue
        line.strokeColor = .clear
        line.position = CGPoint(x: size.width / 2, y: size.height * hitLineFraction)
        addChild(line)
        hitLine = line
    }

    private func buildNotes() {
        for note in notes {
            let node = SKSpriteNode(color: .systemTeal, size: noteSize(for: note))
            node.anchorPoint = CGPoint(x: 0.5, y: 0)
            node.position = CGPoint(x: xPosition(for: note.pitch), y: size.height + 50)
            addChild(node)
            noteNodes[note.id] = node
        }
    }

    // MARK: 60 FPS render loop

    public override func update(_ currentTime: TimeInterval) {
        // Smoothly approach the target time so the motion is continuous even
        // when ViewModel updates arrive in bursts. (Critical-damped-ish lerp.)
        let lerp = 0.35
        renderTime += (targetTime - renderTime) * lerp

        let hitY = size.height * hitLineFraction
        let pxPerSecond = (size.height - hitY) / CGFloat(visibleWindow)

        for (idx, note) in notes.enumerated() {
            guard let node = noteNodes[note.id] else { continue }
            // Time until this note should reach the hit line.
            let dt = note.onset - renderTime
            node.position = CGPoint(
                x: node.position.x,
                y: hitY + CGFloat(dt) * pxPerSecond
            )
            // Discrete highlight: the active note glows; others are calm.
            let isActive = idx == activeIndex
            node.color = isActive ? .systemYellow : .systemTeal
            node.alpha = (dt < -note.duration || dt > visibleWindow) ? 0.0 : 1.0
        }
    }

    // MARK: Geometry helpers

    private func noteSize(for note: NoteEvent) -> CGSize {
        let hitY = size.height * hitLineFraction
        let pxPerSecond = (size.height - hitY) / CGFloat(visibleWindow)
        let laneWidth = max(size.width / CGFloat(pitchSpan), 8)
        return CGSize(width: laneWidth * 0.8, height: CGFloat(note.duration) * pxPerSecond)
    }

    private var pitchSpan: Int {
        Int(pitchRange.upperBound - pitchRange.lowerBound) + 1
    }

    /// Map a pitch to a horizontal lane (low notes left, high notes right).
    private func xPosition(for pitch: MIDINote) -> CGFloat {
        let span = CGFloat(pitchSpan)
        let offset = CGFloat(pitch.number - pitchRange.lowerBound)
        return (offset + 0.5) / span * size.width
    }
}
