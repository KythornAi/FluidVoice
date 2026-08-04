//
//  OpenAITTSProvider.swift
//  FluidChat (FluidVoice fork)
//
//  Phase 3 engine: OpenAI TTS. Strictly opt-in — the user supplies their
//  own (paid) API key via the existing KeychainService; never a default
//  engine (free-first principle, roadmap §4).
//
//  API reference (platform.openai.com):
//    POST https://api.openai.com/v1/audio/speech
//      headers: Authorization: Bearer <key>
//      body: { model, voice, input, response_format: "mp3", speed }
//

import AVFoundation
import Foundation

@MainActor
final class OpenAITTSProvider: NSObject, TTSProvider {
    let identifier = "openaitts"
    let displayName = "OpenAI TTS (cloud · paid, your key)"

    var onStateChange: ((TTSPlaybackState) -> Void)?

    /// Speed multiplier (1.0 = normal); OpenAI accepts 0.25...4.0.
    var rate: Float = 1.0

    /// Selected OpenAI voice. Persisted.
    var selectedVoiceID: String {
        didSet { UserDefaults.standard.set(self.selectedVoiceID, forKey: Self.voiceDefaultsKey) }
    }

    /// Selected model. Persisted; cheapest sensible default.
    var selectedModel: String {
        didSet { UserDefaults.standard.set(self.selectedModel, forKey: Self.modelDefaultsKey) }
    }

    static let keychainProviderID = "tts.openaitts"
    private static let voiceDefaultsKey = "tts.openaiVoice"
    private static let modelDefaultsKey = "tts.openaiModel"
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!

    static let defaultVoice = "nova"
    static let defaultModel = "gpt-4o-mini-tts"

    /// Voice picker catalogue (label shown in settings).
    static let voices: [(id: String, label: String)] = [
        ("nova", "Nova (female, warm)"),
        ("alloy", "Alloy (neutral)"),
        ("ash", "Ash (male, calm)"),
        ("ballad", "Ballad (male)"),
        ("coral", "Coral (female, bright)"),
        ("echo", "Echo (male)"),
        ("fable", "Fable (British, expressive)"),
        ("onyx", "Onyx (male, deep)"),
        ("sage", "Sage (female)"),
        ("shimmer", "Shimmer (female, soft)"),
        ("verse", "Verse (male, dynamic)"),
        ("marin", "Marin (new generation)"),
        ("cedar", "Cedar (new generation)"),
    ]

    /// Model picker catalogue.
    static let models: [(id: String, label: String)] = [
        ("gpt-4o-mini-tts", "gpt-4o-mini-tts (cheapest)"),
        ("tts-1", "tts-1 (legacy, fast)"),
        ("tts-1-hd", "tts-1-hd (legacy, quality)"),
    ]

    private var player: AVAudioPlayer?
    private var synthesisTask: Task<Void, Never>?
    /// Incremented on every speak/stop so stale synthesis results are dropped.
    private var generation: UInt64 = 0

    override init() {
        self.selectedVoiceID = UserDefaults.standard.string(forKey: Self.voiceDefaultsKey) ?? Self.defaultVoice
        self.selectedModel = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? Self.defaultModel
        super.init()
    }

    // MARK: - Credentials

    var hasAPIKey: Bool {
        KeychainService.shared.containsKey(for: Self.keychainProviderID)
    }

    private func apiKey() throws -> String {
        guard let key = try KeychainService.shared.fetchKey(for: Self.keychainProviderID),
              !key.isEmpty
        else {
            throw OpenAITTSError.noAPIKey
        }
        return key
    }

    // MARK: - TTSProvider

    func speak(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.stopInternal(notify: false)
        self.generation &+= 1
        let generation = self.generation

        // Optimistic: pill appears while the network request completes.
        self.onStateChange?(.speaking)

        self.synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.synthesize(trimmed)
                guard !Task.isCancelled, self.generation == generation else { return }
                try self.play(audio)
            } catch is CancellationError {
                // Stale request superseded by a newer speak/stop.
            } catch {
                guard self.generation == generation else { return }
                DebugLogger.shared.error("OpenAI TTS speak failed: \(error.localizedDescription)", source: "OpenAITTSProvider")
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

    private func play(_ mp3: Data) throws {
        let player = try AVAudioPlayer(data: mp3)
        player.delegate = self
        self.player = player
        player.play()
    }

    private func synthesize(_ text: String) async throws -> Data {
        let key = try self.apiKey()

        struct Body: Encodable {
            let model: String
            let voice: String
            let input: String
            let response_format: String
            let speed: Float
        }
        let body = Body(
            model: self.selectedModel,
            voice: self.selectedVoiceID,
            input: text,
            response_format: "mp3",
            speed: max(0.25, min(4.0, self.rate))
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        guard !data.isEmpty else { throw OpenAITTSError.emptyAudio }
        return data
    }

    /// Throws a readable error for non-2xx responses. OpenAI returns
    /// `{"error": {"message": ...}}` on failure; never log the request key.
    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            struct ErrorEnvelope: Decodable {
                struct ErrorBody: Decodable {
                    let message: String?
                }
                let error: ErrorBody?
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message
            throw OpenAITTSError.http(status: statusCode, message: message)
        }
    }
}

enum OpenAITTSError: Error, LocalizedError {
    case noAPIKey
    case emptyAudio
    case http(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No OpenAI API key. Add one in Settings > Read Aloud."
        case .emptyAudio:
            return "OpenAI TTS returned no audio."
        case .http(let status, let message):
            if let message, !message.isEmpty {
                return "OpenAI error \(status): \(message)"
            }
            return "OpenAI TTS request failed (HTTP \(status))."
        }
    }
}

extension OpenAITTSProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.player = nil
            self.onStateChange?(.idle)
        }
    }
}
