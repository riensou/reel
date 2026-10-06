@preconcurrency import AVFoundation
import Combine

/// Live input level for the toolbar's mic button, so you can see the mic works
/// before you hit record. Only runs while the toolbar is open with the mic on.
@MainActor
final class MicMonitor: ObservableObject {
    /// 0…1, smoothed: rises instantly, falls off gently.
    @Published private(set) var level: Float = 0

    private var session: AVCaptureSession?
    private var deviceID: String?
    private let tap = LevelTap()

    init() {
        tap.onLevel = { [weak self] raw in
            DispatchQueue.main.async {
                guard let self, self.session != nil else { return }
                self.level = raw > self.level ? raw : max(raw, self.level * 0.85)
            }
        }
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
        tap.queue.async { session.startRunning() }
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        deviceID = nil
        level = 0
        tap.queue.async { session.stopRunning() }
    }
}

/// Sample-buffer delegate living off the main actor; reports RMS mapped to 0…1.
private final class LevelTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.reel.mic-level")
    var onLevel: ((Float) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer
        )
        guard status == noErr, let data = list.mBuffers.mData else { return }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        // -50 dB (room tone) → 0, 0 dB → 1.
        let db = 20 * log10(max(rms, 1e-7))
        onLevel?(min(max((db + 50) / 50, 0), 1))
    }
}
