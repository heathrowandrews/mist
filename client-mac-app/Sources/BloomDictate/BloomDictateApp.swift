// BloomDictate v0 — SFSpeech streamer.
//
// Captures mic audio via AVCaptureSession (sidesteps the AVAudioEngine
// input-tap bug that paused the earlier prototype), feeds buffers into Apple's
// on-device SFSpeechRecognizer, and emits partial + final transcripts as
// newline-delimited JSON on stdout. A wrapper (Hammerspoon today, native
// hotkey code soon) reads stdout and types the partials.
//
// Stdout protocol (one JSON object per line, line-flushed):
//   {"type":"ready"}                 // permissions + start complete
//   {"type":"partial","text":"..."}
//   {"type":"final","text":"..."}
//   {"type":"error","message":"..."}
//   {"type":"stopped"}               // emitted on SIGINT / clean exit
//
// Stderr is for human/log lines (timestamps, diagnostics).
//
// Permissions (Info.plist usage strings live inside the wrapping .app bundle):
//   - Microphone   (NSMicrophoneUsageDescription)
//   - Speech       (NSSpeechRecognitionUsageDescription)

import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import IOKit.hid
import Speech

// MARK: - JSON output (thread-safe via print + fflush)

let stdoutLock = NSLock()

// Stream file: when the app is launched via `open` it has no inherited
// stdout, so we always also append events to ~/.bloom-dictate/dictate-stream.jsonl.
// Wrappers can either parse stdout (when launched as a child process) or tail
// the stream file (when launched standalone).
let streamFileURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".bloom-dictate")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("dictate-stream.jsonl")
}()

func emit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
          let s = String(data: data, encoding: .utf8) else { return }
    stdoutLock.lock()
    defer { stdoutLock.unlock() }
    print(s)
    fflush(stdout)
    // Also append to the stream file with a newline.
    let line = s + "\n"
    if let lineData = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: streamFileURL.path),
           let handle = try? FileHandle(forWritingTo: streamFileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
            try? handle.close()
        } else {
            try? lineData.write(to: streamFileURL)
        }
    }
}

func emit(type: String, text: String) {
    emit(["type": type, "text": text])
}

func emitError(_ msg: String) {
    emit(["type": "error", "message": msg])
}

let stderrHandle = FileHandle.standardError

// Always also append to ~/.bloom-dictate/dictate-app.log so logs survive being
// launched via `open` (which gives the process no inherited stderr).
let logFileURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".bloom-dictate")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("dictate-app.log")
}()

func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    guard let data = line.data(using: .utf8) else { return }
    stderrHandle.write(data)
    if FileManager.default.fileExists(atPath: logFileURL.path),
       let handle = try? FileHandle(forWritingTo: logFileURL) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? data.write(to: logFileURL)
    }
}

