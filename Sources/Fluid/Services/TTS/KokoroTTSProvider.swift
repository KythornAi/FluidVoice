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
    /// Fired only from audioPlayerDidFinishPlaying — drives queue advance.
    var onNaturalFinish: (() -> Void)?

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

    // Chunked playback state (5 Aug 2026 latency rework): long passages are
    // split into sentences; each chunk starts playing the moment it's
    // synthesized while the next synthesizes in the background, so
    // time-to-first-audio is one sentence instead of the whole passage.
    private var readyChunks: [URL] = []
    private var synthesisFinished = false
    private var pauseRequested = false

    /// Lazily built pipeline; guarded by `pipelineLock` because synthesis runs
    /// on background threads. Rebuilt when the voice's language changes.
    private let synthesizer = KokoroSynthesizer()

    override init() {
        let saved = UserDefaults.standard.string(forKey: Self.voiceDefaultsKey)
        self.selectedVoiceID = saved ?? Self.defaultVoiceID
        super.init()
    }

    // MARK: - TTSProvider

    /// Builds the model pipeline in the background so the first real speak
    /// doesn't pay the multi-second model-load cost. Called at app launch
    /// when Kokoro is the active engine, and when it becomes active.
    func prewarm() {
        let voiceID = self.selectedVoiceID
        let synthesizer = self.synthesizer
        Task {
            do {
                try await KokoroEnvironment.shared.ensureReady()
                try await KokoroEnvironment.shared.ensureVoice(voiceID)
                // Model load is blocking MLX work — off the main actor.
                try await Task.detached(priority: .utility) {
                    try synthesizer.prewarm(voiceID: voiceID)
                }.value
                DebugLogger.shared.info("Kokoro pipeline prewarmed", source: "KokoroTTSProvider")
            } catch {
                DebugLogger.shared.error("Kokoro prewarm failed: \(error.localizedDescription)", source: "KokoroTTSProvider")
            }
        }
    }

    func speak(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.stopInternal(notify: false)
        self.generation &+= 1
        let generation = self.generation
        let voiceID = self.selectedVoiceID
        let speed = self.rate
        let chunks = Self.splitIntoChunks(trimmed)

        self.onStateChange?(.preparing)

        self.synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await KokoroEnvironment.shared.ensureReady()
                try await KokoroEnvironment.shared.ensureVoice(voiceID)
                for chunk in chunks {
                    try Task.checkCancellation()
                    let wavURL = try await self.synthesize(chunk, voiceID: voiceID, speed: speed)
                    guard !Task.isCancelled, self.generation == generation else {
                        try? FileManager.default.removeItem(at: wavURL)
                        return
                    }
                    self.readyChunks.append(wavURL)
                    self.pumpPlayback(generation: generation)
                }
                self.synthesisFinished = true
            } catch is CancellationError {
                // Superseded by a newer speak/stop.
            } catch {
                guard self.generation == generation else { return }
                DebugLogger.shared.error("Kokoro speak failed: \(error.localizedDescription)", source: "KokoroTTSProvider")
                self.clearReadyChunks()
                self.onStateChange?(.idle)
            }
        }
    }

    func pause() {
        if let player, player.isPlaying {
            player.pause()
        } else {
            // Between chunks (next sentence still synthesizing): hold the
            // pause and apply it when the next player would start.
            self.pauseRequested = true
        }
        self.onStateChange?(.paused)
    }

    func resume() {
        self.pauseRequested = false
        if let player, !player.isPlaying {
            player.play()
            self.onStateChange?(.speaking)
            return
        }
        // Paused in a between-chunk gap: start the next ready chunk if any.
        self.pumpPlayback(generation: self.generation)
        if self.player != nil {
            self.onStateChange?(.speaking)
        }
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
        self.clearReadyChunks()
        self.synthesisFinished = false
        self.pauseRequested = false
        if notify { self.onStateChange?(.idle) }
    }

    private func clearReadyChunks() {
        for url in self.readyChunks {
            try? FileManager.default.removeItem(at: url)
        }
        self.readyChunks.removeAll()
    }

    /// Starts the next synthesized chunk when nothing is playing. Called
    /// after each synthesis completes and after each chunk finishes playing,
    /// so playback chains without waiting for the full passage.
    private func pumpPlayback(generation: UInt64) {
        guard self.generation == generation else { return }
        guard self.player == nil else { return }
        guard !self.readyChunks.isEmpty else { return }
        if self.pauseRequested {
            self.onStateChange?(.paused)
            return
        }
        let url = self.readyChunks.removeFirst()
        do {
            try self.play(url)
        } catch {
            DebugLogger.shared.error("Kokoro playback failed: \(error.localizedDescription)", source: "KokoroTTSProvider")
            self.onStateChange?(.idle)
        }
    }

    private func play(_ wavURL: URL) throws {
        let player = try AVAudioPlayer(contentsOf: wavURL)
        player.delegate = self
        self.player = player
        player.play()
        self.onStateChange?(.speaking)
    }

    /// Splits a passage into speakable chunks at sentence boundaries (and
    /// newlines), merging tiny fragments into their neighbour so playback
    /// doesn't get choppy on one-word sentences.
    static func splitIntoChunks(_ text: String) -> [String] {
        let pattern = #"(?<=[.!?…])\s+|\n+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let nsRange = NSRange(text.startIndex..., in: text)
        var raw: [String] = []
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let piece = String(text[cursor ..< range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { raw.append(piece) }
            cursor = range.upperBound
        }
        let tail = String(text[cursor...]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { raw.append(tail) }
        guard !raw.isEmpty else { return [text] }

        var merged: [String] = []
        for piece in raw {
            if let last = merged.last, last.count + piece.count < 40 {
                merged[merged.count - 1] = last + " " + piece
            } else if piece.count < 8, let last = merged.last {
                merged[merged.count - 1] = last + " " + piece
            } else {
                merged.append(piece)
            }
        }
        return merged
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

    nonisolated func synthesize(text: String, voiceID: String, speed: Float, outputURL: URL) throws -> URL {
        self.lock.lock()
        defer { self.lock.unlock() }

        try self.ensurePipelineLocked(voiceID: voiceID)

        guard let pipeline = self.pipeline else {
            throw PiperEnvironmentError.setupFailed("Kokoro pipeline unavailable")
        }
        return try pipeline.synthesizeToWAV(text: text, voice: voiceID, speed: speed, outputURL: outputURL)
    }

    /// Builds the pipeline (model + voices) without synthesizing anything —
    /// used by `prewarm` so the first real speak starts instantly.
    nonisolated func prewarm(voiceID: String) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        try self.ensurePipelineLocked(voiceID: voiceID)
    }

    private func ensurePipelineLocked(voiceID: String) throws {
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
    }
}

extension KokoroTTSProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            let finishedURL = player.url
            self.player = nil
            if let finishedURL {
                try? FileManager.default.removeItem(at: finishedURL)
            }
            if !self.readyChunks.isEmpty {
                // Chain straight into the next synthesized sentence.
                self.pumpPlayback(generation: self.generation)
            } else if self.synthesisFinished {
                self.onStateChange?(.idle)
                self.onNaturalFinish?()
            }
            // else: next chunk still synthesizing — stay in .speaking so the
            // pill doesn't flicker; pumpPlayback fires when it lands.
        }
    }
}
