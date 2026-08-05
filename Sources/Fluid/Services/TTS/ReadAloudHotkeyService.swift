//
//  ReadAloudHotkeyService.swift
//  FluidChat (FluidVoice fork)
//
//  Lightweight global hotkey for read-aloud, deliberately separate from
//  GlobalHotkeyManager (which is a dictation-specific hold-mode state
//  machine). ⌃R always reads the current selection (taking over mid-
//  playback); with nothing highlighted it stops the current read.
//  Pause/resume/replay live on the playback pill.
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

    /// Phase 5 queue reading: Control + Shift + R adds the highlighted
    /// passage to the listening queue instead of taking over playback.
    static let defaultQueueShortcut = HotkeyShortcut(keyCode: 15, modifierFlags: [.control, .shift])
    private static let queueShortcutDefaultsKey = "tts.queueReadAloudShortcut"

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

    /// The active queue-reading shortcut. Persisted across relaunches.
    private(set) var queueShortcut: HotkeyShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(self.queueShortcut) {
                UserDefaults.standard.set(data, forKey: Self.queueShortcutDefaultsKey)
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
        if let data = UserDefaults.standard.data(forKey: Self.queueShortcutDefaultsKey),
           let saved = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
        {
            self.queueShortcut = saved
        } else {
            self.queueShortcut = Self.defaultQueueShortcut
        }
    }

    func updateShortcut(_ newShortcut: HotkeyShortcut) {
        self.shortcut = newShortcut
        DebugLogger.shared.info("Read-aloud shortcut updated: \(newShortcut.displayString)", source: "ReadAloudHotkeyService")
    }

    func updateQueueShortcut(_ newShortcut: HotkeyShortcut) {
        self.queueShortcut = newShortcut
        DebugLogger.shared.info("Queue-read shortcut updated: \(newShortcut.displayString)", source: "ReadAloudHotkeyService")
    }

    /// Installs global + local key monitors. Safe to call multiple times.
    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true

        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.matchesQueue(event) {
                self.triggerQueue()
                return nil // consume so the shortcut doesn't type into our own windows
            }
            if self.matches(event) {
                self.trigger()
                return nil
            }
            return event
        }

        DebugLogger.shared.info(
            "Read-aloud hotkey started (\(self.shortcut.displayString))",
            source: "ReadAloudHotkeyService"
        )
    }

    // MARK: - Matching & trigger

    private func handle(_ event: NSEvent) {
        // Queue shortcut checked first: ⌃⇧R is a strict superset of ⌃R's
        // modifiers (matching is exact, but keep the order explicit).
        if self.matchesQueue(event) {
            self.triggerQueue()
            return
        }
        guard self.matches(event) else { return }
        self.trigger()
    }

    private func matches(_ event: NSEvent) -> Bool {
        self.shortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    private func matchesQueue(_ event: NSEvent) -> Bool {
        self.queueShortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    private func trigger() {
        Task { @MainActor in
            let tts = TTSService.shared
            // ⌃R always means "read what's highlighted now". A fresh
            // selection takes over even mid-playback; only when nothing is
            // highlighted does it fall back to stopping the current read.
            if tts.readSelection() {
                DebugLogger.shared.info("Read-aloud started via hotkey", source: "ReadAloudHotkeyService")
            } else if tts.playbackState != .idle {
                tts.stop()
                DebugLogger.shared.info("Read-aloud stopped via hotkey (no selection)", source: "ReadAloudHotkeyService")
            } else {
                DebugLogger.shared.info("Read-aloud hotkey: no selection captured", source: "ReadAloudHotkeyService")
            }
        }
    }

    /// ⌃⇧R: add the highlighted passage to the listening queue. Never stops
    /// or interrupts — with no selection it simply does nothing.
    private func triggerQueue() {
        Task { @MainActor in
            let tts = TTSService.shared
            if tts.enqueueSelection() {
                DebugLogger.shared.info("Queue: passage added via hotkey", source: "ReadAloudHotkeyService")
            } else {
                DebugLogger.shared.info("Queue hotkey: no selection captured", source: "ReadAloudHotkeyService")
            }
        }
    }
}
