//
//  ReadAloudHotkeyService.swift
//  FluidChat (FluidVoice fork)
//
//  Lightweight global hotkey for read-aloud, deliberately separate from
//  GlobalHotkeyManager (which is a dictation-specific hold-mode state
//  machine). Press once to read the current selection; press again to stop.
//

import AppKit
import Foundation

@MainActor
final class ReadAloudHotkeyService {
    static let shared = ReadAloudHotkeyService()

    /// Default: Control + R ("R" for Read). Single-modifier combo chosen for
    /// Kyle's hybrid keyboard, which handles multi-modifier Mac combos poorly.
    static let defaultShortcut = HotkeyShortcut(keyCode: 15, modifierFlags: [.control])
    private static let shortcutDefaultsKey = "tts.readAloudShortcut"

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isStarted = false

    /// The active read-aloud shortcut. Persisted across relaunches.
    private(set) var shortcut: HotkeyShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(self.shortcut) {
                UserDefaults.standard.set(data, forKey: Self.shortcutDefaultsKey)
            }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.shortcutDefaultsKey),
           let saved = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
        {
            self.shortcut = saved
        } else {
            self.shortcut = Self.defaultShortcut
        }
    }

    func updateShortcut(_ newShortcut: HotkeyShortcut) {
        self.shortcut = newShortcut
        DebugLogger.shared.info("Read-aloud shortcut updated: \(newShortcut.displayString)", source: "ReadAloudHotkeyService")
    }

    /// Installs global + local key monitors. Safe to call multiple times.
    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true

        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matches(event) else { return event }
            self.trigger()
            return nil // consume so the shortcut doesn't type into our own windows
        }

        DebugLogger.shared.info(
            "Read-aloud hotkey started (\(self.shortcut.displayString))",
            source: "ReadAloudHotkeyService"
        )
    }

    // MARK: - Matching & trigger

    private func handle(_ event: NSEvent) {
        guard self.matches(event) else { return }
        self.trigger()
    }

    private func matches(_ event: NSEvent) -> Bool {
        self.shortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    private func trigger() {
        Task { @MainActor in
            let tts = TTSService.shared
            if tts.playbackState == .idle {
                let started = tts.readSelection()
                DebugLogger.shared.info(
                    started ? "Read-aloud started via hotkey" : "Read-aloud hotkey: no selection captured",
                    source: "ReadAloudHotkeyService"
                )
            } else {
                tts.stop()
                DebugLogger.shared.info("Read-aloud stopped via hotkey", source: "ReadAloudHotkeyService")
            }
        }
    }
}
