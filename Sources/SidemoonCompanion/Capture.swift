import CoreGraphics
import Foundation
import SidemoonCore

public enum CaptureOutcome: Equatable, Sendable {
    case captured(URL)
    /// The user pressed Escape or otherwise produced no image.
    case cancelled
}

public struct CaptureError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }

    /// The active-window capture found nothing to capture.
    public static let noActiveWindow = CaptureError("no active window to capture")
}

/// Produces one screenshot file at `destination`. Behind a protocol so tests inject an image instead.
public protocol CaptureProvider: Sendable {
    func capture(into destination: URL) async throws -> CaptureOutcome
}

/// Runs `/usr/sbin/screencapture` with the given arguments and returns its exit status.
private func runScreencapture(_ arguments: [String]) async throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CompanionConstants.Capture.tool)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: CaptureError("could not run \(CompanionConstants.Capture.tool): \(error.localizedDescription)"))
        }
    }
}

private func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

/// Interactive region capture with `/usr/sbin/screencapture -i -x <file>`.
public struct ScreencaptureProvider: CaptureProvider {
    public init() {}

    public func capture(into destination: URL) async throws -> CaptureOutcome {
        let status = try await runScreencapture(CompanionConstants.Capture.arguments + [destination.path])
        // Escape leaves no file (screencapture exits 0 or 1 depending on the macOS version).
        if fileSize(destination) > 0 { return .captured(destination) }
        if status == 0 || status == 1 { return .cancelled }
        throw CaptureError("screencapture exited with status \(status)")
    }
}

// MARK: - Active window

/// One on-screen window, as the window server describes it.
public struct WindowInfo: Equatable, Sendable {
    public let id: CGWindowID
    public let ownerPID: pid_t
    public let layer: Int
    public let bounds: CGRect

    public init(id: CGWindowID, ownerPID: pid_t, layer: Int, bounds: CGRect) {
        self.id = id
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
    }

    /// Reads one entry of `CGWindowListCopyWindowInfo`; nil when a required field is missing.
    public init?(_ entry: [String: Any]) {
        guard let number = entry[kCGWindowNumber as String] as? Int,
              let pid = entry[kCGWindowOwnerPID as String] as? Int,
              let layer = entry[kCGWindowLayer as String] as? Int,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        self.init(id: CGWindowID(number), ownerPID: pid_t(pid), layer: layer, bounds: bounds)
    }
}

public enum ActiveWindow {
    /// The front-most ordinary window of `pid`, given windows in front-to-back order. Never a window of
    /// `excludedPID` (Sidemoon itself), never one on another layer, never one smaller than `minimumSize`.
    public static func pick(_ windows: [WindowInfo], pid: pid_t, excludedPID: pid_t,
                            minimumSize: CGSize = CompanionConstants.Capture.minimumWindowSize) -> WindowInfo? {
        guard pid != excludedPID else { return nil }
        return windows.first { w in
            w.ownerPID == pid && w.layer == CompanionConstants.Capture.normalWindowLayer
                && w.bounds.width >= minimumSize.width && w.bounds.height >= minimumSize.height
        }
    }

    /// The window to capture: the front-most ordinary window of the front-most app, and when that app has none
    /// to offer (it is Sidemoon itself after one of its own dialogs, or an app with no window open), the
    /// front-most ordinary window on screen that is not Sidemoon's. That is the window the user is looking at.
    public static func target(_ windows: [WindowInfo], frontmostPID: pid_t?, excludedPID: pid_t,
                              minimumSize: CGSize = CompanionConstants.Capture.minimumWindowSize) -> WindowInfo? {
        if let pid = frontmostPID, let own = pick(windows, pid: pid, excludedPID: excludedPID, minimumSize: minimumSize) { return own }
        return windows.first { w in
            w.ownerPID != excludedPID && w.layer == CompanionConstants.Capture.normalWindowLayer
                && w.bounds.width >= minimumSize.width && w.bounds.height >= minimumSize.height
        }
    }

    /// On-screen windows, front to back, desktop elements excluded.
    public static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap(WindowInfo.init)
    }
}

/// Captures the front-most window of the app the user is working in, with no selection step:
/// `/usr/sbin/screencapture -x -o -l <windowID> <file>`. The front-most app comes from the caller
/// (AppKit lives in the app target).
public struct ActiveWindowCaptureProvider: CaptureProvider {
    private let frontmostPID: @MainActor @Sendable () -> pid_t?

    public init(frontmostPID: @escaping @MainActor @Sendable () -> pid_t?) { self.frontmostPID = frontmostPID }

    public func capture(into destination: URL) async throws -> CaptureOutcome {
        let frontmost = await frontmostPID()
        guard let window = ActiveWindow.target(ActiveWindow.onScreenWindows(), frontmostPID: frontmost,
                                               excludedPID: ProcessInfo.processInfo.processIdentifier)
        else { throw CaptureError.noActiveWindow }
        let status = try await runScreencapture(CompanionConstants.Capture.windowArguments + [String(window.id), destination.path])
        guard fileSize(destination) > 0 else {
            throw CaptureError("screencapture produced no image of the active window (status \(status))")
        }
        return .captured(destination)
    }
}

/// Copies a fixed image into place, standing in for a real capture.
public struct InjectedImageCapture: CaptureProvider {
    public let source: URL
    public init(source: URL) { self.source = source }

    public func capture(into destination: URL) async throws -> CaptureOutcome {
        do { try FileManager.default.copyItem(at: source, to: destination) } catch {
            throw CaptureError("could not copy the injected image: \(error.localizedDescription)")
        }
        return .captured(destination)
    }
}

