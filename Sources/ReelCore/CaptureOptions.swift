import CoreGraphics
import Foundation

/// What to capture. Region rects are in the display's point space, top-left origin.
public enum CaptureTarget: Equatable, Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case region(CGDirectDisplayID, CGRect)
}

public enum CaptureMode: String, CaseIterable, Codable, Sendable {
    case screen, window, region
}

public enum CaptureAction: String, CaseIterable, Codable, Sendable {
    case screenshot, record
}

public struct CursorOptions: Codable, Equatable, Sendable {
    public var show = true

    public init() {}
}

public struct CaptureOptions: Codable, Equatable, Sendable {
    public var systemAudio = false
    public var microphone = false
    /// AVCaptureDevice.uniqueID; nil means the system default input.
    public var microphoneID: String?
    public var cursor = CursorOptions()
    public var fps = 60

    public init() {}
}

public enum ReelError: LocalizedError {
    case targetNotFound
    case alreadyRecording
    case notRecording
    case writeFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .targetNotFound: "The display or window to capture is no longer available."
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "No recording is in progress."
        case .writeFailed(let url): "Couldn't write \(url.lastPathComponent)."
        }
    }
}
