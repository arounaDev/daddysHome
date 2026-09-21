import SwiftUI
import SwiftTerm
import QuartzCore
import DaddyCore

// MARK: - Terminal Surface
//
// SwiftTerm's `TerminalView` used as a **renderer only**.
//
// Deliberately not `LocalProcessTerminalView`: that class spawns and owns its
// own child process, which would give us two process paths — one in DaddyCore
// and one in the view — and DaddyCore would stop being the source of truth for
// anything on screen. Instead `SessionManager` owns the pty via `PTYProcess`,
// and this view only draws bytes and forwards keystrokes.
//
//   PTYProcess ──chunk callback──▶ Terminal.feed()   (output)
//   TerminalView ──delegate.send──▶ PTYProcess.write (input)
//   TerminalView ──delegate.sizeChanged──▶ PTYProcess.resize (TIOCSWINSZ)

struct TerminalSurface: NSViewRepresentable {
    let pty: PTYProcess

    /// Whether this surface is the one on screen. Several can be mounted at
    /// once — the shell pane keeps every tab alive — and only the visible one
    /// should hold the caret.
    var isActive = true

    /// Whether to ask the child to repaint once, after the first real resize.
    /// True only for a plain shell; see `Coordinator.scheduleFirstRedraw`.
    var redrawsOnFirstAttach = false

    /// Point size of the monospaced face. Owned by settings, not by the pane.
    var fontSize: CGFloat = 11.5

    /// Work-item text to drop into the composer once this surface is attached.
    var composerPaste: PendingComposerPaste? = nil
    var onComposerPasteConsumed: (() -> Void)? = nil

