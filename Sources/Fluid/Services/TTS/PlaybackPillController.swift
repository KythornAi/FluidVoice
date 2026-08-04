//
//  PlaybackPillController.swift
//  FluidChat (FluidVoice fork)
//
//  Owns the floating playback pill window. Mirrors the bottom-overlay window
//  pattern (borderless non-activating NSPanel, floating level, joins all
//  spaces) but stays deliberately small — the pill is a read-aloud companion,
//  not a session surface, so it never steals focus and parks itself top-right.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class PlaybackPillController {
    static let shared = PlaybackPillController()

    private var window: NSPanel?
    private var stateSubscription: AnyCancellable?

    private init() {}

    /// Subscribes to the given TTSService's playback state. Safe to call
    /// multiple times. The service is passed in rather than read from
    /// `TTSService.shared` because `start` is called *from* that singleton's
    /// own initializer — touching `shared` there deadlocks dispatch_once.
    func start(observing service: TTSService) {
        guard self.stateSubscription == nil else { return }
        self.stateSubscription = service.$playbackState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .speaking, .paused:
                    self?.show()
                case .idle:
                    self?.hide()
                }
            }
    }

    // MARK: - Show / hide

    private func show() {
        if self.window == nil {
            self.createWindow()
        }
        self.positionWindow()
        self.window?.orderFrontRegardless()
    }

    private func hide() {
        self.window?.orderOut(nil)
    }

    // MARK: - Window

    private func createWindow() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI handles shadow
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: PlaybackPillView())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.sizingOptions = [.preferredContentSize]

        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)

        self.window = panel
    }

    /// Parks the pill at the top-right of the screen under the pointer, clear
    /// of the notch overlay (top-center) and dictation bar (bottom-center).
    private func positionWindow() {
        guard let window else { return }
        let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let margin: CGFloat = 12
        let origin = NSPoint(
            x: frame.maxX - window.frame.width - margin,
            y: frame.maxY - window.frame.height - margin
        )
        window.setFrameOrigin(origin)
    }
}
