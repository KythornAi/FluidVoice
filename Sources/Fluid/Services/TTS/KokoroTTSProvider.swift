//
//  KokoroTTSProvider.swift
//  FluidChat (FluidVoice fork)
//
//  Phase 2 engine: Kokoro-82M via the vendored kokoro-swift package
//  (MLX GPU inference, built-in Misaki G2P — fully native, no Python).
//  Model and voices download on demand; synthesis runs off the main
//  actor and plays through AVAudioPlayer like the Piper provider.
//

import AVFoundation
import Foundation
import Kokoro

@MainActor
final class KokoroTTSProvider: NSObject, TTSProvider {
    let identifier = "kokoro"
    let displayName = "Kokoro-82M (local neural)"

    var onStateChange: ((TTSPlaybackState) -> Void)?

    /// Speed multiplier, passed straight through to Kokoro's `speed`.
    var rate: Float = 1.0

    /// Selected Kokoro voice (e.g. "bf_emma"). Persisted; downloads on demand.
    var selectedVoiceID: String {
        didSet { UserDefaults.standard.set(self.selectedVoiceID, forKey: Self.voiceDefaultsKey) }
    }

    static let defaultVoiceID = "bf_emma"
    private static let voiceDefaultsKey = "tts.kokoroVoiceID"

    private var player: AVAudioPlayer?
    private var synthesisTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    /// Lazily built pipeline; guarded by `pipelineLock` because synthesis runs
    /// on background threads. Rebuilt when the voice's language changes.
    private let synthesizer = KokoroSynthesizer()

    override init() {
        let saved = UserDefaults.standard.string(forKey: Self.voiceDefaultsKey)
        self.selectedVoiceID = saved ?? Self.defaultVoiceID
        super.init()
    }

    // MARK: - TTSProvider

    func speak(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.stopInternal(notify: false)
        self.generation &+= 1
        let generation = self.generation
        let voiceID = self.selectedVoiceID
        let speed = self.rate

        self.onStateChange?(.speaking)

        self.synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await KokoroEnvironment.shared.ensureReady()
                try await KokoroEnvironment.shared.ensureVoice(voiceID)
                let wavURL = try await self.synthesize(trimmed, voiceID: voiceID, speed: speed)
                guard !Task.isCancelled, self.generation == generation else {
                    try? FileManager.default.removeItem(at: wavURL)
                    return
                }
                try self.play(wavURL)
            } catch is CancellationError {
                // Superseded by a newer speak/stop.
            } catch {
                guard self.generation == generation else { return }
                DebugLogger.shared.error("Kokoro speak failed: \(error.localizedDescription)", source: "KokoroTTSProvider")
                self.onStateChange?(.idle)
            }
        }
    }

    func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
        self.onStateChange?(.paused)
    }

    func resume() {
        guard let player, !player.isPlaying else { return }
        player.play()
        self.onStateChange?(.speaking)
    }

    func stop() {
        self.stopInternal(notify: true)
    }

    // MARK: - Internals

    private func stopInternal(notify: Bool) {
        self.generation &+= 1
        self.synthesisTask?.cancel()
        self.synthesisTask = nil
        self.player?.stop()
        self.player = nil
        if notify { self.onStateChange?(.idle) }
    }

    private func play(_ wavURL: URL) throws {
        let player = try AVAudioPlayer(contentsOf: wavURL)
        player.delegate = self
        self.player = player
        player.play()
    }

    /// Kokoro voices are named {lang}{gender}_{name}; British voices ("b")
    /// need the en-gb G2P, everything else defaults to en-us.
    fileprivate static func langCode(for voiceID: String) -> String {
        voiceID.hasPrefix("b") ? "en-gb" : "en-us"
    }

    private func synthesize(_ text: String, voiceID: String, speed: Float) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidchat-kokoro-\(UUID().uuidString).wav")
        let synthesizer = self.synthesizer

        return try await Task.detached(priority: .userInitiated) {
            try synthesizer.synthesize(
                text: text,
                voiceID: voiceID,
                speed: speed,
                outputURL: outputURL
            )
        }.value
    }
}

/// Owns the Kokoro pipeline off-actor: model load and MLX inference are
/// blocking work that must never run on the main thread. Serialized with a
/// lock because KPipeline is not Sendable.
private final class KokoroSynthesizer: @unchecked Sendable {
    private var pipeline: KPipeline?
    private var pipelineLangCode: String?
    private let lock = NSLock()

    func synthesize(text: String, voiceID: String, speed: Float, outputURL: URL) throws -> URL {
        self.lock.lock()
        defer { self.lock.unlock() }

        let langCode = KokoroTTSProvider.langCode(for: voiceID)
        if self.pipeline == nil || self.pipelineLangCode != langCode {
            let model = try KModel(
                configURL: KokoroEnvironment.configURL,
                weightsURL: KokoroEnvironment.weightsURL
            )
            let voices = VoiceLoader(
                baseDirectory: KokoroEnvironment.voicesDirectory,
                enableDownload: false
            )
            self.pipeline = KPipeline(model: model, voices: voices, langCode: langCode)
            self.pipelineLangCode = langCode
        }

        guard let pipeline = self.pipeline else {
            throw PiperEnvironmentError.setupFailed("Kokoro pipeline unavailable")
        }
        return try pipeline.synthesizeToWAV(text: text, voice: voiceID, speed: speed, outputURL: outputURL)
    }
}

extension KokoroTTSProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.player = nil
            self.onStateChange?(.idle)
        }
    }
}
