//
//  ScoreManager.swift
//  SynthesiaPiano
//
//  Model layer. Holds the parsed reference score as an array of NoteEvents.
//  The MIDI / MusicXML parsing itself is intentionally abstracted away behind
//  the `ScoreProviding` protocol so the rest of the app never depends on a
//  concrete file format.
//

import Foundation

// MARK: - ScoreProviding

/// Read-only access to the reference score.
///
/// Decouples the alignment engine and view model from how notes were parsed
/// (MIDI, MusicXML, hand-authored fixtures, ...). `Sendable` so a provider can
/// be shared across actors safely.
public protocol ScoreProviding: Sendable {

    /// All notes, sorted ascending by `onset`.
    var notes: [NoteEvent] { get }

    /// Total length of the piece in seconds (offset of the last note).
    var duration: TimeInterval { get }

    /// Bounds-checked note lookup.
    func note(at index: Int) -> NoteEvent?

    /// Notes whose sounding window intersects `range` (useful for the
    /// SpriteKit view's visible window culling).
    func notes(in range: Range<TimeInterval>) -> [NoteEvent]
}

public extension ScoreProviding {
    var count: Int { notes.count }

    func note(at index: Int) -> NoteEvent? {
        guard notes.indices.contains(index) else { return nil }
        return notes[index]
    }

    func notes(in range: Range<TimeInterval>) -> [NoteEvent] {
        notes.filter { $0.onset < range.upperBound && $0.offset > range.lowerBound }
    }
}

// MARK: - ScoreManager

/// Concrete, immutable score holder.
///
/// Construct it from an already-parsed `[NoteEvent]`. A real build would feed
/// this from a MIDI/MusicXML importer; `ScoreManager.demo()` provides a fixture
/// so the full pipeline can run before any parser exists.
public struct ScoreManager: ScoreProviding {

    public let notes: [NoteEvent]
    public let duration: TimeInterval

    public init(notes: [NoteEvent]) {
        // Guarantee the onset-sorted invariant the alignment engine relies on.
        let sorted = notes.sorted { $0.onset < $1.onset }
        self.notes = sorted
        self.duration = sorted.last?.offset ?? 0
    }
}

// MARK: - Demo Fixture

public extension ScoreManager {

    /// A simple monophonic melody (C major scale up and back) so the
    /// audio -> follower -> UI pipeline is exercisable without a parser.
    static func demo() -> ScoreManager {
        let scale: [UInt8] = [60, 62, 64, 65, 67, 69, 71, 72, 71, 69, 67, 65, 64, 62, 60]
        let beat: TimeInterval = 0.5
        let events = scale.enumerated().map { index, midi in
            NoteEvent(
                pitch: MIDINote(number: midi),
                onset: TimeInterval(index) * beat,
                duration: beat * 0.9,
                velocity: 90
            )
        }
        return ScoreManager(notes: events)
    }
}
