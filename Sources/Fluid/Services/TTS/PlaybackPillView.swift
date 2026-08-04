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

    private static let speedSteps: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            if let text = self.tts.currentText {
                Text(text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180)
            }

            self.pauseResumeButton
            self.stopButton

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

    private var pauseResumeButton: some View {
        Button {
            self.tts.togglePause()
        } label: {
            Image(systemName: self.tts.playbackState == .paused ? "play.fill" : "pause.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(self.tts.playbackState == .paused ? "Resume" : "Pause")
    }

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
        .help("Stop")
    }

    /// Cycles through the speed ladder. Changing speed mid-utterance only
    /// affects the next speak for AVSpeech (native limitation); Piper/Kokoro
    /// rebuild audio per request so they pick it up immediately.
    private var speedButton: some View {
        Button {
            self.cycleSpeed()
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
        .help("Playback speed (click to cycle)")
    }

    private func cycleSpeed() {
        let steps = Self.speedSteps
        guard let currentIndex = steps.firstIndex(where: { abs($0 - self.tts.playbackSpeed) < 0.01 }) else {
            self.tts.playbackSpeed = 1.0
            return
        }
        self.tts.playbackSpeed = steps[(currentIndex + 1) % steps.count]
    }

    static func speedLabel(_ speed: Float) -> String {
        speed.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f×", speed)
            : String(format: "%g×", speed)
    }
}
