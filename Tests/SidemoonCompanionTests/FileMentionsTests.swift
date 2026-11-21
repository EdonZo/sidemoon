import Foundation
import Testing
@testable import SidemoonCompanion

@Suite struct FileMentionsTests {
    private let home = "/Users/me"

    /// Finds with a fixed set of files standing in for the disk.
    private func find(_ text: String, files: Set<String>) -> [String] {
        FileMentions.find(in: text, home: home, exists: { files.contains($0) }).map(\.path)
    }

    @Test func findsAPathInRunningTextAndDropsTheFullStop() {
        let files: Set = ["/Users/me/out/clip.mp4"]
        #expect(find("The video is saved to /Users/me/out/clip.mp4.", files: files) == ["/Users/me/out/clip.mp4"])
        #expect(find("Rendered: /Users/me/out/clip.mp4, 47 seconds", files: files) == ["/Users/me/out/clip.mp4"])
        #expect(find("(see /Users/me/out/clip.mp4)", files: files) == ["/Users/me/out/clip.mp4"])
    }

    @Test func aNameWithSpacesEndsWhereTheRealFileEnds() {
        let files: Set = ["/Users/me/Downloads/Quarterly Report - Final.pdf"]
        let text = "Attach /Users/me/Downloads/Quarterly Report - Final.pdf to the reply and send it."
        #expect(find(text, files: files) == ["/Users/me/Downloads/Quarterly Report - Final.pdf"])
    }

    @Test func pathsInCodeSpansListsAndWithTildeAreFound() {
        let files: Set = ["/Users/me/song.mp3", "/Users/me/notes/plan.md", "/tmp/a b.wav"]
        let text = """
        Files:
        1. `~/song.mp3`
        2. **/Users/me/notes/plan.md**
        - "/tmp/a b.wav"
        """
        #expect(find(text, files: files) == ["/Users/me/song.mp3", "/Users/me/notes/plan.md", "/tmp/a b.wav"])
    }

    @Test func whatIsNotARealFileIsIgnored() {
        let files: Set = ["/Users/me/real.png"]
        // A missing file, a web address, a fraction and a folder-like word are not files.
        let text = "Open https://example.com/a/b.png or /Users/me/missing.png; about 3/4 done, and/or later."
        #expect(find(text, files: files).isEmpty)
    }

    @Test func repeatsAreListedOnceAndTheListIsCapped() {
        var files: Set<String> = []
        var lines: [String] = []
        for index in 0..<10 {
            files.insert("/Users/me/f\(index).txt")
            lines.append("/Users/me/f\(index).txt and again /Users/me/f\(index).txt")
        }
        let found = find(lines.joined(separator: "\n"), files: files)
        #expect(found.count == CompanionConstants.FileMentions.maxPerReply)
        #expect(Set(found).count == found.count)
        #expect(found.first == "/Users/me/f0.txt")
    }

    @Test func twoPathsOnOneLineAreBothFound() {
        let files: Set = ["/Users/me/a.mp4", "/Users/me/b.mp4"]
        #expect(find("Old: /Users/me/a.mp4 New: /Users/me/b.mp4", files: files) == ["/Users/me/a.mp4", "/Users/me/b.mp4"])
    }
}
