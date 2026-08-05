//
//  FishTTSProvider.swift
//  FluidChat (FluidVoice fork)
//
//  Phase 3 engine: Fish Audio cloud TTS (free developer tier first).
//  User supplies their own API key, stored via the existing
//  KeychainService. Synthesised MP3 plays through AVAudioPlayer.
//
//  API reference (docs.fish.audio, checked 4 Aug 2026):
//    POST https://api.fish.audio/v1/tts
//      headers: Authorization: Bearer <key>, model: s2.1-pro-free
//      body: { text, reference_id?, prosody: { speed }, format: "mp3" }
//    GET  /model?self=true            -> user's voice models (reference_id)
//    GET  /wallet/self/api-credit     -> { credit } balance
//

import AVFoundation
import Foundation

@MainActor
final class FishTTSProvider: NSObject, TTSProvider {
    let identifier = "fishaudio"
    let displayName = "Fish Audio (cloud · free tier)"

    var onStateChange: ((TTSPlaybackState) -> Void)?
    /// Fired only from audioPlayerDidFinishPlaying — drives queue advance.
    var onNaturalFinish: (() -> Void)?

    /// Speed multiplier (1.0 = normal); maps onto Fish `prosody.speed`.
    var rate: Float = 1.0

    /// Fish voice model ID (`reference_id`). Empty = Fish's default voice.
    var selectedVoiceID: String {
        didSet { UserDefaults.standard.set(self.selectedVoiceID, forKey: Self.voiceDefaultsKey) }
    }

    static let keychainProviderID = "tts.fishaudio"
    private static let voiceDefaultsKey = "tts.fishVoiceID"
    private static let endpoint = URL(string: "https://api.fish.audio/v1/tts")!
    private static let voicesEndpoint = URL(string: "https://api.fish.audio/model?self=true&page_size=100")!
    private static let creditEndpoint = URL(string: "https://api.fish.audio/wallet/self/api-credit")!
    /// Free developer tier model, per docs. Paid tiers (s2-pro, s2.1-pro)
    /// are deliberately not offered — free-first principle.
    private static let modelHeader = "s2.1-pro-free"

    private var player: AVAudioPlayer?
    private var synthesisTask: Task<Void, Never>?
    /// Incremented on every speak/stop so stale synthesis results are dropped.
    private var generation: UInt64 = 0

    override init() {
        self.selectedVoiceID = UserDefaults.standard.string(forKey: Self.voiceDefaultsKey) ?? ""
        super.init()
    }

    // MARK: - Credentials & account info

    var hasAPIKey: Bool {
        KeychainService.shared.containsKey(for: Self.keychainProviderID)
    }

    private func apiKey() throws -> String {
        guard let key = try KeychainService.shared.fetchKey(for: Self.keychainProviderID),
              !key.isEmpty
        else {
            throw FishTTSError.noAPIKey
        }
        return key
    }

    /// The user's own Fish Audio voice models (for the settings voice picker).
    static func fetchVoices(apiKey: String) async throws -> [(id: String, title: String)] {
        var request = URLRequest(url: Self.voicesEndpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)

        struct Page: Decodable {
            struct Item: Decodable {
                let _id: String
                let title: String
                let state: String
            }
            let items: [Item]
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        // Only trained voices are usable as reference_id.
        return page.items.filter { $0.state == "trained" }.map { ($0._id, $0.title) }
    }

    /// Raw API credit balance (nice-to-have free-tier indicator).
    static func fetchCredit(apiKey: String) async throws -> String {
        var request = URLRequest(url: Self.creditEndpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)

        struct Credit: Decodable {
            let credit: Double
        }
        let credit = try JSONDecoder().decode(Credit.self, from: data)
        return String(format: "%.0f", credit.credit)
    }

    // MARK: - TTSProvider

    func speak(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.stopInternal(notify: false)
        self.generation &+= 1
        let generation = self.generation

        // Preparing state: pill shows a spinner while the network request completes.
        self.onStateChange?(.preparing)

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
                DebugLogger.shared.error("Fish Audio speak failed: \(error.localizedDescription)", source: "FishTTSProvider")
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
        self.onStateChange?(.speaking)
    }

    private func synthesize(_ text: String) async throws -> Data {
        let key = try self.apiKey()

        struct Prosody: Encodable {
            let speed: Float
        }
        struct Body: Encodable {
            let text: String
            let reference_id: String?
            let prosody: Prosody
            let format: String
        }
        let body = Body(
            text: text,
            reference_id: self.selectedVoiceID.isEmpty ? nil : self.selectedVoiceID,
            prosody: Prosody(speed: max(0.5, min(2.0, self.rate))),
            format: "mp3"
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.modelHeader, forHTTPHeaderField: "model")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 120 // long passages synthesise chunk-by-chunk server-side

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        guard !data.isEmpty else { throw FishTTSError.emptyAudio }
        return data
    }

    /// Throws a readable error for non-2xx responses. Fish returns
    /// `{"status":..., "message":...}` on failure; never log the request key.
    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable {
                let message: String?
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
            throw FishTTSError.http(status: statusCode, message: message)
        }
    }
}

enum FishTTSError: Error, LocalizedError {
    case noAPIKey
    case emptyAudio
    case http(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No Fish Audio API key. Add one in Settings > Read Aloud."
        case .emptyAudio:
            return "Fish Audio returned no audio."
        case .http(let status, let message):
            if let message, !message.isEmpty {
                return "Fish Audio error \(status): \(message)"
            }
            return "Fish Audio request failed (HTTP \(status))."
        }
    }
}

extension FishTTSProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.player = nil
            self.onStateChange?(.idle)
            self.onNaturalFinish?()
        }
    }
}
