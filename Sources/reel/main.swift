import AppKit
import ReelCore

// Headless mode for scripting and testing without the UI:
//   reel --shot <out.png>
//   reel --record <seconds> <out.mov> [--system-audio] [--mic] [--no-cursor]
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
                let recorder = Recorder()
                try await recorder.start(.display(display), options: options, to: out)
                try await Task.sleep(for: .seconds(seconds))
                print(try await recorder.stop().path)
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
