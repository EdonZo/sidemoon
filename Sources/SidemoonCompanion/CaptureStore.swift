import Darwin
import Foundation
import SidemoonCore

/// One running Sidemoon, as its captures folder is named: its process id and when that process started. The start
/// time tells the process apart from an unrelated one that later got the same id.
public struct CaptureRun: Equatable, Sendable {
    public let pid: Int32
    /// Microseconds since 1970 when the process started.
    public let started: Int64

    public init(pid: Int32, started: Int64) {
        self.pid = pid
        self.started = started
    }

    /// This process.
    public static let current: CaptureRun = {
        let pid = getpid()
        if case let .started(at) = processStart(pid) { return CaptureRun(pid: pid, started: at) }
        // Cannot read its own start: a folder no other run can mistake for its own, judged by age when left over.
        return CaptureRun(pid: pid, started: 0)
    }()

    public var folderName: String { "\(CompanionConstants.Capture.runFolderPrefix)\(pid)-\(started)" }

    /// The run a folder belongs to; nil when the name is not one this code writes.
    public static func parse(_ name: String) -> CaptureRun? {
        let prefix = CompanionConstants.Capture.runFolderPrefix
        guard name.hasPrefix(prefix) else { return nil }
        let parts = name.dropFirst(prefix.count).split(separator: "-")
        guard parts.count == 2, let pid = Int32(parts[0]), pid > 0, let started = Int64(parts[1]) else { return nil }
        return CaptureRun(pid: pid, started: started)
    }

    /// What the system says about a process id now.
    public enum Process: Equatable, Sendable {
        /// No process has this id.
        case none
        /// One has, started at this time.
        case started(Int64)
        /// The system would not say.
        case unknown
    }

    public static func processStart(_ pid: Int32) -> Process {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return .unknown }
        guard size > 0, info.kp_proc.p_pid == pid else { return .none }
        let t = info.kp_proc.p_starttime
        return .started(Int64(t.tv_sec) * 1_000_000 + Int64(t.tv_usec))
    }
}

/// What a launch's cleanup does with something it finds in the captures folder.
public enum CaptureCleanup {
    public enum Verdict: Equatable, Sendable { case keep, remove }

    /// A run's folder: kept while its owner runs, removed once it is gone or its id belongs to another process now.
    /// Where the owner cannot be judged (a name this code does not write, the system would not say, or the run could
    /// not read its own start), kept, and removed once older than `Capture.unjudgedMaxAge`, so nothing piles up.
    public static func runFolder(_ name: String, modified: Date, now: Date, own: CaptureRun,
                                 processStart: (Int32) -> CaptureRun.Process) -> Verdict {
        let byAge: Verdict = now.timeIntervalSince(modified) > CompanionConstants.Capture.unjudgedMaxAge ? .remove : .keep
        guard let run = CaptureRun.parse(name) else { return byAge }
        if run == own { return .keep }
        switch processStart(run.pid) {
        case .none: return .remove
        case let .started(at): return run.started == 0 ? byAge : (at == run.started ? .keep : .remove)
        case .unknown: return byAge
        }
    }

    /// A capture left loose in the captures folder by a version from before run folders. Such a version may still be
    /// running and waiting to send it, so only one older than `Capture.legacyMaxAge` is removed.
    public static func looseFile(modified: Date, now: Date) -> Verdict {
        now.timeIntervalSince(modified) > CompanionConstants.Capture.legacyMaxAge ? .remove : .keep
    }
}

/// Temporary capture files, kept owner-only under the support folder: one folder per running Sidemoon, so a second
/// process (another copy, the preview renderer) never deletes what this one is waiting to send. A capture is deleted
/// once its message is delivered or discarded; what a crashed run left is removed at a later launch (`purge`).
public struct CaptureStore: Sendable {
    /// The captures folder all runs share.
    public let root: URL
    /// The run whose captures this store makes.
    public let run: CaptureRun
    /// This run's own folder, where its captures go.
    public var directory: URL { root.appendingPathComponent(run.folderName, isDirectory: true) }

    /// There is no default folder on purpose: whoever makes a store says where, so a test cannot fall back to the
    /// app's (the app passes `CompanionConstants.Capture.directory`).
    public init(root: URL, run: CaptureRun = .current) {
        self.root = root
        self.run = run
    }

    /// The same as `init(root:)`.
    public init(directory: URL) { self.init(root: directory) }

    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, directory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: Constants.Permissions.directory])
            chmod(dir.path, Constants.Permissions.directory)
        }
    }

    public func newFileURL() -> URL {
        directory.appendingPathComponent(
            "\(CompanionConstants.Capture.filePrefix)\(UUID().uuidString.lowercased()).\(CompanionConstants.Capture.fileExtension)")
    }

    public func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Removes what other runs left that cannot be theirs any more (`CaptureCleanup`). This run's own folder, and
    /// the folders of runs that are alive, are never touched.
    public func purge(now: Date = Date(), processStart: (Int32) -> CaptureRun.Process = CaptureRun.processStart) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        for item in items {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? now
            let name = item.lastPathComponent
            if values?.isDirectory == true {
                guard name.hasPrefix(CompanionConstants.Capture.runFolderPrefix), name != run.folderName else { continue }
                if CaptureCleanup.runFolder(name, modified: modified, now: now, own: run, processStart: processStart) == .remove {
                    remove(item)
                }
            } else if name.hasPrefix(CompanionConstants.Capture.filePrefix),
                      CaptureCleanup.looseFile(modified: modified, now: now) == .remove {
                remove(item)
            }
        }
    }

    /// This run's captures.
    public func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(CompanionConstants.Capture.filePrefix) }
    }
}
