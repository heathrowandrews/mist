// Wraps Apple's on-device SFSpeechRecognizer. Accepts CMSampleBuffer frames
// from AudioCapture (no AVAudioEngine — that path has the input-tap bug that
// paused the earlier prototype). Emits partial + final transcripts via
// callbacks. Auto-rotates the recognition request before Apple's per-session
// limit so streaming never drops mid-utterance.
//
// Not @MainActor: SFSpeech delivers results on Apple's internal queue, and
// audio buffer appends happen on the AVCapture queue. We hop to main only
// when invoking the user-facing callbacks.

import AVFoundation
import Foundation
import Speech

final class StreamingRecognizer: @unchecked Sendable {
    typealias TextCallback = @MainActor @Sendable (String) -> Void
    typealias ErrorCallback = @MainActor @Sendable (Error) -> Void

    private let speech = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let stateQueue = DispatchQueue(label: "com.bloom.dictate.recognizer.state")
    private let stateQueueKey = DispatchSpecificKey<Void>()
    // Timer queue is SEPARATE from stateQueue. If we put the rotation timer
    // on stateQueue, the handler would run on stateQueue and then deadlock
    // (libdispatch crashes with "dispatch_sync called on queue already owned
    // by current thread") when rotate() tries to acquire stateQueue.sync.
    // Verified via crash report 2026-05-12.
    private let timerQueue = DispatchQueue(label: "com.bloom.dictate.recognizer.timer")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running: Bool = false
    private var restartScheduled: Bool = false
    private var generation: UInt64 = 0

    // Apple caps each request at ~1 minute. Rotate before then.
    private let sessionMaxSeconds: TimeInterval = 50
    private var rotateTimer: DispatchSourceTimer?

    var onPartial: TextCallback?
    var onFinal: TextCallback?
    var onError: ErrorCallback?
    var onLifecycle: (@Sendable (String) -> Void)?

    var isRunning: Bool {
        stateSync { running }
    }

    init() {
        stateQueue.setSpecific(key: stateQueueKey, value: ())
        speech?.defaultTaskHint = .dictation
    }

    func start() throws {
        try stateSync {
            guard !running else { return }
            guard let speech, speech.isAvailable else {
                throw NSError(domain: "Recognizer", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "SFSpeechRecognizer unavailable"
                ])
            }
            if !speech.supportsOnDeviceRecognition {
                throw NSError(domain: "Recognizer", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "on-device recognition not supported on this hardware"
                ])
            }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = true    // 100 % local
            req.taskHint = .dictation
            req.addsPunctuation = true
            req.contextualStrings = [
                "Bloom Dictate",
                "OpenClaw",
                "Tailscale",
                "Plaud",
                "Codex",
                "Hammerspoon",
                "Karabiner",
                "Right Command"
            ]
            request = req
            running = true
            restartScheduled = false
            generation += 1
            let taskGeneration = generation

            task = speech.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                guard self.isCurrentGeneration(taskGeneration) else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    Task { @MainActor in
                        if result.isFinal {
                            self.onFinal?(text)
                        } else {
                            self.onPartial?(text)
                        }
                    }
                    if result.isFinal {
                        self.requestRestart(afterDelaySec: 0.1)
                    }
                }

                if let error {
                    if self.isBenignRecognitionLifecycleError(error) {
                        self.onLifecycle?("benign recognition lifecycle: \((error as NSError).localizedDescription)")
                        self.requestRestart(afterDelaySec: self.isNoSpeechDetected(error) ? 1.0 : 0.2)
                    } else {
                        Task { @MainActor in
                            self.onError?(error)
                        }
                        self.requestRestart(afterDelaySec: 0.5)
                    }
                }
            }

            scheduleRotateLocked()
            onLifecycle?("recognizer started")
        }
    }

    /// Append an audio sample buffer from AVCaptureSession. Called from the
    /// audio queue; SFSpeechAudioBufferRecognitionRequest is documented as
    /// thread-safe for append.
    func append(sampleBuffer: CMSampleBuffer) {
        let req = stateSync { self.request }
        req?.appendAudioSampleBuffer(sampleBuffer)
    }

    private func scheduleRotateLocked() {
        rotateTimer?.cancel()
        // Timer fires on timerQueue, NOT stateQueue, so rotate() can safely
        // acquire stateQueue.sync without recursing into a deadlock.
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + sessionMaxSeconds)
        timer.setEventHandler { [weak self] in
            self?.rotate()
        }
        timer.resume()
        rotateTimer = timer
    }

    /// End the current request cleanly (lets a final transcript flush) and
    /// open a fresh one so streaming continues past Apple's session limit.
    private func rotate() {
        let shouldRestart = stateSync { () -> Bool in
            guard running, !restartScheduled else { return false }
            restartScheduled = true
            request?.endAudio()
            task?.finish()
            return true
        }
        if shouldRestart {
            onLifecycle?("recognizer rotating after session limit")
            enqueueRestart(afterDelaySec: 0.05)
        }
    }

    func restartAfterStall(reason: String) {
        let shouldRestart = stateSync { () -> Bool in
            guard running, !restartScheduled else { return false }
            restartScheduled = true
            request?.endAudio()
            task?.cancel()
            return true
        }
        if shouldRestart {
            onLifecycle?("recognizer watchdog restart: \(reason)")
            enqueueRestart(afterDelaySec: 0.15)
        }
    }

    private func requestRestart(afterDelaySec: TimeInterval) {
        let shouldRestart = stateSync { () -> Bool in
            guard running, !restartScheduled else { return false }
            restartScheduled = true
            return true
        }
        if shouldRestart {
            enqueueRestart(afterDelaySec: afterDelaySec)
        }
    }

    private func enqueueRestart(afterDelaySec: TimeInterval) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + afterDelaySec) { [weak self] in
            guard let self else { return }
            self.teardownInternal()
            do {
                try self.start()
            } catch {
                DispatchQueue.main.async {
                    self.onError?(error)
                }
            }
        }
    }

    private func teardownInternal() {
        stateSync {
            rotateTimer?.cancel()
            rotateTimer = nil
            request = nil
            task = nil
            running = false
            restartScheduled = false
            generation += 1
        }
    }

    func stop() {
        stateSync {
            request?.endAudio()
            task?.cancel()
            rotateTimer?.cancel()
            rotateTimer = nil
            request = nil
            task = nil
            running = false
            restartScheduled = false
            generation += 1
        }
    }

    private func stateSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return try work()
        }
        return try stateQueue.sync(execute: work)
    }

    private func isCurrentGeneration(_ value: UInt64) -> Bool {
        stateSync { running && generation == value }
    }

    private func isBenignRecognitionLifecycleError(_ error: Error) -> Bool {
        let ns = error as NSError
        let message = ns.localizedDescription.lowercased()

        // 216 is the normal "task canceled" callback during stop/rotation.
        // 1110 is Apple's common "no speech detected" idle callback. Treat
        // both as request lifecycle, not as a user-visible error.
        if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 216 || ns.code == 1110) {
            return true
        }
        return message.contains("no speech detected")
            || message.contains("recognition request was canceled")
            || message.contains("recognition request was cancelled")
    }

    private func isNoSpeechDetected(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110)
            || ns.localizedDescription.lowercased().contains("no speech detected")
    }
}
