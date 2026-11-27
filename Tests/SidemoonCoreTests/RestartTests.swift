import Foundation
import Testing
@testable import SidemoonCore

/// After the Mac or Sidemoon restarts, images still reach a session; and the `claude agents` screen is never a session.
@Suite struct RestartTests {
    private let sid = "5c1d2e3f-0000-4000-8000-00000000a109"

    private func tempFile() -> String {
        NSTemporaryDirectory() + "sidemoon-scratchpads-\(UUID().uuidString).json"
    }

    /// A scratchpad seen in a hook payload is remembered, and recalled after a restart.
    @Test func aScratchpadIsRememberedAcrossRestarts() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        let dir = "/private/tmp/claude-\(getuid())/-Users-x/\(sid)/scratchpad"
        #expect(ScratchpadMemory.recall(sid, path: file) == nil)
        ScratchpadMemory.remember(sid, scratchpad: dir, path: file)
        #expect(ScratchpadMemory.recall(sid, path: file) == dir)
        // A newer folder for the same session replaces the old one.
        let newer = "/private/tmp/claude-\(getuid())/-Users-y/\(sid)/scratchpad"
        ScratchpadMemory.remember(sid, scratchpad: newer, path: file)
        #expect(ScratchpadMemory.recall(sid, path: file) == newer)
    }

    /// Only Claude Code's own temp folder is ever remembered.
    @Test func aFolderOutsideClaudesTempIsNotRemembered() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        ScratchpadMemory.remember(sid, scratchpad: "/Users/x/project", path: file)
        #expect(ScratchpadMemory.recall(sid, path: file) == nil)
    }

    /// Only the newest sessions are kept.
    @Test func theOldestAreForgotten() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        let cap = Constants.Limits.rememberedScratchpads
        for i in 0...cap {
            ScratchpadMemory.remember("s\(i)", scratchpad: "/private/tmp/claude-\(getuid())/p/s\(i)/scratchpad", path: file)
        }
        #expect(ScratchpadMemory.recall("s0", path: file) == nil)
        #expect(ScratchpadMemory.recall("s\(cap)", path: file) != nil)
    }

    /// The temp folder was emptied by a restart: the session's folder is made again and the image is written.
    @Test func aWipedScratchpadIsMadeAgain() throws {
        let project = "/private/tmp/claude-\(getuid())/sidemoon-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: project) }
        let dir = "\(project)/\(sid)/scratchpad"
        #expect(!FileManager.default.fileExists(atPath: dir))
        let file = NSTemporaryDirectory() + "sidemoon-restart-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: file) }
        try Data("hello".utf8).write(to: URL(fileURLWithPath: file))
        let placed = try ImageFile.placeFile(file, inScratchpad: dir)
        #expect(FileManager.default.contents(atPath: placed) == Data("hello".utf8))
    }

    /// The agents screen is told apart by its command line, whether Claude Code runs as a binary or a script.
    @Test func theAgentsScreenIsRecognisedByItsCommand() {
        #expect(AgentsScreen.isAgentsScreen(arguments: ["agents"]))
        #expect(AgentsScreen.isAgentsScreen(arguments: ["/opt/claude/cli.js", "agents"]))
        #expect(AgentsScreen.isAgentsScreen(arguments: ["--verbose", "agents"]))
        #expect(!AgentsScreen.isAgentsScreen(arguments: []))
        #expect(!AgentsScreen.isAgentsScreen(arguments: nil))
        #expect(!AgentsScreen.isAgentsScreen(arguments: ["--resume", "abc"]))
        // A one-off answer whose prompt is the word "agents" is not the screen.
        #expect(!AgentsScreen.isAgentsScreen(arguments: ["-p", "agents"]))
        #expect(!AgentsScreen.isAgentsScreen(arguments: ["--print", "agents"]))
        // A session whose prompt or folder mentions agents is still a session.
        #expect(!AgentsScreen.isAgentsScreen(arguments: ["--continue"]))
        #expect(!AgentsScreen.isAgentsScreen(arguments: ["--dangerously-skip-permissions", "fix the agents page"]))
        // This test process is not the agents screen.
        #expect(!AgentsScreen.isAgentsScreen(pid: getpid()))
        #expect(!AgentsScreen.isAgentsScreen(pid: nil))
    }
}
