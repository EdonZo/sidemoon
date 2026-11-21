import Foundation

/// Finds the local files an answer mentions, so they can be opened from the conversation.
///
/// Sessions name files in plain text ("saved to /Users/me/out/clip.mp4"), often with spaces in the name
/// and seldom as a link. A path counts only when a file really exists there, which is what makes it
/// safe to guess where a name with spaces ends: the longest run of words that names a real file wins.
public enum FileMentions {
    /// Whether a regular file (not a folder) exists at this absolute path.
    public typealias Exists = @Sendable (String) -> Bool

    public static let systemExists: Exists = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// The files mentioned in `text`, in order of first mention, without repeats.
    public static func find(in text: String, home: String = NSHomeDirectory(), exists: Exists = systemExists) -> [URL] {
        var found: [URL] = []
        var seen: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var rest = Substring(line)
            while let start = pathStart(in: rest), found.count < CompanionConstants.FileMentions.maxPerReply {
                let tail = rest[start...]
                // The path cannot run past a character no file name is written with in running text.
                let extent = tail.prefix { !CompanionConstants.FileMentions.terminators.contains($0) }
                if let path = longestExisting(String(extent), home: home, exists: exists) {
                    if seen.insert(path.resolved).inserted { found.append(URL(fileURLWithPath: path.resolved)) }
                    rest = tail.dropFirst(path.written.count)
                } else {
                    rest = tail.dropFirst()
                }
            }
        }
        return found
    }

    /// Where the next path could begin: a `/` or `~/` at the start of the line or after a separator.
    private static func pathStart(in text: Substring) -> Substring.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let opensPath = character == "/" || (character == "~" && text[index...].hasPrefix("~/"))
            if opensPath {
                let atBoundary = index == text.startIndex
                    || CompanionConstants.FileMentions.boundaries.contains(text[text.index(before: index)])
                if atBoundary { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Tries the whole run, then drops one trailing word at a time until a real file is named.
    private static func longestExisting(_ run: String, home: String, exists: Exists) -> (written: String, resolved: String)? {
        var words = run.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if words.count > CompanionConstants.FileMentions.maxWords {
            words = Array(words.prefix(CompanionConstants.FileMentions.maxWords))
        }
        while !words.isEmpty {
            var candidate = words.joined(separator: " ")
            // Sentence punctuation that follows the name is not part of it; try with and without.
            while true {
                let resolved = expand(candidate, home: home)
                if resolved.contains("/"), resolved.count > 1, exists(resolved) { return (candidate, resolved) }
                guard let last = candidate.last, CompanionConstants.FileMentions.trailingPunctuation.contains(last) else { break }
                candidate.removeLast()
            }
            words.removeLast()
        }
        return nil
    }

    private static func expand(_ path: String, home: String) -> String {
        path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }
}
