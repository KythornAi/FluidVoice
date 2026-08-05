//
//  PlaybackPillView.swift
//  FluidChat (FluidVoice fork)
//
//  Floating mini-player shown while read-aloud is active (roadmap §4 playback
//  UX). Reuses the notch-overlay aesthetic: black capsule, white controls,
//  subtle hairline border. Pause/resume, stop, and speed control.
//

import SwiftUI

struct PlaybackPillView: View {
    @ObservedObject private var tts = TTSService.shared
    @State private var showSpeedPopover = false

    var body: some View {
        HStack(spacing: 10) {
            if self.tts.playbackState == .preparing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.9))
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }

            if self.tts.playbackState == .preparing {
                Text("Preparing voice…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
            } else if let text = self.tts.currentText {
                Text(text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180)
            }

            // Queue session indicator + skip (Phase 5 queue reading)
            if self.tts.queueCompletedCount > 0 || !self.tts.queue.isEmpty {
                Text(self.tts.queuePositionLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                self.skipButton
            }

            self.playPauseButton
            self.stopButton
            self.closeButton

            Divider()
                .frame(height: 16)
                .overlay(Color.white.opacity(0.15))

            self.speedButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    // MARK: - Controls

    /// One button whose meaning follows the session: pause while speaking,
    /// resume while paused, and "read selection / replay" when parked.
    private var playPauseButton: some View {
        Button {
            switch self.tts.playbackState {
            case .speaking:
                self.tts.pause()
            case .paused, .idle:
                self.tts.playFromPill()
            case .preparing:
                break // synthesis in flight; nothing to pause yet
            }
        } label: {
            Image(systemName: self.tts.playbackState == .speaking ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(self.playPauseHelp)
    }

    private var playPauseHelp: String {
        switch self.tts.playbackState {
        case .speaking: return "Pause"
        case .paused: return "Resume"
        case .idle: return "Read selection (or replay last passage)"
        case .preparing: return "Preparing voice…"
        }
    }

    /// Skip button (queue sessions): drop the current passage and start the
    /// next queued one; with nothing pending it behaves like stop.
    private var skipButton: some View {
        Button {
            self.tts.skipToNext()
        } label: {
            Image(systemName: "forward.end.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(self.tts.queue.isEmpty ? "Finish queue (nothing else pending)" : "Skip to next queued passage")
    }

    /// Stops the audio but keeps the pill parked — only × dismisses it.
    private var stopButton: some View {
        Button {
            self.tts.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Stop (pill stays parked)")
        .disabled(self.tts.playbackState == .idle)
        .opacity(self.tts.playbackState == .idle ? 0.4 : 1)
    }

    private var closeButton: some View {
        Button {
            self.tts.dismissSession()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
    }

    /// Shows the current speed; click opens a slider popover (0.75–2.0×).
    /// Changing speed mid-utterance only affects the next speak for AVSpeech
    /// (native limitation); Piper/Kokoro rebuild audio per request so they
    /// pick it up immediately.
    private var speedButton: some View {
        Button {
            self.showSpeedPopover = true
        } label: {
            Text(Self.speedLabel(self.tts.playbackSpeed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Playback speed")
        .popover(isPresented: self.$showSpeedPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Playback speed")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(Self.speedLabel(self.tts.playbackSpeed))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("0.75×")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(self.tts.playbackSpeed) },
                            set: { self.tts.playbackSpeed = Float($0) }
                        ),
                        in: 0.75 ... 2.0,
                        step: 0.25
                    )
                    Text("2×")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 230)
        }
    }

    static func speedLabel(_ speed: Float) -> String {
        speed.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f×", speed)
            : String(format: "%g×", speed)
    }
}
