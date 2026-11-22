import Darwin
import Foundation

/// Whether the Claude Code process that started `sidemoon channel` loads it as a channel. Only a channel's
/// pushed messages reach the session; Claude Code ignores what a plain MCP server pushes. Seen on a real Mac:
/// Claude Code hosts a session it moved to the background in a process started with `--mcp-config` but without
/// the development-channels flag, so the helper runs there and connects, yet nothing it pushes arrives.
public enum ChannelRole: String, Sendable, Equatable, Codable {
    /// The parent's arguments load the Sidemoon channel.
    case channel
    /// The parent's arguments were read and do not load it.
    case notChannel
    /// The arguments could not be read (or an older helper did not say).
    case unknown

    /// The role given by a parent's arguments; nil means they could not be read.
    public static func of(arguments: [String]?) -> ChannelRole {
        guard let arguments else { return .unknown }
        return loadsSidemoonChannel(arguments) ? .channel : .notChannel
    }

    /// The role of the process that started this one.
    public static func ofParent() -> ChannelRole { of(arguments: ProcessArguments.read(pid: getppid())) }

    /// True when a channel flag (the development-channels flag or `--channels`) names the Sidemoon server, as
    /// `--flag value...` (values run until the next flag), `--flag=value`, or a comma- or space-separated list.
    static func loadsSidemoonChannel(_ args: [String]) -> Bool {
        let cli = Constants.ClaudeCLI.self
        let flags = [cli.channelLaunchFlags[1], cli.channelsFlag]
        let wanted = cli.channelLaunchValue
        func names(_ value: Substring) -> Bool {
            value.split(whereSeparator: { cli.channelListSeparators.contains($0) }).contains { $0 == wanted }
        }
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if let flag = flags.first(where: { arg.hasPrefix($0 + String(cli.flagValueSeparator)) }) {
                if names(arg.dropFirst(flag.count + 1)) { return true }
                continue
            }
            guard flags.contains(arg) else { continue }
            while index < args.count, !args[index].hasPrefix(cli.flagPrefix) {
                if names(Substring(args[index])) { return true }
                index += 1
            }
        }
        return false
    }
}

/// A process's command line, read with `sysctl` (KERN_PROCARGS2), the same source `ps` uses.
public enum ProcessArguments {
    public static func read(pid: pid_t) -> [String]? {
        guard pid > 1 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    /// The buffer is: argc (a 32-bit integer), the executable path, NUL padding, then argc NUL-terminated
    /// arguments (argv[0] first), then the environment. Returns argv without argv[0].
    static func parse(_ buffer: [UInt8]) -> [String]? {
        let countSize = MemoryLayout<Int32>.size
        guard buffer.count > countSize else { return nil }
        let argc = buffer.prefix(countSize).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return nil }
        var index = countSize
        // The executable path, then the padding after it.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        guard args.count == argc else { return nil }
        return Array(args.dropFirst())
    }
}
