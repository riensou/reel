@preconcurrency import AVFoundation
import Combine

/// A 0…1 audio level for a toolbar button: rises instantly, falls off gently.
@MainActor
final class LevelMeter: ObservableObject {
    @Published private(set) var level: Float = 0
    private(set) var isActive = false

    func activate() { isActive = true }

    func reset() {
        isActive = false
        level = 0
    }

    /// Thread-safe entry point for audio callbacks.
    nonisolated func push(_ sampleBuffer: CMSampleBuffer) {
        guard let raw = Self.normalizedRMS(sampleBuffer) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.isActive else { return }
                self.level = raw > self.level ? raw : max(raw, self.level * 0.85)
            }
        }
    }

    /// RMS across all channels of a Float32 PCM buffer, mapped -50 dB…0 dB → 0…1.
    /// Handles both interleaved (one buffer) and non-interleaved (one per channel) layouts.
    nonisolated static func normalizedRMS(_ sampleBuffer: CMSampleBuffer) -> Float? {
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        )
        guard sizeNeeded > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPtr, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        var sum: Float = 0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(listPtr) {
            guard let data = buffer.mData else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<n { sum += samples[i] * samples[i] }
            count += n
        }
        guard count > 0 else { return nil }
        let db = 20 * log10(max((sum / Float(count)).squareRoot(), 1e-7))
        return min(max((db + 50) / 50, 0), 1)
    }
}