    private var terminalFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// `DaddyTheme.terminalSurface` as AppKit sees it. Same `#0d111a`, so the
    /// emulator's ground and the SwiftUI pane behind it are one flat colour
    /// with no seam where the padding ends.
    private static let surfaceColor = NSColor(
        srgbRed: 0x0d / 255, green: 0x11 / 255, blue: 0x1a / 255, alpha: 1
    )

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pty: pty,
            // Passed in rather than defaulted, because every tab's surface is
            // built in the same pass: a background tab that started out
            // "active" would grab first responder on creation and only be told
            // otherwise on the next update, by which time the deferred focus
            // has already landed in the wrong shell.
            isActive: isActive,
            redrawsOnFirstAttach: redrawsOnFirstAttach
        )
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = DroppableTerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 480),
            font: terminalFont
        )

        view.terminalDelegate = context.coordinator

        // SwiftTerm narrates every escape sequence it does not implement to
        // stdout — "Unhandled DEC Private Mode Set (DECSET) with 2031" arrives
        // several times a second, because 2031 is the colour-scheme-change
        // notification every one of these CLIs enables at startup. It is not a
        // problem with our terminal and there is nothing to act on, so it is
        // noise that buries anything we actually print.
        view.getTerminal().silentLog = true

        // Dropping a file types its path, exactly as Terminal.app and iTerm2
        // do. The agent on the other end just sees a path arrive in its input.
        view.onDropFiles = { [weak coordinator = context.coordinator] urls in
            MainActor.assumeIsolated { coordinator?.insertDroppedFiles(urls) }
        }

        // Opaque, deliberately.
        //
        // This was `.clear`, to let the panel's Liquid Glass show through. The
        // cost was invisible and enormous: SwiftTerm clears each dirty rect to
        // transparent and relies on the layer's background colour showing
        // through for default-background cells, so with a clear layer every
        // repaint punched a hole straight down to the glass — which then had to
        // re-blur an aurora that animates at 30Hz — and CoreText had no known
        // ground to antialias glyphs against.
        //
        // Glass belongs to the panels, the sidebar and the chrome. The terminal
        // is a terminal.
        view.nativeBackgroundColor = Self.surfaceColor
        view.nativeForegroundColor = NSColor.white.withAlphaComponent(0.92)
        view.caretColor = NSColor.white.withAlphaComponent(0.75)
        view.allowMouseReporting = true

        // One frame from the agent must land as one repaint, not two.
        //
        // Measured, from a 60fps capture of a Claude session being scrolled:
        // every step arrived on screen as *two* paints, the top half and then
        // the bottom half 50-67ms behind it, alternating for the whole gesture
        // (top diff 20.8 / bottom 0.05, then top 1.3 / bottom 21.2, and so on
        // for four straight seconds). Two halves of one frame, permanently out
        // of phase at an effective 15-20fps. That is what "it nudges" and
        // "reloading every inch it moves" actually were — not the agent being
        // slow, and not corruption.
        //
        // The cause is SwiftTerm's partial-repaint optimisation. On Big Sur+
        // AppKit redraws a layer-backed view in full whenever any part of it is
        // invalidated, unless the layer opts into a preserved backing store —
        // which is what `disableFullRedrawOnAnyChanges` does, stamping
        // `layer.contentsFormat = .RGBA8Uint` in `viewWillDraw`. With it
        // preserved, only the invalidated rows are repainted, so the picture is
        // only ever as correct as the invalidation was. And the invalidation is
        // computed in `updateDisplay` from `getUpdateRange()`, while the draw
        // itself happens later in the runloop — our own flush feeds more rows
        // in between, and those rows are live in the buffer but outside the
        // rect, so they wait for the *next* tick. Hence the split, every time.
        //
        // Off, every repaint redraws the whole visible grid straight from the
        // buffer, so it cannot be half a frame behind. It costs redrawing ~40
        // rows of CoreText rather than a few; AppKit still coalesces to one
        // draw per runloop pass, and SwiftTerm's own source notes AppKit sends
        // full exposes most of the time anyway.
        view.disableFullRedrawOnAnyChanges = false
        // Six times the scrollback SwiftTerm ships with.
        //
        // `TerminalOptions.default.scrollback` is 500 lines, which is about a
        // dozen screens in a pane this size — an agent that reads four files
        // and explains itself can push its own first answer out of the buffer
        // while you are still reading the last one. There is nowhere else to
        // find it: the transcript only exists in the emulator, and
        // `PTYProcess.recentOutput` keeps a 200-line tail for state detection,
        // not for you.
        //
        // Set through `changeScrollback` rather than a `TerminalOptions` at
        // construction, because it also writes `options.scrollback` — which is
        // what `resetToInitialState` rebuilds the normal buffer from, and
        // `rebindIfNeeded` calls that every time this surface is pointed at a
        // different session. Passed as an option to the initializer instead, it
        // would survive exactly until the first rebind.
        //
        // Costs nothing up front: the cap only raises `CircularList.maxLength`,
        // and lines are still allocated as the child produces them. A session
        // that actually fills all 3000 pays a few MB, and only that session.
        view.changeScrollback(3000)

        // Option is a compose/AltGr layer, not Meta.
        //
        // On non-US layouts Option is how you type characters the base layout
        // has no key for — Spanish Option+2 is "@", and without it you cannot
        // write an email address, an npm scope, or a git remote. With
        // optionAsMetaKey on, SwiftTerm takes the Meta path and sends ESC plus
        // `charactersIgnoringModifiers`, which is the *base* glyph ("2"), so
        // the composed "@" is discarded before macOS ever produces it.
        //
        // Off matches every mainstream macOS terminal's default (Terminal.app,
        // iTerm2, Ghostty) and enables SwiftTerm's AltGr path, which sends the
        // composed text directly. Meta bindings — Option+B/F word jumps and the
        // Emacs family — are the cost; Cmd+Option+O toggles this at runtime for
        // anyone who wants them back.
        view.optionAsMetaKey = false

        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        // If the pane is pointed at a different session, rebind the stream.
        context.coordinator.rebindIfNeeded(to: pty, view: view)

        // Clicking a tab should put the caret in that shell. Only the surface
        // that just became active claims focus — the others are mounted, not
        // shown, and must not fight over first responder every update.
        context.coordinator.setActive(isActive, view: view)
        context.coordinator.enableMetalIfNeeded(view)
        context.coordinator.consumeComposerPasteIfNeeded(
            composerPaste,
            view: view,
            onConsumed: onComposerPasteConsumed
        )

        // Self-heal, because the cost of this being wrong is a session you have
        // to throw away. Nothing in the app leaves mouse reporting off — the
        // scroll monitor's window is one synchronous call — so observing it off
        // here means something got away from us, and the honest response is to
        // put it back rather than let the pane stay quietly broken.
        if !view.allowMouseReporting {
            view.allowMouseReporting = true
        }

        // Guarded, because SwiftTerm's `font` setter rebuilds the font set,
        // resets every cached glyph run, drops the selection and reflows the
        // grid — which is a TIOCSWINSZ at the far end. `updateNSView` runs on
        // any observed change, so an unguarded assignment would do all of that
        // every time the agent's state badge ticked.
        if view.font.pointSize != fontSize {
            view.font = terminalFont
        }
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    /// Mutable state is only ever touched on the main actor; the one method
    /// reachable from `PTYProcess`'s background queue (`handleChunk`) does
    /// nothing but hop straight back to main.
    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        @MainActor private var pty: PTYProcess
        @MainActor private weak var view: TerminalView?
        @MainActor private var isAttached = false
        @MainActor private var controlCMonitor: Any?
        @MainActor private var scrollMonitor: Any?
        @MainActor private var mouseUpMonitor: Any?

        /// Output accumulated since the last flush. Written from the pty queue,
        /// drained on main.
        private let pendingLock = NSLock()
        private var pending = ""
        private var flushScheduled = false

        /// Identifies which pty a delivered chunk belongs to, so output from a
        /// session we have since switched away from is discarded rather than
        /// painted into the wrong terminal.
        private let generationLock = NSLock()
        private var generation: Int = 0

        /// The registration this coordinator holds on `pty`, so it can be
        /// taken back. Without it every attach left a live closure behind on a
        /// pty that outlives the view — see `detach`.
        @MainActor private var chunkToken: UUID?

        /// The size last reported to the child, and the work item that will
        /// report the next one. See `sizeChanged`.
        @MainActor private var lastReportedSize: (cols: Int, rows: Int)?
        @MainActor private var pendingResize: DispatchWorkItem?
        @MainActor private var consumedPasteID: UUID?
        @MainActor private var catchUpReveal: DispatchWorkItem?
        @MainActor private var catchUpDeadline: DispatchWorkItem?

        /// Bytes of a synchronized-output frame the agent has opened and not
        /// yet closed. See `flushPending`.
        @MainActor private var metalEnabled = false
        @MainActor private var heldFrame = ""
        @MainActor private var heldFrameRelease: DispatchWorkItem?

        private static let frameOpen = "\u{1b}[?2026h"
        private static let frameClose = "\u{1b}[?2026l"
        private static let heldFrameDeadline: TimeInterval = 0.25
        private static let heldFrameLimit = 1 << 20

        /// Splits output at the end of the last *closed* frame.
        ///
        /// Returns what is safe to draw and what must wait. With no frame open
        /// at the end everything is safe, which is the ordinary case and the
        /// one that must stay cheap.
        static func splitAtFrameBoundary(_ s: String) -> (ready: String, unclosed: String) {
            var depth = 0
            var lastClose: String.Index?
            var cursor = s.startIndex

            while cursor < s.endIndex {
                let open = s.range(of: frameOpen, range: cursor..<s.endIndex)
                let close = s.range(of: frameClose, range: cursor..<s.endIndex)

                switch (open, close) {
                case (nil, nil):
                    cursor = s.endIndex
                case (let o?, nil):
                    depth += 1
                    cursor = o.upperBound
                case (nil, let c?):
                    depth = max(0, depth - 1)
                    lastClose = c.upperBound
                    cursor = c.upperBound
                case (let o?, let c?):
                    if o.lowerBound < c.lowerBound {
                        depth += 1
                        cursor = o.upperBound
                    } else {
                        depth = max(0, depth - 1)
                        lastClose = c.upperBound
                        cursor = c.upperBound
                    }
                }
            }

            guard depth > 0 else { return (s, "") }
            guard let lastClose else { return ("", s) }
            return (String(s[..<lastClose]), String(s[lastClose...]))
        }

        /// Draws an unclosed frame anyway, once it has waited too long.
        @MainActor
        private func scheduleHeldFrameRelease(_ view: TerminalView) {
            guard heldFrameRelease == nil else { return }
            let work = DispatchWorkItem { [weak self, weak view] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.heldFrameRelease = nil
                    guard let view, !self.heldFrame.isEmpty else { return }
                    let overdue = self.heldFrame
                    self.heldFrame = ""
                    view.feed(text: overdue)
                }
            }
            heldFrameRelease = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.heldFrameDeadline,
                execute: work
            )
        }

        private let redrawsOnFirstAttach: Bool

        /// Whether this surface is the one on screen, and therefore the one
        /// entitled to the caret.
        @MainActor private var isActive: Bool

        init(
            pty: PTYProcess,
            isActive: Bool,
            redrawsOnFirstAttach: Bool
        ) {
            self.pty = MainActor.assumeIsolated { pty }
            self.isActive = MainActor.assumeIsolated { isActive }
            self.redrawsOnFirstAttach = redrawsOnFirstAttach
        }

        @MainActor
        func attach(to view: TerminalView) {
            self.view = view
            installControlCMonitor(for: view)
            installScrollMonitor(for: view)
            installMouseUpMonitor(for: view)
            guard !isAttached else { return }
            isAttached = true

            generationLock.lock()
            generation += 1
            let currentGeneration = generation
            generationLock.unlock()

            // Tell the child how big it really is, straight away.
            //
            // `PTYProcess` starts at a fixed 120×30 because the pty exists
            // before any view does. A TUI lays out its first frame against
            // whatever it is told at startup, so if the pane is a different
            // shape that frame is drawn wrong and stays wrong until something
            // else triggers a resize. `sizeChanged` only fires when the size
            // *changes*, which may be never.
            let size = view.getTerminal().getDims()
            lastReportedSize = (size.cols, size.rows)
            pty.resize(columns: UInt16(size.cols), rows: UInt16(size.rows))

            // Replay what the session already produced, so selecting a session
            // mid-flight does not show an empty pane. Hidden until the feed
            // lands at the bottom — a long Cursor transcript used to paint
            // from the first message and scroll the whole way down.
            let backlog = pty.recentOutput
            if !backlog.isEmpty {
                beginCatchUp(view)
                view.feed(text: backlog)
                snapToBottom(view)
            }

            // The chunk callback, not registerOutputCallback — the latter
            // re-sends the entire retained buffer on every write, which would
            // duplicate the whole transcript into the renderer each time.
            chunkToken = pty.registerChunkCallback { [weak self] text in
                self?.handleChunk(text, generation: currentGeneration)
            }

            scheduleFirstRedraw()

            if isActive { takeKeyboardFocus(view) }

            // Deferred for the same reason focus is: there is no window yet
            // when the view is first made, and Metal needs one.
            DispatchQueue.main.async { [weak self, weak view] in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.enableMetalRenderer(view)
                }
            }
        }

        /// One Ctrl-L, once, to a child that has only just started.
        ///
        /// The pty exists before any view does, so it launches at a fixed
        /// 120×30 and the shell prints its prompt at that width — a powerline
        /// prompt in a 55-column pane arrives wrapped across two lines with the
        /// caret stranded below it. The resize above fixes the *geometry*, but
        /// nothing unprints what has already been drawn.
        ///
        /// zsh, bash and fish all bind Ctrl-L to clear-and-redraw, which does
        /// both: the mis-wrapped fragment goes, the prompt comes back at the
        /// right width. `consumeFreshLaunchRedraw` returns true exactly once per
        /// launch, so this can never fire over output worth keeping.
        ///
        /// Delayed, because a login shell is still sourcing `.zprofile` and
        /// `.zshrc` at this point and zle is not yet reading. A quarter of a
        /// second is long past that and still before anyone has typed.
        ///
        /// **Shells only.** To a TUI agent Ctrl-L is not a redraw — they bind it
        /// themselves, and Claude Code treats it as clear-the-conversation — so
        /// `redrawsOnFirstAttach` is false everywhere except the shell pane.
        @MainActor
        private func scheduleFirstRedraw() {
            guard redrawsOnFirstAttach, pty.consumeFreshLaunchRedraw() else { return }
            let target = pty
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                try? target.write("\u{0c}")
            }
        }

        @MainActor
        func setActive(_ active: Bool, view: TerminalView) {
            guard active != isActive else { return }
            isActive = active
            if active {
                takeKeyboardFocus(view)
            } else if view.window?.firstResponder === view {
                // Nil is how the whole window stopped taking keys. Cursor's
                // mouse-reporting also skips `becomeFirstResponder` on click,
                // so a nil first responder is a session you cannot type into
                // and cannot click back into.
                view.window?.makeFirstResponder(view.window?.contentView)
            }
        }

        /// Hide the emulator while a dump or a SIGWINCH reflow paints, then
        /// reveal the last screen. Cursor redraws a long chat from the top;
        /// without this you watch every message scroll past.
        @MainActor
        private func beginCatchUp(_ view: TerminalView) {
            view.alphaValue = 0
            catchUpReveal?.cancel()
            catchUpDeadline?.cancel()
            let deadline = DispatchWorkItem { [weak self, weak view] in
                MainActor.assumeIsolated { self?.endCatchUp(view) }
            }
            catchUpDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: deadline)
            bumpCatchUpReveal(view)
        }

        @MainActor
        private func bumpCatchUpReveal(_ view: TerminalView) {
            guard view.alphaValue == 0 else { return }
            catchUpReveal?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                MainActor.assumeIsolated { self?.endCatchUp(view) }
            }
            catchUpReveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        @MainActor
        private func endCatchUp(_ view: TerminalView?) {
            catchUpReveal?.cancel()
            catchUpReveal = nil
            catchUpDeadline?.cancel()
            catchUpDeadline = nil
            guard let view else { return }
            snapToBottom(view)
            view.alphaValue = 1
        }

        @MainActor
        private func snapToBottom(_ view: TerminalView) {
            view.scrollTo(row: Int.max)
        }

        @MainActor
        private func cancelCatchUp() {
            catchUpReveal?.cancel()
            catchUpReveal = nil
            catchUpDeadline?.cancel()
            catchUpDeadline = nil
            view?.alphaValue = 1
        }

        /// Draw the grid on the GPU instead of rasterising it with CoreText.
        ///
        /// The frame-gating fix made every paint a whole, coherent frame — but
        /// measured on the capture, a whole-screen repaint costs two to four
        /// vsync intervals (gaps of 33/50/67ms, never 16), while a paint that
        /// only touches a line or two holds a clean 60fps. That is the shape of
        /// a CPU-bound rasteriser: `buildAttributedString` runs per row, per
        /// paint, with no cache, so ~50 rows of CoreText blows a 16.67ms budget
        /// and the scroll settles at ~18fps.
        ///
        /// SwiftTerm's Metal renderer rasterises glyphs once into a texture
        /// atlas and draws cells as GPU quads, which is what makes a full-grid
        /// repaint affordable at all. Failure is not interesting — the
        /// CoreGraphics path stays exactly as it was — so it is not propagated.
        @MainActor
        func enableMetalIfNeeded(_ view: TerminalView) { enableMetalRenderer(view) }

        @MainActor
        private func enableMetalRenderer(_ view: TerminalView) {
            guard !metalEnabled, view.window != nil else { return }
            do {
                try view.setUseMetal(true)
                metalEnabled = true
            } catch {
                metalEnabled = false
            }
        }

        /// Puts the caret in the terminal, since that is where you talk to the
        /// agent. Deferred by one turn because the view is not in a window yet
        /// when it is first made.
        @MainActor
        private func takeKeyboardFocus(_ view: TerminalView) {
            // Spelled out as `@MainActor @Sendable` rather than left to
            // inference. That is exactly the type `DispatchQueue.main`'s
            // `execute:` takes, and an inferred closure is neither, so every
            // hand-off warned about a data race that was not there — the body
            // only ever ran on main. Declaring the type also makes the
            // `MainActor.assumeIsolated` wrapper that used to be inside
            // unnecessary: the closure is isolated now, not merely asserting
            // that it is.
            let hop: @MainActor @Sendable () -> Void = { [weak view] in
                guard let view, view.window != nil else { return }
                view.window?.makeFirstResponder(view)
            }
            DispatchQueue.main.async(execute: hop)
            // Board cover is gone on the next turn; one hop is sometimes still
            // under the outgoing view.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: hop)
        }

        /// Called on `PTYProcess`'s private serial queue.
        ///
        /// Chunks are accumulated and handed over on the **next turn of the
        /// main runloop** — coalesced, but not delayed.
        ///
        /// Batching matters: a TUI redrawing its viewport emits a burst of small
        /// writes, and one `feed` per write is one parse and one repaint request
        /// each. Everything that arrives before the flush runs is merged into a
        /// single feed.
        ///
        /// **The delay is what had to go.** This used to hold chunks for a
        /// sixtieth of a second before feeding them, on the theory that a
        /// terminal should not repaint faster than the screen. But SwiftTerm
        /// already coalesces at exactly 60Hz — `queuePendingDisplay` starts its
        /// countdown when the bytes arrive and refuses to paint inside a
        /// synchronized-output frame — so ours was a second clock running at the
        /// same rate, started from a different instant. Two 60Hz clocks in
        /// arbitrary phase do not halve the work; they beat against each other,
        /// and a paint that lands between two halves of a frame we ourselves
        /// split shows half of the old frame and half of the new. Which is what
        /// tearing is. The only clock now is SwiftTerm's, and it starts counting
        /// the moment the bytes get there.
        private func handleChunk(_ text: String, generation incoming: Int) {
            generationLock.lock()
            let isCurrent = incoming == generation
            generationLock.unlock()
            guard isCurrent else { return }

            pendingLock.lock()
            pending += text
            let alreadyScheduled = flushScheduled
            flushScheduled = true
            pendingLock.unlock()

            guard !alreadyScheduled else { return }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.flushPending() }
            }
        }

        @MainActor
        private func flushPending() {
            pendingLock.lock()
            let text = pending
            pending = ""
            flushScheduled = false
            pendingLock.unlock()

            guard !text.isEmpty, let view else { return }

            // Never hand the emulator half a frame.
            //
            // Photographed, at 60fps: a row reading "…adipiscing p" followed by
            // "i ut tincidunt orci quis…" — the left of the row rewritten and
            // the right still holding the tail of what used to be there, then
            // correct again 33ms later. That is not stale pixels and not a wrap
            // bug. It is the agent's redraw caught in the middle, painted, and
            // finished afterwards.
            //
            // Claude Code brackets every redraw in DECSET 2026 precisely so a
            // terminal can avoid this (confirmed in the 2.1.241 binary, which
            // emits `[?2026h` and `[?2026l`), and SwiftTerm does suppress its
            // own painting while a frame is open. But suppression is a race:
            // every paint request resolves at the end of the runloop, and any
            // feed landing in between reopens a frame behind its back.
            //
            // So the frame boundary is enforced one level lower, where it is
            // not a race — the bytes. Everything up to the last *closed* frame
            // is fed; an unclosed one is held until its `[?2026l` arrives. The
            // emulator therefore never holds a partially drawn frame at all, so
            // no paint from any path can show one.
            let combined = heldFrame + text
            heldFrame = ""
            var (ready, unclosed) = Self.splitAtFrameBoundary(combined)

            if unclosed.isEmpty {
                heldFrameRelease?.cancel()
                heldFrameRelease = nil
            } else if unclosed.utf8.count > Self.heldFrameLimit {
                // Too big to be a frame any more — something is streaming
                // without ever closing it. Draw it rather than hoard it, in
                // order, as part of this same feed.
                ready += unclosed
                unclosed = ""
                heldFrameRelease?.cancel()
                heldFrameRelease = nil
            } else {
                // A frame that never closes must not freeze the pane. SwiftTerm's
                // own escape hatch is a full second; a quarter of that is still
                // far longer than any real frame takes to arrive and short enough
                // to read as a hitch rather than a hang.
                heldFrame = unclosed
                scheduleHeldFrameRelease(view)
            }

            guard !ready.isEmpty else { return }

            if view.alphaValue == 0 { bumpCatchUpReveal(view) }

            // Through the **view**, never `view.getTerminal().feed(...)`.
            //
            // `TerminalView.feed(text:)` is `feedPrepare()` → `terminal.feed`
            // → `feedFinish()`, and `feedFinish` is the only output-driven
            // repaint scheduler SwiftTerm has: `displayImmediately()` when the
            // user has just typed — `TerminalView.send(data:)` stamps that
            // window before our delegate ever sees the keystroke — and
            // `queuePendingDisplay()` otherwise, which invalidates only the
            // rows `getUpdateRange()` marked dirty, coalesces at 60Hz, and
            // holds off inside a DECSET 2026 synchronized-output frame.
            //
            // Feeding the emulator directly skips both halves, so output
            // scheduled *no repaint at all*. What used to stand in for it was
            // a hand-rolled `view.setNeedsDisplay(view.bounds)` per flush,
            // latched off for agents that announce 2026 frames — which meant a
            // plain shell, announcing none and opting out of the manual
            // repaint, never painted on its own at all, and Claude, announcing
            // them, was left depending on `synchronizedOutputChanged` alone:
            // that queues a paint 16.67ms out, and `updateDisplay` returns
            // early — clearing `pendingDisplay` without re-queuing — if the
            // next frame opens inside the window. Under sustained output those
            // paints are dropped and rows keep stale pixels.
            //
            // So there is no repaint code here any more. There should not be.
            view.feed(text: ready)
        }

        @MainActor
        func rebindIfNeeded(to newPTY: PTYProcess, view: TerminalView) {
            guard newPTY !== pty else { return }

            // Anything buffered belongs to the session being left behind, and
            // so does the registration on it.
            pendingLock.lock()
            pending = ""
            pendingLock.unlock()

            if let chunkToken {
                pty.removeChunkCallback(chunkToken)
                self.chunkToken = nil
            }

            heldFrame = ""
            heldFrameRelease?.cancel()
            heldFrameRelease = nil

            cancelCatchUp()

            pty = newPTY
            isAttached = false
            lastReportedSize = nil
            view.getTerminal().resetToInitialState()
            attach(to: view)
        }

        @MainActor
        func detach() {
            // The pty outlives the view — an agent keeps running while you look
            // at another one — so a registration left behind here is a closure
            // that appends to a string and schedules a main-queue hop for every
            // chunk, forever, once per time this surface was ever built.
            if let chunkToken {
                pty.removeChunkCallback(chunkToken)
                self.chunkToken = nil
            }

            pendingResize?.cancel()
            pendingResize = nil
            heldFrameRelease?.cancel()
            heldFrameRelease = nil
            heldFrame = ""
            cancelCatchUp()

            view = nil
            if let controlCMonitor {
                NSEvent.removeMonitor(controlCMonitor)
                self.controlCMonitor = nil
            }
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
                self.scrollMonitor = nil
            }
            if let mouseUpMonitor {
                NSEvent.removeMonitor(mouseUpMonitor)
                self.mouseUpMonitor = nil
            }
        }

        /// The wheel scrolls *our* scrollback unless the child owns the screen.
        ///
        /// SwiftTerm's `scrollWheel` asks whether mouse reporting is on before
        /// it asks which buffer is active, so any child that turns mouse
        /// tracking on takes the wheel with it — including ones that print
        /// normally and leave a scrollback behind them. Scrolling back through
        /// what such an agent said did nothing at all, because the events were
        /// going to a program that had not asked to be scrolled.
        ///
        /// In the alternate screen there is no scrollback of ours to move and
        /// the child is drawing the whole viewport itself, so there the wheel is
        /// genuinely its business — Claude Code runs there with full mouse
        /// tracking (`?1049h ?1000h ?1002h ?1003h ?1006h`) and keeps every
        /// event. Everywhere else the terminal scrolls, which is what
        /// Terminal.app, iTerm2 and Ghostty all do.
        ///
        /// Done from a monitor rather than an override because SwiftTerm's
        /// `scrollWheel` is `public`, not `open`. The flag is put back on the
        /// next turn of the runloop, by which time this one event has been
        /// dispatched.
        /// Puts mouse reporting back after any drag, wherever it ended.
        ///
        /// A selection drag that leaves the pane is the one gesture that still
        /// reproduces the stuck state, and the difference is not the selection
        /// — it is where the mouse was when the buttons came up. AppKit routes
        /// a drag's events to the view that received the press, but only while
        /// it keeps routing them: a release over another window, another app,
        /// or off the screen edge can land somewhere this surface never hears
        /// about, and any state that was supposed to be restored on the way out
        /// simply is not.
        ///
        /// So the restore is repeated somewhere it cannot be missed. This is a
        /// repair, not a policy — nothing in the app leaves mouse reporting
        /// off, so if this ever fires, something got away from us. It says so
        /// in debug builds, because "the pane went slow an hour ago" is not a
        /// bug report anyone can act on.
        @MainActor
        private func installMouseUpMonitor(for view: TerminalView) {
            guard mouseUpMonitor == nil else { return }
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
            ) { [weak self, weak view] event in
                guard let self, self.isActive, let view, event.window === view.window else { return event }
                if !view.allowMouseReporting {
                    view.allowMouseReporting = true
                    #if DEBUG
                    print("Daddy: repaired stuck allowMouseReporting after a drag")
                    #endif
                }
                return event
            }
        }

        @MainActor
        private func installScrollMonitor(for view: TerminalView) {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self, weak view] event in
                guard let self, self.isActive, let view, event.window === view.window else { return event }

                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }

                // Scrolling ends an alternate-screen selection.
                //
                // A drag that leaves the pane is the gesture that strands one:
                // the mouse comes up somewhere this surface may never hear
                // about, and the selection is left active with nothing to
                // retire it. SwiftTerm's own policy is that an alternate-screen
                // selection does not survive output — `feedPrepare` clears it
                // and `linefeed` calls `selectNone` — but both are guarded on
                // `allowMouseReporting`, so a selection can outlive the moment
                // that was supposed to end it and then costs work on every
                // frame for the rest of the session.
                //
                // The alternate screen has no scrollback of ours, and its
                // contents are rewritten wholesale by the agent, so a selection
                // held across a scroll refers to text that no longer exists. It
                // is not something worth preserving, and dropping it here is
                // both what the emulator already wants and a point the gesture
                // cannot slip past. A selection you made is still yours to copy
                // — right up until you scroll away from it.
                if view.getTerminal().isCurrentBufferAlternate,
                   view.selection?.active == true {
                    view.selectNone()
                }

                guard view.allowMouseReporting,
                      !view.getTerminal().isCurrentBufferAlternate
                else { return event }

                // Dispatched by hand, so the flag is restored on the same call
                // stack that cleared it.
                //
                // This used to clear the flag, return the event for AppKit to
                // deliver, and restore it on a later turn of the runloop. That
                // restore is a promise made to a global: miss it once — the
                // block lost, reordered behind another that reads the flag,
                // the surface torn down mid-flight — and mouse reporting is off
                // for the rest of the session, with nothing anywhere to turn it
                // back on. Its symptoms do not look like a scroll bug at all,
                // which is what makes it expensive: `feedPrepare` and
                // `linefeed` both clear the selection only `if
                // allowMouseReporting`, so a highlight suddenly survives output
                // forever, and `scrollWheel` stops reporting the wheel and
                // falls into its alternate-screen branch, which sends arrow
                // keys instead — a slower, coarser scroll that no amount of
                // clicking recovers.
                //
                // Calling `scrollWheel` directly makes the window in which the
                // flag is false exactly one synchronous call long. Nothing can
                // observe it, and there is no restore left to lose. The event
                // is swallowed afterwards because it has already been handled.
                view.allowMouseReporting = false
                view.scrollWheel(with: event)
                view.allowMouseReporting = true
                return nil
            }
        }

        /// Observe the original AppKit key event while this terminal is first
        /// responder. SwiftTerm's `keyDown` implementation is not open to
        /// subclassing, and inspecting its delegate bytes is too late once a
        /// TUI has enabled Kitty/CSI-u keyboard reporting.
        @MainActor
        private func installControlCMonitor(for view: TerminalView) {
            guard controlCMonitor == nil else { return }
            controlCMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self, weak view] event in
                guard let self, self.isActive, view?.window?.firstResponder === view else { return event }

                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let isPlainControl = modifiers.contains(.control)
                    && !modifiers.contains(.command)
                    && !modifiers.contains(.option)
                if isPlainControl,
                   event.charactersIgnoringModifiers?.lowercased() == "c" {
                    self.noteControlCInput()
                }
                return event
            }
        }

        // MARK: Dropped files

        /// Types the dropped paths into the agent, the way a terminal does.
        ///
        /// Paths are backslash-escaped even though the receiver is a TUI input
        /// box rather than a shell. That is deliberate: it is byte-for-byte
        /// what these CLIs receive when someone drags a file into iTerm2 or
        /// Terminal.app, so it is the form they are all written against. A path
        /// with nothing special in it comes through untouched either way.
        @MainActor
        func insertDroppedFiles(_ urls: [URL]) {
            guard !urls.isEmpty else { return }

            // Trailing space so the next word you type is a new one.
            let paths = urls.map { Self.escaped($0.path) }.joined(separator: " ") + " "

            // Wrapped as a paste when the agent asked for bracketed paste, so a
            // path is delivered as one pasted unit instead of a burst of
            // keystrokes its input handler has to interpret one at a time.
            let payload: String
            if view?.getTerminal().bracketedPasteMode == true {
                payload = "\u{1b}[200~" + paths + "\u{1b}[201~"
            } else {
                payload = paths
            }

            try? pty.write(payload)
        }

        /// A work item's prompt, as one paste, not a burst of keystrokes.
        ///
        /// Newlines in these prompts are the freeze: without bracketed paste
        /// each `\n` is a submit (or a full TUI redraw), and doing that while
        /// the emulator is mid-attach leaves the pane dead except for Close.
        @MainActor
        func consumeComposerPasteIfNeeded(
            _ pending: PendingComposerPaste?,
            view: TerminalView,
            onConsumed: (() -> Void)?
        ) {
            guard let pending,
                  consumedPasteID != pending.id,
                  isAttached,
                  isActive,
                  view.window != nil
            else { return }

            consumedPasteID = pending.id
            onConsumed?()
            let payload = "\u{1b}[200~" + pending.text + "\u{1b}[201~"
            DispatchQueue.main.async { [weak self, weak view] in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    try? self.pty.write(payload)
                    self.takeKeyboardFocus(view)
                }
            }
        }

        /// Capture intent before SwiftTerm turns the key into legacy, Kitty, or
        /// CSI-u bytes. The PTY still receives SwiftTerm's original encoding;
        /// this only annotates a subsequent process exit for UI cleanup.
        @MainActor
        private func noteControlCInput() {
            pty.noteInterruptInput()
        }

        /// Characters a shell would otherwise act on. Spelled out one per
        /// entry rather than as a string literal, because a literal is exactly
        /// where a stray `\t` stops meaning tab and starts meaning "escape
        /// every letter t in the path".
        private static let escapees: Set<Character> = [
            " ", "\t", "\n", "\"", "'", "`", "\\", "$", "&", "|", ";",
            "<", ">", "(", ")", "[", "]", "{", "}", "*", "?", "!", "#", "~", "^",
        ]

        private static func escaped(_ path: String) -> String {
            var out = ""
            out.reserveCapacity(path.count)
            for character in path {
                if escapees.contains(character) { out.append("\\") }
                out.append(character)
            }
            return out
        }

        // MARK: TerminalViewDelegate

        // The view always calls its delegate on the main thread, but the
        // protocol is not annotated, hence the explicit assumption.

        /// Keystrokes from the view go into the pty.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let text = String(bytes: data, encoding: .utf8) else { return }
            MainActor.assumeIsolated { try? pty.write(text) }
        }

        /// The child needs to know the new geometry or it will not re-wrap —
        /// but only once it has stopped changing.
        ///
        /// Every pane in the workspace is positioned by hand and animated, so a
        /// single toggle in or out of focus mode walks both terminals through a
        /// dozen intermediate widths over 300ms. Passed straight through, each
        /// one is a `TIOCSWINSZ`, a `SIGWINCH` and a full reflow at the far end
        /// — of a geometry that is already out of date by the time the TUI has
        /// finished laying out for it. Coalesced, an animation costs exactly one
        /// resize, at the size it settles on.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                // A 0-column pty is how every live session died when the
                // fleet was laid out hidden: SwiftUI proposed an empty
                // frame, SwiftTerm reported it, and we forwarded a
                // TIOCSWINSZ the child cannot survive.
                guard newCols > 1, newRows > 1 else { return }

                guard lastReportedSize?.cols != newCols
                    || lastReportedSize?.rows != newRows
                else { return }

                pendingResize?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.pendingResize = nil
                        self.lastReportedSize = (newCols, newRows)
                        self.pty.resize(columns: UInt16(newCols), rows: UInt16(newRows))
                    }
                }
                pendingResize = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        func clipboardRead(source: TerminalView) -> Data? {
            NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
