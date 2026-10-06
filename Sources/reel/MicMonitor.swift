@preconcurrency import AVFoundation

/// Live input level for the toolbar's mic button, so you can see the mic works
/// before you hit record. Only runs while the toolbar is open with the mic on.
@MainActor
final class MicMonitor {
    let meter = LevelMeter()
    private var session: AVCaptureSession?
    private var deviceID: String?
    private let tap = SampleTap(label: "dev.reel.mic-level")

    init() {
        tap.onSample = { [meter] in meter.push($0) }
    }

    /// Starts (or switches) monitoring. nil = system default input.
    func start(deviceID: String?) {
        if session != nil, self.deviceID == deviceID { return }
        stop()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted { DispatchQueue.main.async { self.start(deviceID: deviceID) } }
            }
            return
        default: return
        }
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(tap, queue: tap.queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        self.session = session
        self.deviceID = deviceID
        meter.activate()
        tap.queue.async { session.startRunning() }
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        deviceID = nil
        meter.reset()
        tap.queue.async { session.stopRunning() }
    }
}

/// Forwards audio sample buffers from a background queue.
final class SampleTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue: DispatchQueue
    var onSample: ((CMSampleBuffer) -> Void)?

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSample?(sampleBuffer)
    }
}
