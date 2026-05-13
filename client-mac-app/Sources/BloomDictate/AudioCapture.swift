// Mic capture via AVCaptureSession + AVCaptureAudioDataOutput.
//
// Why not AVAudioEngine? The earlier prototype used AVAudioEngine and hit a
// reproducible bug where the inputNode tap callback never fires, even though
// `audioEngine.isRunning == true`. STATUS.md called for the AVCaptureSession
// path as the fix — this is that path.
//
// The delegate receives CMSampleBuffers, which SFSpeechAudioBufferRecognitionRequest
// accepts directly via `appendAudioSampleBuffer(_:)`. No PCM conversion needed.
//
// Not @MainActor: capture runs on its own audio queue. The user-facing
// callback (`onSampleBuffer`) is invoked from that queue; the caller should
// be ready for non-main delivery.

import AVFoundation
import AudioToolbox
import Foundation

final class AudioCapture: NSObject, @unchecked Sendable {
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?
    var onDiagnostic: (@Sendable (String) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.bloom.dictate.audio")
    private(set) var isRunning: Bool = false

    // Counts buffers received from AVCapture; log periodically so we can
    // tell whether audio is actually flowing.
    private let counterLock = NSLock()
    private var bufferCount: Int = 0
    private var lastLoggedAt: Date = .distantPast
    private var runningPeak: Float = 0   // peak amplitude across current 2s window

    func start() throws {
        guard !isRunning else { return }

        let allDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices

        guard let device = selectDevice(from: allDevices) else {
            throw NSError(domain: "AudioCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no audio input device (set one in System Settings → Sound → Input)"
            ])
        }

        onDiagnostic?("using audio device: \(device.localizedName) [\(device.uniqueID)]")
        for d in allDevices {
            let marker = (d.uniqueID == device.uniqueID) ? " ← selected" : ""
            onDiagnostic?("  available: \(d.localizedName) [\(d.uniqueID)]\(marker)")
        }

        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            throw NSError(domain: "AudioCapture", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "session refused audio input"
            ])
        }

        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            throw NSError(domain: "AudioCapture", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "session refused audio output"
            ])
        }

        session.startRunning()
        isRunning = true
    }

    private func selectDevice(from allDevices: [AVCaptureDevice]) -> AVCaptureDevice? {
        let env = ProcessInfo.processInfo.environment
        if let requested = env["BLOOM_DICTATE_AUDIO_DEVICE"], !requested.isEmpty {
            if let match = allDevices.first(where: { device in
                device.uniqueID == requested ||
                    device.localizedName.localizedCaseInsensitiveContains(requested)
            }) {
                onDiagnostic?("audio override matched BLOOM_DICTATE_AUDIO_DEVICE=\(requested)")
                return match
            }
            onDiagnostic?("audio override did not match any device: \(requested)")
        }

        guard let systemDefault = AVCaptureDevice.default(for: .audio) else {
            return allDevices.first
        }

        if env["BLOOM_DICTATE_PREFER_SYSTEM_INPUT"] == "1" {
            onDiagnostic?("using system-default input because BLOOM_DICTATE_PREFER_SYSTEM_INPUT=1")
            return systemDefault
        }

        if isLikelySilentBluetoothInput(systemDefault),
           let builtIn = allDevices.first(where: isBuiltInMacMicrophone) {
            onDiagnostic?("avoiding likely silent Bluetooth input \(systemDefault.localizedName); using built-in microphone")
            return builtIn
        }

        return systemDefault
    }

    private func isLikelySilentBluetoothInput(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        return name.contains("airpods") || name.contains("beats")
    }

    private func isBuiltInMacMicrophone(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        return device.uniqueID == "BuiltInMicrophoneDevice" ||
            name.contains("macbook") ||
            name.contains("built-in") ||
            name.contains("built in")
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        isRunning = false
    }
}

extension AudioCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Diagnostic: count buffers + compute peak amplitude so we can tell
        // whether the mic is actually capturing sound (vs just streaming
        // empty buffers — happens with some headsets in the wrong mode).
        let peak = peakAmplitude(in: sampleBuffer)
        counterLock.lock()
        bufferCount += 1
        runningPeak = max(runningPeak, peak)
        let now = Date()
        if now.timeIntervalSince(lastLoggedAt) > 2.0 {
            lastLoggedAt = now
            let count = bufferCount
            let p = runningPeak
            runningPeak = 0
            counterLock.unlock()
            onDiagnostic?("audio: \(count) buffers · peak=\(String(format: "%.4f", p)) \(p < 0.001 ? "(SILENT?)" : "")")
            onLevel?(p)
        } else {
            counterLock.unlock()
        }

        onSampleBuffer?(sampleBuffer)
    }

    private func peakAmplitude(in sampleBuffer: CMSampleBuffer) -> Float {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return 0 }

        let asbd = streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return 0 }

        var dataPtr: UnsafeMutablePointer<Int8>?
        var totalLength: Int = 0
        guard CMBlockBufferGetDataPointer(blockBuffer,
                                          atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPtr) == noErr,
              let dataPtr
        else { return 0 }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        if isFloat && asbd.mBitsPerChannel == 32 {
            let sampleCount = totalLength / MemoryLayout<Float>.size
            var peak: Float = 0
            dataPtr.withMemoryRebound(to: Float.self, capacity: sampleCount) { samples in
                for i in 0..<sampleCount {
                    peak = max(peak, abs(samples[i]))
                }
            }
            return min(peak, 1)
        }

        if asbd.mBitsPerChannel == 16 {
            let sampleCount = totalLength / MemoryLayout<Int16>.size
            var peak: Float = 0
            dataPtr.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                for i in 0..<sampleCount {
                    peak = max(peak, abs(Float(samples[i])) / Float(Int16.max))
                }
            }
            return min(peak, 1)
        }

        return 0
    }
}
