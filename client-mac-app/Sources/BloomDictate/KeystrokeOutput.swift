// Synthesize keystrokes into the currently focused text field via CGEvent.
//
// Uses CGEvent.keyboardSetUnicodeString so we can type any Unicode character
// (not limited to layout-mapped virtual keys). For backspace we post a real
// virtual key event (kVK_Delete = 0x33) since the OS handles that as a
// destructive editing command.
//
// Requires Accessibility permission so the synthetic events are accepted by
// other apps. macOS prompts the first time we post into another app's process.

import CoreGraphics
import Foundation

final class KeystrokeOutput {
    private let chunkSize: Int = 20
    private let interCharDelay: TimeInterval = 0.003   // 3 ms between chunks

    /// Type a string into whatever has focus.
    func type(_ text: String) {
        guard !text.isEmpty else { return }
        let utf16: [UniChar] = Array(text.utf16)
        var i = 0
        while i < utf16.count {
            let end = Swift.min(i + chunkSize, utf16.count)
            let slice = Array(utf16[i..<end])
            postUnicode(slice)
            i = end
            if i < utf16.count {
                Thread.sleep(forTimeInterval: interCharDelay)
            }
        }
    }

    /// Send N backspace keystrokes.
    func backspace(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)
            let up   = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: interCharDelay)
        }
    }

    private func postUnicode(_ chars: [UniChar]) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        chars.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: base)
            up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: base)
        }
        // Force flags=0 so the user's currently-held Right-⌘ doesn't get
        // merged into our synthetic event (would turn every typed letter
        // into a ⌘+letter shortcut — ⌘S saves, ⌘W closes, etc.)
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
