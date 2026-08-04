//
//  PiperEnvironment.swift
//  FluidChat (FluidVoice fork)
//
//  Manages the Piper Python sidecar environment: a dedicated venv under
//  Application Support with piper-tts pinned, created on demand. VoiceAssist
//  proved the native piper macOS binary ships with missing dylibs, so the
//  official PyPI package (rhasspy/OHF-Voice) is the reliable engine path.
//

import Combine
import Foundation

enum PiperEnvironmentError: LocalizedError {
    case noPython
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPython:
            return "No usable python3 found (looked in /usr/bin, /opt/homebrew/bin, /usr/local/bin)."
        case .setupFailed(let detail):
            return "Piper setup failed: \(detail)"
        }
    }
}

enum PiperEnvironmentStatus: Equatable {
    case notInstalled
    case installing(step: String)
    case ready
    case failed(String)
}

/// Owns the piper venv. Setup runs off the main actor; status is published
/// for the settings UI.
@MainActor
final class PiperEnvironment: ObservableObject {
    static let shared = PiperEnvironment()

    static let piperPackage = "piper-tts==1.6.0"

    @Published private(set) var status: PiperEnvironmentStatus = .notInstalled

    private init() {
        if Self.isVenvUsable {
            self.status = .ready
        }
    }

    // MARK: - Paths

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FluidVoice/Piper", isDirectory: true)
    }

    static var venvDirectory: URL {
        self.rootDirectory.appendingPathComponent("venv", isDirectory: true)
    }

    static var venvPython: URL {
        self.venvDirectory.appendingPathComponent("bin/python", isDirectory: false)
    }

    static var voicesDirectory: URL {
        self.rootDirectory.appendingPathComponent("voices", isDirectory: true)
    }

    static var isVenvUsable: Bool {
        FileManager.default.fileExists(atPath: self.venvPython.path)
    }

    // MARK: - Setup

    /// Creates the venv and installs piper-tts if needed. Safe to call
    /// repeatedly; no-ops when already ready or in progress.
    func ensureReady() async throws {
        switch self.status {
        case .ready: return
        case .installing: break // fall through and let the caller await the loop below
        case .notInstalled, .failed: break
        }

        if case .installing = self.status {
            // Another caller is setting up; poll until it resolves.
            while case .installing = self.status {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if self.status == .ready { return }
            if case .failed(let message) = self.status { throw PiperEnvironmentError.setupFailed(message) }
            return
        }

        guard let python3 = Self.findSystemPython() else {
            self.status = .failed("python3 not found")
            throw PiperEnvironmentError.noPython
        }

        do {
            try FileManager.default.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)

            self.status = .installing(step: "Creating Python environment…")
            try await Self.runProcess(python3, ["-m", "venv", Self.venvDirectory.path])

            self.status = .installing(step: "Installing Piper (one-time download)…")
            let pip = Self.venvDirectory.appendingPathComponent("bin/pip").path
            try await Self.runProcess(pip, ["install", "--quiet", Self.piperPackage])

            self.status = .ready
            DebugLogger.shared.info("Piper environment ready at \(Self.venvDirectory.path)", source: "PiperEnvironment")
        } catch {
            let message = error.localizedDescription
            self.status = .failed(message)
            DebugLogger.shared.error("Piper setup failed: \(message)", source: "PiperEnvironment")
            throw error
        }
    }

    private static func findSystemPython() -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a process to completion, throwing on non-zero exit with stderr.
    nonisolated static func runProcess(_ launchPath: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice

            // Drain stderr concurrently or a chatty child (e.g. pip) can
            // fill the pipe buffer and deadlock against our wait.
            let buffer = ProcessDataBuffer()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                buffer.append(handle.availableData)
            }

            process.terminationHandler = { proc in
                stderr.fileHandleForReading.readabilityHandler = nil
                buffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                let errText = String(data: buffer.snapshot(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PiperEnvironmentError.setupFailed(
                        "\(launchPath) exited \(proc.terminationStatus): \(errText.suffix(400))"
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