// MARK: - App lifecycle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recognizer = StreamingRecognizer()
    private let audio = AudioCapture()
    private let hotkey = HotkeyMonitor()
    private let keystroke = KeystrokeOutput()
    private let menubar = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    // Typing state — SFSpeech runs continuously; we only TYPE when the user
    // is holding Right-⌘ or in locked-recording mode.
    private var isTyping: Bool = false
    private var typedText: String = ""         // what we've actually keystroked
    private var baselinePartial: String = ""   // partial seen at the moment recording started
    private var lastPartial: String = ""
    private var lastRecognitionEventAt: Date = Date()
    private var lastWatchdogRestartAt: Date = .distantPast

    // --streamer mode: just emit SFSpeech partials as JSON on stdout. No
    // hotkey, no keystroke, no menubar — Hammerspoon (or another wrapper)
    // drives hotkey + typing while we provide the recognition engine.
    private let isStreamerMode: Bool = CommandLine.arguments.contains("--streamer")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isStreamerMode {
            setMenubar(recording: false)
        }

        recognizer.onPartial = { [weak self] text in
            self?.lastRecognitionEventAt = Date()
            emit(type: "partial", text: text)
            self?.handlePartial(text)
        }
        recognizer.onFinal = { [weak self] text in
            self?.lastRecognitionEventAt = Date()
            emit(type: "final", text: text)
            self?.handlePartial(text)
        }
        recognizer.onError = { err in
            emitError(err.localizedDescription)
            log("recognizer error: \(err.localizedDescription)")
        }
        recognizer.onLifecycle = { message in
            log(message)
        }

        audio.onSampleBuffer = { [weak self] buf in
            self?.recognizer.append(sampleBuffer: buf)
        }
        audio.onDiagnostic = { msg in log("audio: \(msg)") }
        audio.onLevel = { [weak self] peak in
            Task { @MainActor in
                self?.handleAudioLevel(peak)
            }
        }

        if !isStreamerMode {
            hotkey.onEvent = { [weak self] e in
                self?.handleHotkey(e)
            }
        }

        Task { @MainActor in
            await self.requestPermissions()
            self.startStreaming()
        }
    }

    private func requestPermissions() async {
        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in cont.resume(returning: granted) }
        }
        log("mic granted: \(micGranted)")
        if !micGranted {
            emitError("microphone denied — grant in System Settings → Privacy & Security → Microphone")
            exit(2)
        }

        let speechAuth = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        log("speech auth: \(speechAuth.rawValue)")
        if speechAuth != .authorized {
            emitError("speech recognition denied — grant in System Settings → Privacy & Security → Speech Recognition")
            exit(3)
        }
    }

    private func startStreaming() {
        if !isStreamerMode {
            // Standalone mode: also handles hotkey + keystroke output and
            // therefore needs Input Monitoring + Accessibility grants.
            let axTrusted = AXIsProcessTrusted()
            log("accessibility (AXIsProcessTrusted): \(axTrusted)")
            let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            log("input monitoring (IOHIDCheckAccess): \(inputMonitoring.rawValue)")

            if inputMonitoring != kIOHIDAccessTypeGranted {
                log("requesting Input Monitoring (system dialog will appear)…")
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
            if !axTrusted {
                log("requesting Accessibility (system dialog will appear)…")
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            }

            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let _ = self else { timer.invalidate(); return }
                let ax = AXIsProcessTrusted()
                let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
                log("grant-poll · accessibility=\(ax) inputMonitoring=\(im.rawValue)")
                if ax && im == kIOHIDAccessTypeGranted {
                    log("all grants received — fully functional")
                    timer.invalidate()
                }
            }

            hotkey.onLog = { msg in log("hotkey: \(msg)") }
        } else {
            log("streamer mode — SFSpeech only, no hotkey, no keystroke")
        }

        do {
            lastRecognitionEventAt = Date()
            try recognizer.start()
            try audio.start()
            if !isStreamerMode {
                try hotkey.start()
            }
            emit(["type": "ready"])
            log(isStreamerMode
                ? "streaming SFSpeech partials to stdout…"
                : "listening… (hold Right-⌘ or double-tap to lock)")
        } catch {
            emitError("start failed: \(error.localizedDescription)")
            log("start failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    private func handleAudioLevel(_ peak: Float) {
        guard peak >= 0.08 else { return }
        let now = Date()
        let recognitionQuietFor = now.timeIntervalSince(lastRecognitionEventAt)
        let restartQuietFor = now.timeIntervalSince(lastWatchdogRestartAt)
        guard recognitionQuietFor > 10, restartQuietFor > 15 else { return }

        lastWatchdogRestartAt = now
        log("watchdog: audio peak \(String(format: "%.4f", peak)) but no recognition for \(String(format: "%.1f", recognitionQuietFor))s; restarting recognizer")
        recognizer.restartAfterStall(reason: "audio without recognition")
    }

    // MARK: - Hotkey handling

    private func handleHotkey(_ e: HotkeyMonitor.Event) {
        switch e {
        case .startRecording:
            beginTyping()
            emit(["type": "rec_start"])
            setMenubar(recording: true)
        case .stopRecording:
            endTyping()
            emit(["type": "rec_stop"])
            setMenubar(recording: false)
        case .cancelRecording:
            // Drop typing context without touching the field.
            isTyping = false
            typedText = ""
            baselinePartial = lastPartial
            emit(["type": "rec_cancel"])
            setMenubar(recording: false)
        case .lockEngaged:
            emit(["type": "lock"])
        }
    }

    private func beginTyping() {
        // Anything currently in the partial is "before we started"; only type
        // characters that appear after this point.
        baselinePartial = lastPartial
        typedText = ""
        isTyping = true
        log("typing start (baseline len=\(baselinePartial.count))")
    }

    private func endTyping() {
        isTyping = false
        log("typing end (typed \(typedText.count) chars)")
        // Reset so a future session re-baselines fresh.
        typedText = ""
        baselinePartial = ""
    }

    private func handlePartial(_ text: String) {
        lastPartial = text
        guard isTyping else { return }

        // Compute the "new since recording started" portion. SFSpeech revises
        // earlier words occasionally; for v1 we follow Whisper-style "type the
        // suffix that appeared after our baseline" and accept that mid-utterance
        // revisions show up as new text without backspacing.
        guard text.count > baselinePartial.count,
              text.hasPrefix(baselinePartial) else {
            // Either no growth yet, or SFSpeech revised something behind our
            // baseline (rare). Skip this pass; the next partial will catch up.
            return
        }
        let newPortion = String(text.dropFirst(baselinePartial.count))
        guard newPortion.count > typedText.count,
              newPortion.hasPrefix(typedText) else {
            return
        }
        let toType = String(newPortion.dropFirst(typedText.count))
        if !toType.isEmpty {
            keystroke.type(toType)
            typedText = newPortion
        }
    }

    // MARK: - Menubar

    private func setMenubar(recording: Bool) {
        guard let button = menubar.button else { return }
        if recording {
            button.title = "🎙"
            button.toolTip = "Bloom Dictate · recording"
        } else {
            button.title = "🌱"
            button.toolTip = "Bloom Dictate · hold Right-⌘ or double-tap to lock"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        audio.stop()
        recognizer.stop()
        emit(["type": "stopped"])
        log("terminated")
    }
}

// MARK: - Entry

@main
@MainActor
struct BloomDictateApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon
        let delegate = AppDelegate()
        app.delegate = delegate

        // SIGINT / SIGTERM → clean terminate so we flush {"type":"stopped"}
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigInt.setEventHandler {
            log("SIGINT")
            app.terminate(nil)
        }
        sigInt.resume()
        let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigTerm.setEventHandler {
            log("SIGTERM")
            app.terminate(nil)
        }
        sigTerm.resume()

        app.run()

        // Keep dispatch sources from being optimized away before run returns.
        _ = sigInt
        _ = sigTerm
    }
}
