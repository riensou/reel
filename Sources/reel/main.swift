import AppKit
import ReelCore

// Headless mode for scripting and testing without the UI:
//   reel --shot <out.png>
//   reel --record <seconds> <out.mp4|.mov> [--system-audio] [--mic] [--no-cursor]
// Captures the main display. (A proper CLI + MCP server is Phase 2.)
let args = CommandLine.arguments
if let i = args.firstIndex(where: { $0 == "--shot" || $0 == "--record" }) {
    Task {
        do {
            let display = CGMainDisplayID()
            var options = CaptureOptions()
            options.systemAudio = args.contains("--system-audio")
            options.microphone = args.contains("--mic")
            options.cursor.show = !args.contains("--no-cursor")
            if args[i] == "--shot" {
                let out = URL(fileURLWithPath: args[i + 1])
                let shot = try await Screenshotter.capture(.display(display), options: options)
                try Screenshotter.writePNG(shot, to: out)
                print(out.path)
            } else {
                let seconds = Double(args[i + 1]) ?? 5
                let out = URL(fileURLWithPath: args[i + 2])
                if out.pathExtension == "mov" { options.format = .mov }
                let recorder = Recorder()
                try await recorder.start(.display(display), options: options)
                try await Task.sleep(for: .seconds(seconds))
                let recording = try await recorder.stop()
                var job = Finisher.Job(segments: recording.segments, output: out)
                job.format = out.pathExtension == "mov" ? .mov : .mp4
                if await Finisher.canSkip(job) {
                    try? FileManager.default.removeItem(at: out)
                    try FileManager.default.moveItem(at: recording.segments[0], to: out)
                } else {
                    try await Finisher.run(job)
                }
                try? FileManager.default.removeItem(at: recording.workDirectory)
                print(out.path)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("reel: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
