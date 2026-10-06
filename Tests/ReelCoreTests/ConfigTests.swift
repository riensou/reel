import Carbon.HIToolbox
import Foundation
import Testing
@testable import ReelCore

@Suite struct ConfigTests {
    @Test func defaultsWhenEmpty() {
        let (c, w) = Config.parse("")
        #expect(c == Config())
        #expect(w.isEmpty)
    }

    @Test func templateParsesToDefaultsWithoutWarnings() {
        let (c, w) = Config.parse(Config.template)
        #expect(c == Config())
        #expect(w.isEmpty)
    }

    @Test func parsesValuesCommentsAndQuotes() {
        let (c, w) = Config.parse("""
        # comment
        countdown = 3
        save-directory = "~/My Videos"   # inline comment
        auto-zoom = yes
        show-keystrokes = Shortcuts
        auto-zoom-scale = 2.5
        hotkey = shift+cmd+r
        """)
        #expect(w.isEmpty)
        #expect(c.countdown == 3)
        #expect(c.saveDirectory == "~/My Videos")
        #expect(c.autoZoom)
        #expect(c.showKeystrokes == .shortcuts)
        #expect(c.autoZoomScale == 2.5)
        #expect(c.hotkey == KeyCombo(keyCode: kVK_ANSI_R, modifiers: [.command, .shift]))
    }

    @Test func laterLinesWin() {
        let (c, _) = Config.parse("fps = 30\nfps = 24")
        #expect(c.fps == 24)
    }

    @Test func warnsWithLineNumbers() {
        let (c, w) = Config.parse("fps = 30\nbogus = 1\ncountdown = 99\nhotkey = 6")
        #expect(c.fps == 30)
        #expect(c.countdown == 0)
        #expect(w.map(\.line) == [2, 3, 4])
    }

    @Test func systemSaveDirectoryMeansNil() {
        #expect(Config.parse("save-directory = system").0.saveDirectory == nil)
        #expect(Config().value(for: "save-directory") == "system")
    }

    // MARK: In-place edits

    @Test func setReplacesActiveLineKeepingComments() {
        let text = "# hi\ncountdown = 3 # note\n\nfps = 30\n"
        let out = ConfigFile.setting("countdown", "5", in: text)
        #expect(out == "# hi\ncountdown = 5\n\nfps = 30\n")
    }

    @Test func setUncommentsTemplateLine() {
        let out = ConfigFile.setting("countdown", "3", in: Config.template)
        #expect(Config.parse(out).0.countdown == 3)
        #expect(out.components(separatedBy: "\n").count == Config.template.components(separatedBy: "\n").count)
        #expect(!out.contains("# countdown = 0"))
    }

    @Test func setAppendsWhenMissing() {
        let out = ConfigFile.setting("fps", "24", in: "# only a comment\n")
        #expect(out == "# only a comment\nfps = 24\n")
    }

    @Test func setOnFileRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = ConfigFile(url: dir.appending(path: "config"))
        try file.ensureExists()
        try file.set("recording-border", "true")
        try file.set("hotkey", "ctrl+opt+r")
        let (c, w) = file.load()
        #expect(w.isEmpty)
        #expect(c.recordingBorder)
        #expect(c.hotkey.description == "ctrl+opt+r")
        try? FileManager.default.removeItem(at: dir)
    }
}

@Suite struct KeyComboTests {
    @Test func parsesAndPrints() throws {
        let k = try #require(KeyCombo("Shift+CMD+6"))
        #expect(k == .defaultToolbar)
        #expect(k.description == "shift+cmd+6")
        #expect(k.symbols == "⇧⌘6")
        #expect(KeyCombo(k.description) == k)
    }

    @Test func rejectsBareKeysAndJunk() {
        #expect(KeyCombo("6") == nil)
        #expect(KeyCombo("cmd+") == nil)
        #expect(KeyCombo("cmd+a+b") == nil)
        #expect(KeyCombo("cmd+banana") == nil)
    }

    @Test func functionKeys() {
        #expect(KeyCombo("ctrl+f5")?.keyCode == kVK_F5)
    }
}

@Suite struct SaveLocationTests {
    @Test func filenames() {
        let date = DateComponents(calendar: .current, year: 2026, month: 10, day: 6, hour: 14, minute: 3, second: 22).date!
        #expect(SaveLocation.filename(for: .screenshot, date: date) == "Screenshot 2026-10-06 at 14.03.22.png")
        #expect(SaveLocation.filename(for: .recording, date: date) == "Screen Recording 2026-10-06 at 14.03.22.mp4")
        #expect(SaveLocation.filename(for: .recording, date: date, format: .mov).hasSuffix(".mov"))
    }

    @Test func commitAvoidsCollisions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for _ in 0..<3 {
            let src = fm.temporaryDirectory.appending(path: "\(UUID().uuidString)/Shot.png")
            try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: src)
            let renamed = src.deletingLastPathComponent().appending(path: "Shot.png")
            _ = try SaveLocation.commit(renamed, to: dir)
        }
        let names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["Shot (2).png", "Shot (3).png", "Shot.png"])
        try? fm.removeItem(at: dir)
    }
}
