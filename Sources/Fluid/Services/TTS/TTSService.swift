//
//  TTSService.swift
//  FluidChat (FluidVoice fork)
//
//  Orchestrates read-aloud: owns the active TTS provider, tracks playback
//  state for the UI, and provides the "read current selection" entry point
//  used by the hotkey and menu bar action.
//

import Combine
import Foundation

@MainActor
final class TTSService: ObservableObject {
    static let shared = TTSService()

    /// Current playback state, mirrored from the active provider (drives the pill UI).
    @Published private(set) var playbackState: TTSPlaybackState = .idle

    /// The text currently being read (kept for the pill's title/display later).
    @Published private(set) var currentText: String?

    /// Registered providers keyed by identifier. Phase 1 ships AVSpeech only;
    /// Piper/Kokoro/cloud engines register here in later phases.
    private var providers: [String: any TTSProvider] = [:]

    /// Active provider identifier. Persisted so the choice survives relaunches.
    @Published var activeProviderID: String {
        didSet { UserDefaults.standard.set(self.activeProviderID, forKey: Self.activeProviderDefaultsKey) }
    }

    /// User-facing playback speed multiplier (1.0 = normal). Persisted and
    /// mapped onto each provider's native rate scale (see `providerRate`).
    @Published var playbackSpeed: Float {
        didSet {
            UserDefaults.standard.set(self.playbackSpeed, forKey: Self.speedDefaultsKey)
            self.applySpeedToProviders()
        }
    }

    private static let activeProviderDefaultsKey = "tts.activeProviderID"
    private static let speedDefaultsKey = "tts.playbackSpeed"
    private static let defaultProviderID = "avspeech"

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.activeProviderDefaultsKey)
        self.activeProviderID = saved ?? Self.defaultProviderID
        let savedSpeed = UserDefaults.standard.object(forKey: Self.speedDefaultsKey) as? Float
        self.playbackSpeed = savedSpeed ?? 1.0
        self.register(AVSpeechTTSProvider())
        self.register(PiperTTSProvider())
        self.register(KokoroTTSProvider())
        PlaybackPillController.shared.start(observing: self)
    }

    // MARK: - Speed

    private func applySpeedToProviders() {
        for provider in self.providers.values {
            provider.rate = Self.providerRate(forSpeed: self.playbackSpeed, providerID: provider.identifier)
        }
    }

    /// Maps the user-facing speed multiplier onto each engine's native scale.
    static func providerRate(forSpeed speed: Float, providerID: String) -> Float {
        switch providerID {
        case "avspeech":
            // AVSpeech rate range is 0.0...1.0 with 0.5 = normal.
            return max(0.1, min(1.0, 0.5 * speed))
        default:
            // Piper (length-scale inverse) and Kokoro take plain multipliers;
            // those providers translate internally.
            return speed
        }
    }

    // MARK: - Provider registry

    func register(_ provider: any TTSProvider) {
        provider.onStateChange = { [weak self] state in
            guard let self, provider.identifier == self.activeProviderID else { return }
            self.playbackState = state
            // Note: currentText intentionally survives .idle so a parked
            // pill can replay the last passage.
        }
        provider.rate = Self.providerRate(forSpeed: self.playbackSpeed, providerID: provider.identifier)
        self.providers[provider.identifier] = provider
    }

    var activeProvider: (any TTSProvider)? {
        self.providers[self.activeProviderID]
    }

    var availableProviders: [(identifier: String, displayName: String)] {
        self.providers.values
            .map { ($0.identifier, $0.displayName) }
            .sorted { $0.1 < $1.1 }
    }

    // MARK: - Playback controls

    /// Whether a listening session exists. True from the first speak until the
    /// user explicitly closes the pill — stopping playback parks the pill
    /// rather than dismissing it (Kyle's UX call, 4 Aug 2026).
    @Published private(set) var hasSession = false

    /// Hotkey/menu entry point: grab the highlighted text in the frontmost app
    /// and read it aloud. Returns false when nothing could be captured.
    @discardableResult
    func readSelection() -> Bool {
        var text = TextSelectionService.shared.getSelectedText()
        if text == nil || text!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Accessibility couldn't read it (web views, some ebook readers) —
            // fall back to the clipboard-sentinel copy pattern.
            text = SelectionCopyCapture.capture()
        }
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            DebugLogger.shared.info("Read-aloud: no selected text captured", source: "TTSService")
            return false
        }
        self.speak(text: text)
        return true
    }

    func speak(text: String) {
        self.hasSession = true
        self.currentText = text
        self.activeProvider?.speak(text: text)
    }

    /// Pill play button: resume if paused, read the current selection if any
    /// is highlighted, otherwise replay the last passage.
    func playFromPill() {
        if self.playbackState == .paused {
            self.resume()
            return
        }
        if self.readSelection() { return }
        if let text = self.currentText {
            self.speak(text: text)
        }
    }

    /// Pill close button: stop playback and dismiss the parked pill.
    func dismissSession() {
        self.stop()
        self.hasSession = false
        self.currentText = nil
    }

    func pause() { self.activeProvider?.pause() }
    func resume() { self.activeProvider?.resume() }
    func stop() { self.activeProvider?.stop() }

    /// Toggles pause/resume; stops are deliberate via `stop()`.
    func togglePause() {
        switch self.playbackState {
        case .speaking: self.pause()
        case .paused: self.resume()
        case .idle: break
        }
    }
}
