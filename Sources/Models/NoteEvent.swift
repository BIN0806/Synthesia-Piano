//
//  NoteEvent.swift
//  SynthesiaPiano
//
//  Core value types shared across every layer (Model, Audio, Alignment, UI).
//  Everything here is `Sendable` so it can cross actor / AsyncStream boundaries
//  without data races.
//

import Foundation

// MARK: - MIDINote

/// A single chromatic pitch identified by its MIDI note number (0...127).
///
/// Wrapping the raw `UInt8` lets us attach music-domain helpers (frequency,
/// note name, nearest-note matching) without scattering magic numbers through
/// the DSP and alignment code.
public struct MIDINote: Hashable, Sendable, Comparable {

    /// Standard MIDI note number. 69 == A4 == 440 Hz.
    public let number: UInt8

    public init(number: UInt8) {
        self.number = number
    }

    public init(number: Int) {
        self.number = UInt8(clamping: number)
    }

    /// Equal-temperament frequency in Hz (A4 = 440 Hz reference).
    public var frequency: Double {
        440.0 * pow(2.0, (Double(number) - 69.0) / 12.0)
    }

    /// Octave in scientific pitch notation (C4 == middle C).
    public var octave: Int {
        Int(number) / 12 - 1
    }

    /// Human-readable name, e.g. "A4", "C#5".
    public var name: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[Int(number) % 12])\(octave)"
    }

    /// Nearest chromatic note to an arbitrary frequency.
    ///
    /// Returns `nil` for non-positive frequencies (silence / unvoiced frames).
    /// This is the bridge from the continuous DSP world to the discrete score.
    public init?(frequency: Double) {
        guard frequency > 0 else { return nil }
        let raw = 69.0 + 12.0 * log2(frequency / 440.0)
        let rounded = Int(raw.rounded())
        guard (0...127).contains(rounded) else { return nil }
        self.number = UInt8(rounded)
    }

    public static func < (lhs: MIDINote, rhs: MIDINote) -> Bool {
        lhs.number < rhs.number
    }
}

// MARK: - NoteEvent

/// One note in the reference score (parsed from MIDI / MusicXML).
///
/// The actual file parsing is abstracted away for now (see `ScoreManager`);
/// downstream layers only ever see arrays of these.
public struct NoteEvent: Identifiable, Hashable, Sendable {

    public let id: UUID
    public let pitch: MIDINote

    /// Seconds from the start of the piece at which the note begins.
    public let onset: TimeInterval

    /// Sounding length in seconds.
    public let duration: TimeInterval

    /// MIDI velocity (0...127). Drives note "weight"/brightness in the UI.
    public let velocity: UInt8

    public init(
        id: UUID = UUID(),
        pitch: MIDINote,
        onset: TimeInterval,
        duration: TimeInterval,
        velocity: UInt8 = 80
    ) {
        self.id = id
        self.pitch = pitch
        self.onset = onset
        self.duration = duration
        self.velocity = velocity
    }

    /// Seconds from start at which the note releases.
    public var offset: TimeInterval { onset + duration }
}

// MARK: - DetectionCapability

/// Declares what a pitch detector can actually resolve.
///
/// The MVP ships `.monophonic` because AudioKit's `PitchTap` (YIN/MPM) tracks a
/// single fundamental. This enum is the seam that lets a future FFT peak-picker
/// or CoreML audio classifier advertise `.polyphonic` without changing callers.
public enum DetectionCapability: Sendable, Equatable {
    case monophonic
    case polyphonic(maxVoices: Int)
}

// MARK: - PitchEvent

/// A single live sample emitted by the audio engine.
///
/// IMPORTANT (polyphony-readiness): pitch is stored as an *array* of
/// fundamentals even though the monophonic MVP only ever fills one slot.
/// When detection is upgraded to polyphonic FFT/CoreML, the detector simply
/// populates more entries — `PitchEvent`, the AsyncStream, the follower and the
/// views all stay the same.
public struct PitchEvent: Sendable {

    /// Detected fundamental frequencies in Hz. Monophonic detectors emit
    /// exactly one element (or zero when unvoiced).
    public let frequencies: [Double]

    /// Normalized input loudness (0...1), used for silence gating and UI.
    public let amplitude: Double

    /// Capture time (seconds, monotonic) for latency/interpolation math.
    public let timestamp: TimeInterval

    public init(frequencies: [Double], amplitude: Double, timestamp: TimeInterval) {
        self.frequencies = frequencies
        self.amplitude = amplitude
        self.timestamp = timestamp
    }

    /// Convenience for monophonic consumers: the loudest / first fundamental.
    public var primaryFrequency: Double? {
        frequencies.first { $0 > 0 }
    }

    /// Nearest chromatic note to `primaryFrequency`, if voiced.
    public var nearestMIDINote: MIDINote? {
        guard let f = primaryFrequency else { return nil }
        return MIDINote(frequency: f)
    }

    /// Whether this frame carries usable pitch (above the silence floor).
    public func isVoiced(amplitudeFloor: Double) -> Bool {
        amplitude >= amplitudeFloor && primaryFrequency != nil
    }
}
