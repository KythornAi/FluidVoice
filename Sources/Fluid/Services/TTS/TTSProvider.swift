//
//  TTSProvider.swift
//  FluidChat (FluidVoice fork)
//
//  Read-aloud provider interface. All voice engines (AVSpeech, Piper, Kokoro,
//  cloud APIs) live behind this protocol so switching engines is a settings
//  dropdown, never a rebuild (roadmap §4).
//

import Foundation

/// Playback state shared by all TTS providers, surfaced to the playback pill UI.
enum TTSPlaybackState: Equatable {
    case idle
    /// Synthesis in progress — no audio yet. Lets the pill show honest
    /// "preparing" feedback instead of looking stuck (Kyle, 5 Aug 2026).
    case preparing
    case speaking
    case paused
}

/// One text-to-speech engine. Implementations must be usable from the main actor.
@MainActor
protocol TTSProvider: AnyObject {
    /// Stable machine identifier, e.g. "avspeech", "piper", "kokoro".
    var identifier: String { get }
    /// Human-readable name shown in settings, e.g. "System Voices (AVSpeech)".
    var displayName: String { get }

    /// Speech rate. Range is provider-defined; AVSpeech uses 0.0...1.0.
    var rate: Float { get set }

    /// Begin speaking `text`, replacing anything currently playing.
    func speak(text: String)
    func pause()
    func resume()
    func stop()

    /// Called by TTSService when playback state changes, for UI updates.
    var onStateChange: ((TTSPlaybackState) -> Void)? { get set }

    /// Called only when a passage finishes playing **naturally** — never on
    /// stop, cancel, supersede-by-newer-speak, or error. Drives queue
    /// auto-advance (Phase 5). Optional; providers that don't implement it
    /// simply never auto-advance.
    var onNaturalFinish: (() -> Void)? { get set }
}

extension TTSProvider {
    /// Default no-op so existing providers compile unchanged.
    var onNaturalFinish: (() -> Void)? {
        get { nil }
        set {}
    }
}
