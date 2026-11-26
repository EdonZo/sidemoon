import Foundation

/// A message that is a Claude Code command, such as `/model opus` or `/compact`. It is sent exactly as typed: no
/// reply-style note or tag, no screenshot or file lines, nothing else added, as anything added would become part of
/// the command's arguments.
///
/// The definition: on the first line, after any leading whitespace, a "/" followed by a name, then the end of the line
/// or whitespace. A name starts with a letter and goes on with letters, digits, "-", "_" or ":" (plugin commands are
/// written `/plugin:command`). So "/Users/me/file.txt is broken" is not a command (the first word has a second "/"),
/// "/ not a command" is not one, and a slash later in the text never counts.
public struct SlashCommand: Equatable, Sendable {
    /// The command's name, without the slash, as typed.
    public let name: String
    /// What follows the name, trimmed (the rest of the first line and any further lines).
    public let arguments: String

    public static func parse(_ text: String) -> SlashCommand? {
        let trimmed = text.drop { $0.isWhitespace }
        guard trimmed.first == Constants.SlashCommands.prefix else { return nil }
        let afterSlash = trimmed.dropFirst()
        let name = afterSlash.prefix { !$0.isWhitespace }
        guard let first = name.first, first.isLetter,
              name.allSatisfy({ $0.isLetter || $0.isNumber || Constants.SlashCommands.nameSymbols.contains($0) }) else { return nil }
        let rest = afterSlash.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return SlashCommand(name: String(name), arguments: rest)
    }

    public static func isCommand(_ text: String?) -> Bool { text.map { parse($0) != nil } ?? false }

    /// Whether this is the named command, in any case.
    public func `is`(_ command: String) -> Bool { name.lowercased() == command.lowercased() }
}
