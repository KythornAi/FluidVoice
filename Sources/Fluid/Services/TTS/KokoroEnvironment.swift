//
//  KokoroEnvironment.swift
//  FluidChat (FluidVoice fork)
//
//  Manages the Kokoro-82M model files (config + MLX safetensors, ~310 MB)
//  and voice packs, downloaded on demand from the mweinbach/Kokoro-82M-Swift
//  HuggingFace repo into Application Support. Roadmap §7.3 decision: native
//  MLX Swift (vendored kokoro-swift package) over ONNX — no Python runtime,
//  GPU inference via Metal, built-in Misaki G2P.
//

import Combine
import Foundation
import Kokoro

enum KokoroEnvironmentStatus: Equatable {
    case notInstalled
    case installing(step: String)
    case ready
    case failed(String)
}

@MainActor
final class KokoroEnvironment: ObservableObject {
    static let shared = KokoroEnvironment()

    @Published private(set) var status: KokoroEnvironmentStatus = .notInstalled

    private init() {
        if Self.isModelInstalled {
            self.status = .ready
        }
    }

    // MARK: - Paths

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FluidVoice/Kokoro", isDirectory: true)
    }

    static var configURL: URL {
        self.rootDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    static var weightsURL: URL {
        self.rootDirectory.appendingPathComponent("kokoro-v1_0.safetensors", isDirectory: false)
    }

    static var voicesDirectory: URL {
        self.rootDirectory.appendingPathComponent("voices", isDirectory: true)
    }

    static var isModelInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: self.configURL.path),
              let size = try? fm.attributesOfItem(atPath: self.weightsURL.path)[.size] as? Int
        else { return false }
        return size > 100_000_000
    }

    static func isVoiceInstalled(_ voiceID: String) -> Bool {
        FileManager.default.fileExists(
            atPath: self.voicesDirectory.appendingPathComponent("\(voiceID).npy").path
        )
    }

    // MARK: - Setup

    private static func makeDownloader() -> VoiceDownloader {
        VoiceDownloader(cacheDirectory: self.rootDirectory)
    }

    /// Downloads the model (~310 MB) and config on first use. Safe to call
    /// repeatedly; concurrent callers await the in-flight setup.
    func ensureReady() async throws {
        switch self.status {
        case .ready: return
        case .installing:
            while case .installing = self.status {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if self.status == .ready { return }
            if case .failed(let message) = self.status {
                throw PiperEnvironmentError.setupFailed(message)
            }
            return
        case .notInstalled, .failed: break
        }

        do {
            try FileManager.default.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)

            self.status = .installing(step: "Downloading Kokoro config…")
            _ = try await Self.makeDownloader().downloadConfig()

            self.status = .installing(step: "Downloading Kokoro model (~310 MB, one-time)…")
            _ = try await Self.makeDownloader().downloadMLXWeights()

            self.status = .ready
            DebugLogger.shared.info("Kokoro environment ready at \(Self.rootDirectory.path)", source: "KokoroEnvironment")
        } catch {
            let message = error.localizedDescription
            self.status = .failed(message)
            DebugLogger.shared.error("Kokoro setup failed: \(message)", source: "KokoroEnvironment")
            throw error
        }
    }

    /// Downloads a voice pack (.npy, a few MB) if missing.
    func ensureVoice(_ voiceID: String) async throws {
        guard !Self.isVoiceInstalled(voiceID) else { return }
        _ = try await Self.makeDownloader().downloadVoice(voiceID)
        DebugLogger.shared.info("Kokoro voice installed: \(voiceID)", source: "KokoroEnvironment")
    }
}
