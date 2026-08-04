//
//  SelectionCopyCapture.swift
//  FluidChat (FluidVoice fork)
//
//  Clipboard-sentinel selection capture (ported from VoiceAssist's proven
//  pattern). Used as the last-resort fallback when Accessibility APIs can't
//  read the highlighted text: plant a sentinel on the clipboard, simulate
//  Cmd+C, watch the clipboard change, then restore the previous contents.
//

import AppKit
import Foundation

enum SelectionCopyCapture {
    /// Attempts to capture the current selection by simulating a copy.
    /// Must be called on the main thread. Blocks briefly (max ~600 ms) while
    /// the target app processes the copy.
    static func capture() -> String? {
        let pasteboard = NSPasteboard.general
        let sentinel = "fluidchat-readaloud-sentinel-\(UUID().uuidString)"
        let previousText = pasteboard.string(forType: .string)

        // Plant the sentinel so we can tell "copy produced nothing" apart from
        // "clipboard didn't change".
        pasteboard.clearContents()
        pasteboard.setString(sentinel, forType: .string)
        let sentinelChangeCount = pasteboard.changeCount

        // Simulate Cmd+C into the frontmost app.
        postCopyCommand()

        // Give the target app a moment to service the copy.
        var captured: String?
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            guard pasteboard.changeCount != sentinelChangeCount else { continue }
            if let contents = pasteboard.string(forType: .string), contents != sentinel, !contents.isEmpty {
                captured = contents
            }
            break
        }

        // Restore the user's previous clipboard (MVP: text only; rich
        // clipboard types are not preserved yet).
        pasteboard.clearContents()
        if let previousText {
            pasteboard.setString(previousText, forType: .string)
        }

        if let captured {
            DebugLogger.shared.info("Selection captured via clipboard sentinel (chars=\(captured.count))", source: "SelectionCopyCapture")
        } else {
            DebugLogger.shared.info("Clipboard sentinel capture found no selection", source: "SelectionCopyCapture")
        }
        return captured
    }

    private static func postCopyCommand() {
        let source = CGEventSource(stateID: .hidSystemState)
        // kVK_ANSI_C = 0x08
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
