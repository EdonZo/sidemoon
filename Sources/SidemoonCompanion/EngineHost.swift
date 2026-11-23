import Foundation
import SidemoonCore

public enum EngineStartOutcome: Equatable, Sendable {
    case running
    /// Another process (usually `sidemoon serve`) already answers on the socket.
    case conflict
}

/// What the companion needs from the engine. A protocol so the view model can be tested with a fake.
public protocol CompanionEngine: AnyObject, Sendable {
    func start() throws -> EngineStartOutcome
    func stop()
    func sessions() -> [Session]
    /// Called on an arbitrary thread whenever a session changes.
    func subscribe(_ handler: @escaping @Sendable (Session) -> Void)
    /// Blocking; call it off the main thread.
    func send(_ request: SendRequest) -> SendResult
    /// Starts a new background session with its first message. Blocking (a few seconds); call it off the main thread.
    func startSession(_ request: NewSessionRequest) -> NewSessionResult
    /// Claude Code on this Mac has refused to reopen a background session in the home folder (`HomeFolderMemory`).
    func homeFolderRefused() -> Bool
}

/// Runs the stage 1 Engine inside the app process, so no `sidemoon serve` is needed.
public final class InProcessEngine: CompanionEngine, @unchecked Sendable {
    public let engine: Engine
    private let lock = NSLock()
    private var started = false

    public init(engine: Engine = Engine()) { self.engine = engine }

    public func start() throws -> EngineStartOutcome {
        try lock.withLock {
            if started { return .running }
            // Never take the socket from a live engine: probe it first.
            if let probe = try UnixSocket.connect(path: engine.socketPath, timeout: Constants.Timeouts.socketSend) {
                close(probe)
                return .conflict
            }
            do {
                try engine.start()
            } catch let e as SocketError where e.description.contains("already listening") {
                return .conflict
            }
            started = true
            return .running
        }
    }

    public func stop() {
        lock.withLock {
            guard started else { return }
            started = false
            engine.stop()
        }
    }

    public func sessions() -> [Session] { engine.registry.snapshot() }

    public func subscribe(_ handler: @escaping @Sendable (Session) -> Void) {
        engine.registry.subscribe { change in
            guard case let .updated(s) = change else { return }
            handler(s)
        }
    }

    public func send(_ request: SendRequest) -> SendResult { engine.send(request) }

    public func startSession(_ request: NewSessionRequest) -> NewSessionResult { engine.startSession(request) }

    public func homeFolderRefused() -> Bool { engine.registry.homeFolderMemory.refused }
}
