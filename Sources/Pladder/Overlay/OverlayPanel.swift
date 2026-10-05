import AppKit
import SwiftUI
import PladderCore

/// Borderless floating panel that shows dictation status without ever taking
/// focus away from the app the user is typing into.
///
/// The combination that makes this work: `.nonactivatingPanel` so ordering the
/// window front does not activate Pladder, `canBecomeKey == false` so it never
/// becomes the key window, and `ignoresMouseEvents` so clicks fall through to
/// whatever is underneath.
final class OverlayPanel: NSPanel {
    /// Includes room around the capsule for its soft shadow and for the
    /// widest error message; the window itself draws nothing, so nothing is
    /// clipped and the pill sizes itself to its content inside this box. A
    /// smaller pill (Minimal) just centres in the invisible box, and every
    /// style has to fit the error row, so only the live transcript — which
    /// needs room for its text — asks for more.
    private static func size(for style: OverlayStyle) -> NSSize {
        switch style {
        case .liveTranscript: NSSize(width: 480, height: 190)
        case .menuBar, .minimal, .compact: NSSize(width: 320, height: 96)
        }
    }

    /// How long the pill takes to fade out when it does not fly. Flightless
    /// hides — the clipboard hint, an error — use the plain fade; the
    /// controller waits it out before it resets the model, so the last
    /// content stays on screen for the whole fade.
    static let fadeOutDuration: TimeInterval = 0.25

    /// How far below its resting frame the panel starts (and dives back to),
    /// so the pill enters and leaves through the screen's bottom edge. The
    /// pill never sits higher than the panel's top, which is 64 pt above the
    /// screen bottom, and it draws its own shadow.
    private static func flightDistance(for height: CGFloat) -> CGFloat { height + 80 }

    private let model: OverlayModel

    /// Bumped on every show/hide so a fade-out that is superseded by a new
    /// show does not order the window out afterwards.
    private var generation = 0

    init(model: OverlayModel) {
        self.model = model
        let size = Self.size(for: model.style)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        // The capsule draws its own shadow. A window shadow on a transparent
        // panel is computed from the window's rectangle and shows up as a faint
        // box around the pill.
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        contentView = host

        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(flight: Bool, onArrival: (@MainActor @Sendable () -> Void)? = nil) {
        generation &+= 1
        let token = generation
        // A borderless panel that is never key or main does not reliably
        // inherit an appearance changed through `NSApp.appearance` after it
        // was created, so re-sync on every show. The settings window restyles
        // itself; the panel only exists between its appearances.
        appearance = NSApp.appearance
        let final = targetFrame()
        alphaValue = 1
        // `orderFrontRegardless` avoids requiring Pladder to be active, which
        // an accessory app never is.
        if flight {
            // Start fully below the bottom edge — the window is clipped
            // there, so nothing flashes — and slide up to rest. The pill is
            // always opaque; the disc-to-style morph is SwiftUI's job once
            // the slide lands.
            setFrame(final.offsetBy(dx: 0, dy: -Self.flightDistance(for: final.height)), display: false)
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = model.speed.flightDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(final, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    onArrival?()
                }
            })
        } else {
            // A dive that is still running keeps driving the frame after a
            // plain `setFrame`, so the panel would finish below the screen
            // edge with the hint on it. Only an animated frame supersedes
            // it: the clipboard hint or an error arriving mid-dive brings the
            // pill back up inside the fade.
            let diving = isVisible && frame != final
            if !diving { setFrame(final, display: false) }
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                if diving { animator().setFrame(final, display: true) }
                animator().alphaValue = 1
            }
        }
    }

    func hide(flight: Bool) {
        generation &+= 1
        let token = generation
        if flight {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = model.speed.flightDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().setFrame(
                    frame.offsetBy(dx: 0, dy: -Self.flightDistance(for: frame.height)),
                    display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.orderOut(nil)
                }
            })
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeOutDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // AppKit runs this on the main thread, but types it as @Sendable.
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.orderOut(nil)
                }
            }
        }
    }

    /// Bottom-centre of whichever screen the pointer is on, so the pill shows up
    /// where the user is looking on a multi-display setup.
    private func targetFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return self.frame }
        // The style can change between showings; the hosting view's
        // autoresizing mask follows `setFrame`.
        let size = Self.size(for: model.style)
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.minY + 64,
            width: size.width,
            height: size.height
        )
    }
}
