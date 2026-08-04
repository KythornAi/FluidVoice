//
//  PiperVoiceManager.swift
//  FluidChat (FluidVoice fork)
//
//  Voice catalog + download-on-demand for Piper models. Curated UK/US set
//  ported from VoiceAssist's download-piper.js; models come from the
//  rhasspy/piper-voices HuggingFace repo and land in the Piper voices dir.
//

import Combine
import Foundation

struct PiperVoice: Identifiable, Equatable {
    /// e.g. "en_GB-alba-medium"
    let id: String
    let lang: String
    let voiceName: String
    let quality: String
    let isMale: Bool

    var label: String {
        let pretty = self.voiceName
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        let region = self.lang.contains("GB") ? "UK" : self.lang.contains("US") ? "US" : self.lang
        return "\(pretty) — \(region) (\(self.isMale ? "male" : "female"), \(self.quality))"
    }

    var onnxURL: URL {
        PiperVoiceManager.voiceFileURL(self.id, ext: "onnx")
    }

    var isInstalled: Bool {
        PiperVoiceManager.isInstalled(self.id)
    }
}

@MainActor
final class PiperVoiceManager: ObservableObject {
    static let shared = PiperVoiceManager()

    private static let huggingFaceBase = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0"

    /// Curated starter set (VoiceAssist's pick): UK and US, male and female.
    /// Kyle defaults to UK English.
    let catalog: [PiperVoice] = [
        PiperVoice(id: "en_GB-alba-medium", lang: "en_GB", voiceName: "alba", quality: "medium", isMale: false),
        PiperVoice(id: "en_GB-alan-medium", lang: "en_GB", voiceName: "alan", quality: "medium", isMale: true),
        PiperVoice(id: "en_GB-cori-medium", lang: "en_GB", voiceName: "cori", quality: "medium", isMale: false),
        PiperVoice(id: "en_GB-northern_english_male-medium", lang: "en_GB", voiceName: "northern_english_male", quality: "medium", isMale: true),
        PiperVoice(id: "en_US-amy-medium", lang: "en_US", voiceName: "amy", quality: "medium", isMale: false),
        PiperVoice(id: "en_US-joe-medium", lang: "en_US", voiceName: "joe", quality: "medium", isMale: true),
        PiperVoice(id: "en_US-kathleen-low", lang: "en_US", voiceName: "kathleen", quality: "low", isMale: false),
        PiperVoice(id: "en_US-kristin-medium", lang: "en_US", voiceName: "kristin", quality: "medium", isMale: false),
        PiperVoice(id: "en_US-norman-medium", lang: "en_US", voiceName: "norman", quality: "medium", isMale: true),
    ]

    /// Voice that auto-downloads on first Piper use.
    static let defaultVoiceID = "en_GB-alba-medium"

    /// IDs currently downloading, for UI progress display.
    @Published private(set) var downloading: Set<String> = []

    /// Bumped after each successful download so views refresh.
    @Published private(set) var installedRevision = 0

    private init() {}

    // MARK: - Files

    static func voiceFileURL(_ voiceID: String, ext: String) -> URL {
        PiperEnvironment.voicesDirectory
            .appendingPathComponent("\(voiceID).\(ext)", isDirectory: false)
    }

    static func isInstalled(_ voiceID: String) -> Bool {
        let fm = FileManager.default
        let onnx = self.voiceFileURL(voiceID, ext: "onnx")
        let json = self.voiceFileURL(voiceID, ext: "onnx.json")
        guard fm.fileExists(atPath: onnx.path), fm.fileExists(atPath: json.path),
              let size = try? fm.attributesOfItem(atPath: onnx.path)[.size] as? Int
        else { return false }
        return size > 1_000_000
    }

    var installedVoices: [PiperVoice] {
        _ = self.installedRevision // dependency for SwiftUI refresh
        return self.catalog.filter(\.isInstalled)
    }

    // MARK: - Download

    /// Downloads the model + config for a voice. No-op if already installed.
    func download(_ voiceID: String) async throws {
        guard !Self.isInstalled(voiceID) else { return }
        guard let voice = self.catalog.first(where: { $0.id == voiceID }) else { return }

        self.downloading.insert(voiceID)
        defer {
            self.downloading.remove(voiceID)
            self.installedRevision &+= 1
        }

        try FileManager.default.createDirectory(
            at: PiperEnvironment.voicesDirectory,
            withIntermediateDirectories: true
        )

        let lang = voice.lang
        let name = voice.voiceName
        let quality = voice.quality
        let folder = "en/\(lang)/\(name)/\(quality)"
        let file = "\(lang)-\(name)-\(quality)"

        for ext in ["onnx", "onnx.json"] {
            let url = URL(string: "\(Self.huggingFaceBase)/\(folder)/\(file).\(ext)")!
            let destination = Self.voiceFileURL(voiceID, ext: ext)
            let temp = destination.appendingPathExtension("download")

            let (downloaded, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PiperEnvironmentError.setupFailed("Voice download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(url.lastPathComponent)")
            }
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.moveItem(at: downloaded, to: temp)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
        }

        DebugLogger.shared.info("Piper voice installed: \(voiceID)", source: "PiperVoiceManager")
    }
}
