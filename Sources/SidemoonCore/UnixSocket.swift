import Darwin
import Foundation

public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    init(_ what: String) { description = "\(what): \(String(cString: strerror(errno)))" }
    init(message: String) { description = message }
}

/// Minimal blocking Unix domain socket helpers.
public enum UnixSocket {

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError(message: "socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    /// Creates the listening socket, owner-only. Refuses if another engine is already listening.
    public static func listen(path: String) throws -> Int32 {
        if let probe = try? connect(path: path, timeout: Constants.Timeouts.socketSend) {
            close(probe)
            throw SocketError(message: "an engine is already listening on \(path)")
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        var addr = try address(path)
        // No umask change here: it is process-wide and would affect files other threads create meanwhile.
        // The socket lives in an owner-only directory and is restricted before it starts listening.
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw SocketError("bind \(path)") }
        guard chmod(path, Constants.Permissions.socket) == 0 else { close(fd); unlink(path); throw SocketError("chmod \(path)") }
        guard Darwin.listen(fd, Constants.Limits.listenBacklog) == 0 else { close(fd); throw SocketError("listen") }
        return fd
    }

    /// Connects, or returns nil quickly when nothing is listening.
    public static func connect(path: String, timeout: TimeInterval) throws -> Int32? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, SO_SNDTIMEO, timeout)
        var addr = try address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); return nil }
        return fd
    }

    public static func setTimeout(_ fd: Int32, _ option: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// True when the peer runs as the same user as this process.
    public static func peerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
}

/// Newline-delimited messages over a connected socket. Writes are serialized.
public final class LineConnection: @unchecked Sendable {
    public let fd: Int32
    private var buffer = Data()
    private let writeLock = NSLock()
    private let closeLock = NSLock()
    private var closed = false

    public init(fd: Int32) {
        self.fd = fd
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    /// Reads one line (without the newline). Nil on EOF, error, timeout or an oversized line.
    public func readLine() -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                return Data(line)
            }
            guard buffer.count <= Constants.Limits.maxMessageBytes else { return nil }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                if n < 0, errno == EINTR { continue }
                return nil
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    @discardableResult
    public func writeLine(_ data: Data) -> Bool {
        writeLock.withLock {
            var payload = data
            payload.append(UInt8(ascii: "\n"))
            return payload.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { return false }
                    off += n
                }
                return true
            }
        }
    }

    public func writeJSON(_ object: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return writeLine(data)
    }

    public func readJSON() -> [String: Any]? {
        guard let line = readLine() else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    public func close() {
        closeLock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }

    /// Unblocks a pending read from another thread.
    public func shutdownBoth() { Darwin.shutdown(fd, SHUT_RDWR) }
}
