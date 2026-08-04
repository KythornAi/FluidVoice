//
//  ReadAloudSettingsSection.swift
//  FluidChat (FluidVoice fork)
//
//  Settings card for read-aloud: engine picker → voice picker → preview,
//  plus Piper voice download management (roadmap §5 Phase 2 voice picker).
//  Self-contained in the TTS module to keep upstream merges clean.
//

import SwiftUI

struct ReadAloudSettingsSection: View {
    @ObservedObject private var tts = TTSService.shared
    @ObservedObject private var piperEnvironment = PiperEnvironment.shared
    @ObservedObject private var voiceManager = PiperVoiceManager.shared

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private static let previewText = "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife."

    private var titleText: Color { Color(nsColor: .labelColor) }
    private var secondaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.90) : self.theme.palette.primaryText.opacity(0.82)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read Aloud")
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.titleText)

            Text("Highlight text anywhere and press the read-aloud shortcut to hear it. Engines are all local and free; switch any time without a rebuild.")
                .font(.caption)
                .foregroundStyle(self.secondaryText)

            // MARK: Engine picker

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Engine")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.titleText)
                    Text(self.engineDescription)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.secondaryText)
                }

                Spacer()

                Picker("", selection: self.$tts.activeProviderID) {
                    ForEach(self.tts.availableProviders, id: \.identifier) { provider in
                        Text(provider.displayName).tag(provider.identifier)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 230, alignment: .trailing)
            }

            // MARK: Piper voice management

            if self.tts.activeProviderID == "piper" {
                Divider().opacity(0.2)
                self.piperSection
            }

            Divider().opacity(0.2)

            // MARK: Preview

            HStack {
                Text("Preview")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.titleText)
                Spacer()
                Button {
                    self.tts.speak(text: Self.previewText)
                } label: {
                    Label("Play sample", systemImage: "play.circle")
                }
                .disabled(self.tts.activeProviderID == "piper" && self.piperEnvironment.status != .ready)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.elevatedCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private var engineDescription: String {
        switch self.tts.activeProviderID {
        case "avspeech":
            return "Built-in macOS voice (follows System Settings > Spoken Content)."
        case "piper":
            return "Local neural voices, downloaded on demand."
        default:
            return "Local neural voice."
        }
    }

    // MARK: - Piper

    @ViewBuilder
    private var piperSection: some View {
        switch self.piperEnvironment.status {
        case .notInstalled:
            self.environmentRow(
                message: "Piper needs a one-time setup (~100 MB download).",
                buttonTitle: "Set up Piper"
            ) {
                Task { try? await PiperEnvironment.shared.ensureReady() }
            }

        case .installing(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.secondaryText)
            }

        case .failed(let message):
            self.environmentRow(
                message: "Setup failed: \(message)",
                buttonTitle: "Retry setup"
            ) {
                Task { try? await PiperEnvironment.shared.ensureReady() }
            }

        case .ready:
            self.voicePicker
            Divider().opacity(0.2)
            self.voiceDownloads
        }
    }

    private func environmentRow(message: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(message)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.secondaryText)
                .lineLimit(2)
            Spacer()
            Button(buttonTitle, action: action)
        }
    }

    private var voicePicker: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.titleText)
                Text("Installed Piper voices. Download more below.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.secondaryText)
            }

            Spacer()

            Picker("", selection: Binding(
                get: { (self.tts.activeProvider as? PiperTTSProvider)?.selectedVoiceID ?? PiperVoiceManager.defaultVoiceID },
                set: { (self.tts.activeProvider as? PiperTTSProvider)?.selectedVoiceID = $0 }
            )) {
                ForEach(self.voiceManager.installedVoices) { voice in
                    Text(voice.label).tag(voice.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 230, alignment: .trailing)
            .disabled(self.voiceManager.installedVoices.isEmpty)
        }
    }

    private var voiceDownloads: some View {
        let notInstalled = self.voiceManager.catalog.filter { !$0.isInstalled }
        return VStack(alignment: .leading, spacing: 6) {
            if notInstalled.isEmpty {
                Text("All catalog voices installed.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.secondaryText)
            } else {
                Text("Download voices")
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.titleText)

                ForEach(notInstalled) { voice in
                    HStack {
                        Text(voice.label)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.secondaryText)
                        Spacer()
                        if self.voiceManager.downloading.contains(voice.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Download") {
                                Task { try? await self.voiceManager.download(voice.id) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}
