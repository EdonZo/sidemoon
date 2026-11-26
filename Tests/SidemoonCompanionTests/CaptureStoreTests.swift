import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

private func scratchRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-capture-root-\(UUID().uuidString)", isDirectory: true)
}

private func capture(in store: CaptureStore) throws -> URL {
    try store.prepare()
    let url = store.newFileURL()
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
    return url
}

private func age(_ url: URL, by seconds: TimeInterval) throws {
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
}

@Suite struct CaptureStoreTests {
    /// Under the test runner nothing resolves to the real support folder, where the running app keeps the user's
    /// captures; and a model cannot be made without saying where its captures go.
    @Test func testsNeverReachTheRealFolder() {
        #expect(Constants.TestRunner.isActive)
        let real = Constants.Paths.realSupportDirectory.standardizedFileURL.path
        #expect(!Constants.Paths.supportDirectory.standardizedFileURL.path.hasPrefix(real))
        #expect(!CompanionConstants.Capture.directory.standardizedFileURL.path.hasPrefix(real))
        #expect(!scratchStore().directory.path.hasPrefix(real))
    }

    @Test func eachRunHasItsOwnFolder() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(root: root)
        let file = try capture(in: store)
        #expect(file.deletingLastPathComponent().lastPathComponent == CaptureRun.current.folderName)
        #expect(CaptureRun.parse(CaptureRun.current.folderName) == CaptureRun.current)
        #expect(CaptureRun.current.started > 0)
        #expect(store.files().map(\.lastPathComponent) == [file.lastPathComponent])
        // Owner-only, as before.
        let mode = (try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? NSNumber)?.int16Value
        #expect(mode.map { mode_t($0) } == Constants.Permissions.directory)
    }

    /// The case that lost the owner's screenshots: another process starting (a test run, the preview renderer, a
    /// second copy) cleans up, and the first one's waiting captures stay.
    @Test func anotherRunStartingKeepsTheseCaptures() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = CaptureStore(root: root)
        let waiting = try capture(in: mine)
        // A second Sidemoon whose process is alive (here: a made-up one the injected check says is running).
        let other = CaptureStore(root: root, run: CaptureRun(pid: 4242, started: 7))
        let theirs = try capture(in: other)
        other.purge(processStart: { pid in pid == 4242 ? .started(7) : CaptureRun.processStart(pid) })
        #expect(FileManager.default.fileExists(atPath: waiting.path))
        // And the other way round, with the real check: this process is alive, so its folder stays.
        mine.purge(processStart: { pid in pid == 4242 ? .started(7) : CaptureRun.processStart(pid) })
        #expect(FileManager.default.fileExists(atPath: theirs.path) && FileManager.default.fileExists(atPath: waiting.path))
        // A model starting on the same folder does not delete them either.
        let fresh = CaptureStore(root: root, run: CaptureRun(pid: 4243, started: 9))
        fresh.purge()
        #expect(FileManager.default.fileExists(atPath: waiting.path))
    }

    @Test func aDeadRunsLeftoversAreRemoved() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let crashed = CaptureStore(root: root, run: CaptureRun(pid: 4242, started: 7))
        let left = try capture(in: crashed)
        let reused = CaptureStore(root: root, run: CaptureRun(pid: 4343, started: 7))
        let alsoLeft = try capture(in: reused)
        let mine = CaptureStore(root: root)
        mine.purge(processStart: { pid in
            switch pid {
            case 4242: return .none
            case 4343: return .started(99)  // the id now belongs to another program
            default: return CaptureRun.processStart(pid)
            }
        })
        #expect(!FileManager.default.fileExists(atPath: crashed.directory.path))
        #expect(!FileManager.default.fileExists(atPath: left.path) && !FileManager.default.fileExists(atPath: alsoLeft.path))
    }

    @Test func looseLegacyCapturesAreRemovedOnceOld() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("\(CompanionConstants.Capture.filePrefix)old.png")
        let recent = root.appendingPathComponent("\(CompanionConstants.Capture.filePrefix)recent.png")
        let unrelated = root.appendingPathComponent("notes.txt")
        for url in [old, recent, unrelated] { try Data([1]).write(to: url) }
        try age(old, by: CompanionConstants.Capture.legacyMaxAge + 60)
        try age(unrelated, by: CompanionConstants.Capture.legacyMaxAge + 60)
        CaptureStore(root: root).purge()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        // A recent one may belong to an older Sidemoon still running; anything not a capture is not Sidemoon's.
        #expect(FileManager.default.fileExists(atPath: recent.path) && FileManager.default.fileExists(atPath: unrelated.path))
    }

    /// Where the owner cannot be judged, kept; once old enough, removed.
    @Test func anUnjudgedFolderIsKeptThenRemovedByAge() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsure = CaptureStore(root: root, run: CaptureRun(pid: 4242, started: 7))
        _ = try capture(in: unsure)
        let odd = root.appendingPathComponent("\(CompanionConstants.Capture.runFolderPrefix)not-a-run", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let mine = CaptureStore(root: root)
        let cannotTell: (Int32) -> CaptureRun.Process = { $0 == 4242 ? .unknown : CaptureRun.processStart($0) }
        mine.purge(processStart: cannotTell)
        #expect(FileManager.default.fileExists(atPath: unsure.directory.path) && FileManager.default.fileExists(atPath: odd.path))
        let later = Date().addingTimeInterval(CompanionConstants.Capture.unjudgedMaxAge + 60)
        mine.purge(now: later, processStart: cannotTell)
        #expect(!FileManager.default.fileExists(atPath: unsure.directory.path) && !FileManager.default.fileExists(atPath: odd.path))
        // This run's own folder is never removed, however old.
        #expect(CaptureCleanup.runFolder(CaptureRun.current.folderName, modified: .distantPast, now: Date(), own: CaptureRun.current,
                                         processStart: { _ in .none }) == .keep)
    }
}
