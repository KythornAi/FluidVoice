//
//  AVSpeechTTSProvider.swift
//  FluidChat (FluidVoice fork)
//
//  Phase 1 engine: Apple's built-in AVSpeechSynthesizer. Free, offline,
//  zero downloads — the baseline every other engine is compared against.
//

import AVFoundation
import Foundation

@MainActor
final class AVSpeechTTSProvider: NSObject, TTSProvider {
    let identifier = "avspeech"
    let displayName = "System Voices (AVSpeech)"

    var onStateChange: ((TTSPlaybackState) -> Void)?

    /// AVSpeech rate range is 0.0...1.0; 0.5 is the system default.
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        self.synthesizer.delegate = self
    }

    func speak(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if self.synthesizer.isSpeaking || self.synthesizer.isPaused {
            self.synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = self.rate
        // Default voice follows the user's macOS speech settings; premium/Siri
        // voices selected there are picked up automatically.
        self.synthesizer.speak(utterance)
    }

    func pause() {
        guard self.synthesizer.isSpeaking else { return }
        self.synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        guard self.synthesizer.isPaused else { return }
        self.synthesizer.continueSpeaking()
    }

    func stop() {
        self.synthesizer.stopSpeaking(at: .immediate)
    }
}

extension AVSpeechTTSProvider: @preconcurrency AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onStateChange?(.speaking) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onStateChange?(.idle) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onStateChange?(.paused) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onStateChange?(.speaking) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onStateChange?(.idle) }
    }
}
