// Native Right-Command hotkey detection via CGEventTap.
//
// Replaces the Hammerspoon eventtap loop. Same UX:
//
//   * HOLD Right-⌘           → start recording (PTT). Release = stop.
//   * Quick tap-tap Right-⌘  → toggle-LOCK. Recording stays on. Tap again to stop.
//   * ⌃⌥⌘Escape              → cancel without finalizing.
//
// Requires Input Monitoring permission (separate TCC bucket from Accessibility).
// macOS shows the prompt the first time CGEventTap is enabled.

import AppKit
import CoreGraphics
import Foundation

final class HotkeyMonitor {
    enum Event {
        case startRecording
        case stopRecording
        case cancelRecording
        case lockEngaged   // diagnostic: double-tap detected
    }

    var onEvent: ((Event) -> Void)?

    private let KEY_RIGHT_CMD: Int64 = 54
    private let KEY_ESCAPE: Int64 = 53
    private let HOLD_THRESHOLD: TimeInterval = 0.25
    private let DOUBLE_TAP_WINDOW: TimeInterval = 0.35

    private enum HotkeyState {
        case idle
        case recHold
        case recLocked
        case tapPending
    }

    private var state: HotkeyState = .idle
    private var rcmdDown: Bool = false
    private var pressedAt: Date = .distantPast
    private var pendingStopWork: DispatchWorkItem?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() throws {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(event: event, type: type)
                return Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            throw NSError(domain: "HotkeyMonitor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "CGEventTap creation failed — grant Input Monitoring in System Settings → Privacy & Security → Input Monitoring"
            ])
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    var onLog: ((String) -> Void)?

    private func handle(event: CGEvent, type: CGEventType) {
        if type == .keyDown {
            handleKeyDown(event)
            return
        }
        if type == .flagsChanged {
            handleFlagsChanged(event)
            return
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == KEY_ESCAPE else { return }

        let flags = event.flags
        let isControl  = flags.contains(.maskControl)
        let isAlt      = flags.contains(.maskAlternate)
        let isCommand  = flags.contains(.maskCommand)

        if isControl && isAlt && isCommand {
            cancelPending()
            state = .idle
            emit(.cancelRecording)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        onLog?("flagsChanged keyCode=\(keyCode)")
        guard keyCode == KEY_RIGHT_CMD else { return }

        let isDown = event.flags.contains(.maskCommand)
        guard isDown != rcmdDown else {
            onLog?("right-cmd duplicate state ignored down=\(isDown)")
            return
        }
        rcmdDown = isDown
        let now = Date()

        if rcmdDown {
            // PRESS
            switch state {
            case .idle:
                pressedAt = now
                state = .recHold
                emit(.startRecording)
            case .tapPending:
                cancelPending()
                state = .recLocked
                emit(.lockEngaged)
            case .recLocked:
                state = .idle
                emit(.stopRecording)
            case .recHold:
                // double-press without release; ignore
                break
            }
        } else {
            // RELEASE
            if state == .recHold {
                let heldFor = now.timeIntervalSince(pressedAt)
                if heldFor < HOLD_THRESHOLD {
                    state = .tapPending
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        if self.state == .tapPending {
                            self.state = .idle
                            self.emit(.stopRecording)
                        }
                        self.pendingStopWork = nil
                    }
                    pendingStopWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + DOUBLE_TAP_WINDOW, execute: work)
                } else {
                    state = .idle
                    emit(.stopRecording)
                }
            }
            // release in .recLocked / .tapPending → ignore
        }
    }

    private func cancelPending() {
        pendingStopWork?.cancel()
        pendingStopWork = nil
    }

    private func emit(_ e: Event) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(e)
        }
    }
}
