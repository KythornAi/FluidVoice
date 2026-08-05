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
    @ObservedObject private var kokoroEnvironment = KokoroEnvironment.shared

    /// Bumped after a Kokoro voice download finishes so rows refresh.
    @State private var kokoroInstalledRevision = 0
    /// Kokoro voices currently downloading.
    @State private var kokoroDownloading: Set<String> = []

    // Cloud engine state (Phase 3)
    /// Bumped when a cloud API key is saved/removed so rows refresh.
    @State private var cloudKeyRevision = 0
    @State private var fishKeyDraft = ""
    @State private var openAIKeyDraft = ""
    @State private var cloudKeyError: String?
    @State private var fishVoices: [(id: String, title: String)] = []
    @State private var fishVoicesLoading = false
    @State private var fishCredit: String?
    @State private var fishCreditLoading = false

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

            Text("Highlight text anywhere and press the read-aloud shortcut (Control + R) to hear it. For listening sessions, press Control + J instead: each highlighted passage joins a queue and plays in turn, with a skip button and progress on the pill. Local engines work free and offline; cloud engines are optional and use your own API key.")
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

            Divider().opacity(0.2)

            // MARK: Playback speed

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playback Speed")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.titleText)
                    Text("Applies to every engine. Also adjustable from the playback pill.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.secondaryText)
                }

                Spacer()

                Text(PlaybackPillView.speedLabel(self.tts.playbackSpeed))
                    .font(self.theme.typography.bodySmall.monospaced())
                    .foregroundStyle(self.secondaryText)
                    .frame(width: 40, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { Double(self.tts.playbackSpeed) },
                        set: { self.tts.playbackSpeed = Float($0) }
                    ),
                    in: 0.75 ... 2.0,
                    step: 0.25
                )
                .frame(width: 160, alignment: .trailing)
            }

            Divider().opacity(0.2)

            // MARK: Read-back after dictation

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read Back After Dictation")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.titleText)
                    Text("Speaks each finished transcript aloud with the active engine, so you can prooflisten. Starting a new dictation stops playback automatically.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { self.tts.readBackAfterDictationEnabled },
                    set: { self.tts.readBackAfterDictationEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            // MARK: Piper voice management

            if self.tts.activeProviderID == "piper" {
                Divider().opacity(0.2)
                self.piperSection
            }

            // MARK: Kokoro voice management

            if self.tts.activeProviderID == "kokoro" {
                Divider().opacity(0.2)
                self.kokoroSection
            }

            // MARK: Fish Audio (cloud)

            if self.tts.activeProviderID == "fishaudio" {
                Divider().opacity(0.2)
                self.fishSection
            }

            // MARK: OpenAI TTS (cloud)

            if self.tts.activeProviderID == "openaitts" {
                Divider().opacity(0.2)
                self.openAISection
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
                .disabled(self.previewDisabled)
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

    private var previewDisabled: Bool {
        switch self.tts.activeProviderID {
        case "piper": return self.piperEnvironment.status != .ready
        case "kokoro": return self.kokoroEnvironment.status != .ready
        case "fishaudio": return !self.cloudHasKey(FishTTSProvider.keychainProviderID)
        case "openaitts": return !self.cloudHasKey(OpenAITTSProvider.keychainProviderID)
        default: return false
        }
    }

    private var engineDescription: String {
        switch self.tts.activeProviderID {
        case "avspeech":
            return "Built-in macOS voice (follows System Settings > Spoken Content)."
        case "piper":
            return "Local neural voices, downloaded on demand."
        case "kokoro":
            return "Local neural voice, runs on Apple Silicon."
        case "fishaudio":
            return "Cloud voices on Fish Audio's free developer tier (~1 hr/month) with your own API key."
        case "openaitts":
            return "OpenAI cloud voices, billed to your own API key."
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

    // MARK: - Kokoro

    /// Curated English Kokoro voices: all 8 British plus American staples.
    private static let kokoroCatalog: [(id: String, label: String)] = [
        ("bf_emma", "Emma — UK (female)"),
        ("bf_isabella", "Isabella — UK (female)"),
        ("bf_alice", "Alice — UK (female)"),
        ("bf_lily", "Lily — UK (female)"),
        ("bm_george", "George — UK (male)"),
        ("bm_daniel", "Daniel — UK (male)"),
        ("bm_fable", "Fable — UK (male)"),
        ("bm_lewis", "Lewis — UK (male)"),
        ("af_heart", "Heart — US (female)"),
        ("af_bella", "Bella — US (female)"),
        ("af_sarah", "Sarah — US (female)"),
        ("am_adam", "Adam — US (male)"),
        ("am_michael", "Michael — US (male)"),
        ("am_liam", "Liam — US (male)"),
    ]

    @ViewBuilder
    private var kokoroSection: some View {
        switch self.kokoroEnvironment.status {
        case .notInstalled:
            self.environmentRow(
                message: "Kokoro needs a one-time model download (~310 MB).",
                buttonTitle: "Set up Kokoro"
            ) {
                Task { try? await KokoroEnvironment.shared.ensureReady() }
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
                Task { try? await KokoroEnvironment.shared.ensureReady() }
            }

        case .ready:
            self.kokoroVoicePicker
            Divider().opacity(0.2)
            self.kokoroVoiceDownloads
        }
    }

    private var kokoroVoicePicker: some View {
        let installed = Self.kokoroCatalog.filter { KokoroEnvironment.isVoiceInstalled($0.id) }
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.titleText)
                Text("Installed Kokoro voices. Download more below.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.secondaryText)
            }

            Spacer()

            Picker("", selection: Binding(
                get: { (self.tts.activeProvider as? KokoroTTSProvider)?.selectedVoiceID ?? KokoroTTSProvider.defaultVoiceID },
                set: { (self.tts.activeProvider as? KokoroTTSProvider)?.selectedVoiceID = $0 }
            )) {
                ForEach(installed, id: \.id) { voice in
                    Text(voice.label).tag(voice.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 230, alignment: .trailing)
            .disabled(installed.isEmpty)
        }
    }

    private var kokoroVoiceDownloads: some View {
        _ = self.kokoroInstalledRevision // refresh dependency
        let notInstalled = Self.kokoroCatalog.filter { !KokoroEnvironment.isVoiceInstalled($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            if notInstalled.isEmpty {
                Text("All catalog voices installed.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.secondaryText)
            } else {
                Text("Download voices")
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.titleText)

                ForEach(notInstalled, id: \.id) { voice in
                    HStack {
                        Text(voice.label)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.secondaryText)
                        Spacer()
                        if self.kokoroDownloading.contains(voice.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Download") {
                                self.kokoroDownloading.insert(voice.id)
                                Task {
                                    try? await KokoroEnvironment.shared.ensureVoice(voice.id)
                                    self.kokoroDownloading.remove(voice.id)
                                    self.kokoroInstalledRevision &+= 1
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Cloud providers (Phase 3)

    /// Keychain lookup with a refresh dependency on `cloudKeyRevision`.
    private func cloudHasKey(_ keychainProviderID: String) -> Bool {
        _ = self.cloudKeyRevision
        return KeychainService.shared.containsKey(for: keychainProviderID)
    }

    /// Shared API-key row for cloud engines. Keys go through the existing
    /// KeychainService (same store as the AI-enhancement providers); they
    /// are never logged or shown after saving.
    private func cloudKeyRow(
        title: String,
        keychainProviderID: String,
        draft: Binding<String>
    ) -> some View {
        let hasKey = self.cloudHasKey(keychainProviderID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.titleText)
                    Text(hasKey
                         ? "Saved in your macOS Keychain."
                         : "Required — stored only in your macOS Keychain.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.secondaryText)
                }

                Spacer()

                SecureField(hasKey ? "Replace key…" : "Paste API key…", text: draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Button("Save") {
                    let key = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return }
                    do {
                        try KeychainService.shared.storeKey(key, for: keychainProviderID)
                        // Verify read-back so a denied Keychain prompt surfaces here.
                        _ = try KeychainService.shared.fetchKey(for: keychainProviderID)
                        draft.wrappedValue = ""
                        self.cloudKeyError = nil
                        self.cloudKeyRevision &+= 1
                    } catch {
                        self.cloudKeyError = "Could not save to Keychain. Choose \"Always Allow\" if macOS asks, then try again."
                    }
                }
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasKey {
                    Button("Remove") {
                        try? KeychainService.shared.deleteKey(for: keychainProviderID)
                        self.cloudKeyRevision &+= 1
                    }
                }
            }

            if let error = self.cloudKeyError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var fishSection: some View {
        self.cloudKeyRow(
            title: "Fish Audio API Key",
            keychainProviderID: FishTTSProvider.keychainProviderID,
            draft: self.$fishKeyDraft
        )

        if self.cloudHasKey(FishTTSProvider.keychainProviderID) {
            Divider().opacity(0.2)
            self.fishVoicePicker
            Divider().opacity(0.2)
            self.fishCreditRow
        }
    }

    private var fishVoicePicker: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.titleText)
                Text("Voices from your Fish Audio account (fish.audio).")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.secondaryText)
            }

            Spacer()

            if self.fishVoicesLoading {
                ProgressView().controlSize(.small)
            }

            Picker("", selection: Binding(
                get: { (self.tts.activeProvider as? FishTTSProvider)?.selectedVoiceID ?? "" },
                set: { (self.tts.activeProvider as? FishTTSProvider)?.selectedVoiceID = $0 }
            )) {
                Text("Fish default voice").tag("")
                ForEach(self.fishVoices, id: \.id) { voice in
                    Text(voice.title).tag(voice.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200, alignment: .trailing)

            Button {
                self.refreshFishAccountInfo()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh voice list and credit balance")
        }
        .task(id: self.cloudKeyRevision) {
            self.refreshFishAccountInfo()
        }
    }

    private var fishCreditRow: some View {
        HStack {
            Text("Free-tier credit")
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.titleText)
            Spacer()
            if self.fishCreditLoading {
                ProgressView().controlSize(.small)
            } else if let credit = self.fishCredit {
                Text(credit)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.secondaryText)
            } else {
                Text("—")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.secondaryText)
            }
        }
    }

    private func refreshFishAccountInfo() {
        guard let key = try? KeychainService.shared.fetchKey(for: FishTTSProvider.keychainProviderID),
              !key.isEmpty
        else { return }
        self.fishVoicesLoading = true
        self.fishCreditLoading = true
        Task {
            if let voices = try? await FishTTSProvider.fetchVoices(apiKey: key) {
                self.fishVoices = voices
            }
            self.fishVoicesLoading = false
        }
        Task {
            self.fishCredit = try? await FishTTSProvider.fetchCredit(apiKey: key)
            self.fishCreditLoading = false
        }
    }

    @ViewBuilder
    private var openAISection: some View {
        self.cloudKeyRow(
            title: "OpenAI API Key",
            keychainProviderID: OpenAITTSProvider.keychainProviderID,
            draft: self.$openAIKeyDraft
        )

        if self.cloudHasKey(OpenAITTSProvider.keychainProviderID) {
            Divider().opacity(0.2)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.titleText)
                    Text("Usage is billed to your OpenAI account.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.secondaryText)
                }

                Spacer()

                Picker("", selection: Binding(
                    get: { (self.tts.activeProvider as? OpenAITTSProvider)?.selectedVoiceID ?? OpenAITTSProvider.defaultVoice },
                    set: { (self.tts.activeProvider as? OpenAITTSProvider)?.selectedVoiceID = $0 }
                )) {
                    ForEach(OpenAITTSProvider.voices, id: \.id) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 230, alignment: .trailing)
            }

            Divider().opacity(0.2)

            HStack(alignment: .center) {
                Text("Model")
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.titleText)

                Spacer()

                Picker("", selection: Binding(
                    get: { (self.tts.activeProvider as? OpenAITTSProvider)?.selectedModel ?? OpenAITTSProvider.defaultModel },
                    set: { (self.tts.activeProvider as? OpenAITTSProvider)?.selectedModel = $0 }
                )) {
                    ForEach(OpenAITTSProvider.models, id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 230, alignment: .trailing)
            }
        }
    }

    // MARK: - Piper voice downloads

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
