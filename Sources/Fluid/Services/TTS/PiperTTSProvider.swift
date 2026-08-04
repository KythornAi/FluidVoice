//
//  PiperTTSProvider.swift
//  FluidChat (FluidVoice fork)
//
//  Phase 2 engine: Piper sidecar. Spawns the app-managed venv's piper,
//  pipes text via stdin, receives WAV on stdout (VoiceAssist sidecar
//  pattern), plays through AVAudioPlayer.
//

import AVFoundation
import Foundation

@MainActor
final class PiperTTSProvider: NSObject, TTSProvider {
    let identifier = "piper"
    let displayName = "Piper (local neural voices)"

    var onStateChange: ((TTSPlaybackState) -> Void)?

    /// Speed multiplier (1.0 = normal); translated to piper's length_scale.
    var rate: Float = 1.0

    /// Selected voice model. Persisted; auto-downloaded on first use.
    var selectedVoiceID: String {
        didSet { UserDefaults.standard.set(self.selectedVoiceID, forKey: Self.voiceDefaultsKey) }
    }

    private static let voiceDefaultsKey = "tts.piperVoiceID"

    private var player: AVAudioPlayer?
    private var synthesisTask: Task<Void, Never>?
    /// Incremented on every speak/stop so stale synthesis results are dropped.
    private var generation: UInt64 = 0

    override init() {
        let saved = UserDefaults.standard.string(forKey: Self.voiceDefaultsKey)
        self.selectedVoiceID = saved ?? PiperVoiceManager.defaultVoiceID
        super.init()
    }

    // MARK: - TTSProvider

    func speak(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.stopInternal(notify: false)
        self.generation &+= 1
        let generation = self.generation

        // Optimistic: pill appears while the (possibly first-run) setup,
        // voice download, and synthesis complete.
        self.onStateChange?(.speaking)

        self.synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await PiperEnvironment.shared.ensureReady()
                if !PiperVoiceManager.isInstalled(self.selectedVoiceID) {
                    try await PiperVoiceManager.shared.download(self.selectedVoiceID)
                }
                let wav = try await self.synthesize(trimmed, voiceID: self.selectedVoiceID)
                guard !Task.isCancelled, self.generation == generation else { return }
                try self.play(wav)
            } catch is CancellationError {
                // Stale request superseded by a newer speak/stop.
            } catch {
                guard self.generation == generation else { return }
                DebugLogger.shared.error("Piper speak failed: \(error.localizedDescription)", source: "PiperTTSProvider")
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

    private func play(_ wav: Data) throws {
        let player = try AVAudioPlayer(data: wav)
        player.delegate = self
        self.player = player
        player.play()
    }

    /// Runs piper as a subprocess: text in via stdin, WAV out via stdout.
    private func synthesize(_ text: String, voiceID: String) async throws -> Data {
        // Piper length_scale: lower = faster; speed multiplier inverts it
        // (VoiceAssist mapping, clamped to piper's sane range).
        let lengthScale = max(0.3, min(3.0, 1.0 / self.rate))
        let modelPath = PiperVoiceManager.voiceFileURL(voiceID, ext: "onnx").path

        let process = Process()
        process.executableURL = PiperEnvironment.venvPython
        process.arguments = [
            "-m", "piper",
            "--model", modelPath,
            "-f", "-",
            "--length-scale", String(format: "%.2f", lengthScale),
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                // Drain stdout concurrently: piper blocks once the 64 KB pipe
                // buffer fills, so waiting for termination before reading
                // deadlocks on any passage longer than ~1.5s of audio.
                let buffer = ProcessDataBuffer()
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    buffer.append(handle.availableData)
                }

                process.terminationHandler = { proc in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    buffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                    let wav = buffer.snapshot()

                    if proc.terminationStatus == 0, wav.count > 44 {
                        continuation.resume(returning: wav)
                    } else {
                        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        continuation.resume(throwing: PiperEnvironmentError.setupFailed(
                            "piper exited \(proc.terminationStatus): \(errText.suffix(300))"
                        ))
                    }
                }

                do {
                    try process.run()
                    stdin.fileHandleForWriting.write(Data(text.utf8))
                    try stdin.fileHandleForWriting.close()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

extension PiperTTSProvider: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.player = nil
            self.onStateChange?(.idle)
        }
    }
}
