import CoreMedia
import Foundation
import ScreenCaptureKit

/// Builds the ScreenCaptureKit filter + configuration shared by screenshots and recordings.
enum StreamSetup {
    /// - Parameter keepWindows: windows owned by this process that should still be
    ///   captured (e.g. the click-highlight overlay). Every other reel window is excluded.
    static func make(
        target: CaptureTarget,
        options: CaptureOptions,
        keepWindows: [CGWindowID] = []
    ) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let keep = content.windows.filter { keepWindows.contains($0.windowID) }

        let filter: SCContentFilter
        var sourceRect: CGRect?
        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ReelError.targetNotFound
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: keep)
        case .region(let id, let rect):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ReelError.targetNotFound
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: keep)
            sourceRect = rect.integral
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw ReelError.targetNotFound
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let scale = CGFloat(filter.pointPixelScale)
        let size = sourceRect?.size ?? filter.contentRect.size
        let config = SCStreamConfiguration()
        if let sourceRect { config.sourceRect = sourceRect }
        // Even dimensions keep the video encoder happy.
        config.width = max(2, Int(size.width * scale) & ~1)
        config.height = max(2, Int(size.height * scale) & ~1)
        config.captureResolution = .best
        config.showsCursor = options.cursor.show
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, options.fps)))
        config.queueDepth = 6
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = options.microphone
        if let mic = options.microphoneID { config.microphoneCaptureDeviceID = mic }
        return (filter, config)
    }
}
