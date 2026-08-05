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
    private static let readBackDefaultsKey = "tts.readBackAfterDictation"
    private static let defaultProviderID = "avspeech"

    /// Phase 5: when enabled, the final transcript is spoken aloud after each
    /// dictation (proofreading aid). Uses the active engine/voice/speed.
    /// Default off; toggle lives in the Read Aloud settings card.
    @Published var readBackAfterDictationEnabled: Bool {
        didSet { UserDefaults.standard.set(self.readBackAfterDictationEnabled, forKey: Self.readBackDefaultsKey) }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.activeProviderDefaultsKey)
        self.activeProviderID = saved ?? Self.defaultProviderID
        let savedSpeed = UserDefaults.standard.object(forKey: Self.speedDefaultsKey) as? Float
        self.playbackSpeed = savedSpeed ?? 1.0
        self.readBackAfterDictationEnabled = UserDefaults.standard.bool(forKey: Self.readBackDefaultsKey)
        self.register(AVSpeechTTSProvider())
        self.register(PiperTTSProvider())
        self.register(KokoroTTSProvider())
        self.register(FishTTSProvider())
        self.register(OpenAITTSProvider())
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
        provider.onNaturalFinish = { [weak self] in
            guard let self, provider.identifier == self.activeProviderID else { return }
            self.handleNaturalFinish()
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
        // Takeover semantics (⌃R, dictation read-back): a fresh explicit speak
        // always wins and clears any pending queue.
        self.clearQueue()
        self.hasSession = true
        self.currentText = text
        self.activeProvider?.speak(text: text)
    }

    /// Pill play button: resume if paused, continue a pending queue, read the
    /// current selection if any is highlighted, otherwise replay last passage.
    func playFromPill() {
        if self.playbackState == .paused {
            self.resume()
            return
        }
        if self.playbackState == .idle, !self.queue.isEmpty {
            self.playNextQueued()
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
        self.clearQueue()
        self.hasSession = false
        self.currentText = nil
    }

    // MARK: - Queue (Phase 5: ebook listening sessions)

    /// Upcoming passages, in order. The passage currently playing lives in
    /// `currentText`, not in here.
    @Published private(set) var queue: [String] = []

    /// Passages completed or skipped this queue session (drives the pill's
    /// "2 of 4" label).
    @Published private(set) var queueCompletedCount = 0

    /// Pill label for an active queue session, e.g. "2 of 4".
    var queuePositionLabel: String {
        let current = self.queueCompletedCount + 1
        let total = current + self.queue.count
        return "\(current) of \(total)"
    }

    /// ⌃⇧R entry point: capture the highlighted text and add it to the queue.
    /// Starts playback immediately when nothing is playing.
    @discardableResult
    func enqueueSelection() -> Bool {
        var text = TextSelectionService.shared.getSelectedText()
        if text == nil || text!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = SelectionCopyCapture.capture()
        }
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            DebugLogger.shared.info("Queue: no selected text captured", source: "TTSService")
            return false
        }
        self.queue.append(text)
        self.hasSession = true
        DebugLogger.shared.info("Queue: passage added (\(self.queue.count) pending)", source: "TTSService")
        if self.playbackState == .idle {
            self.playNextQueued()
        }
        return true
    }

    /// Pill skip button: drop the current passage and start the next queued
    /// one; with nothing pending, behaves like stop.
    func skipToNext() {
        guard !self.queue.isEmpty else {
            self.stop()
            return
        }
        self.queueCompletedCount += 1
        self.playNextQueued()
    }

    private func playNextQueued() {
        guard !self.queue.isEmpty else { return }
        let next = self.queue.removeFirst()
        self.currentText = next
        self.activeProvider?.speak(text: next)
    }

    /// Active provider finished a passage naturally (never on stop/cancel/
    /// supersede). Advances the queue when passages are pending.
    private func handleNaturalFinish() {
        guard !self.queue.isEmpty else { return }
        self.queueCompletedCount += 1
        self.playNextQueued()
    }

    private func clearQueue() {
        self.queue.removeAll()
        self.queueCompletedCount = 0
    }

    func pause() { self.activeProvider?.pause() }
    func resume() { self.activeProvider?.resume() }
    func stop() { self.activeProvider?.stop() }

    /// Stops playback when a new dictation recording starts, so read-aloud
    /// audio can't bleed into the mic and contaminate the next transcript.
    /// Parks the pill (per stop semantics) rather than dismissing the session.
    func stopForRecordingStart() {
        guard self.playbackState != .idle else { return }
        DebugLogger.shared.info("Read-aloud: stopping playback for recording start", source: "TTSService")
        self.stop()
    }

    /// Toggles pause/resume; stops are deliberate via `stop()`.
    func togglePause() {
        switch self.playbackState {
        case .speaking: self.pause()
        case .paused: self.resume()
        case .idle: break
        }
    }
}
