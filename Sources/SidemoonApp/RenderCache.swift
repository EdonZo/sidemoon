import Foundation
import SidemoonCompanion

/// Work that redrawing a conversation would otherwise repeat for every answer on every pass: parsing
/// its Markdown, and checking the disk for the files it mentions. The window redraws often (a new
/// message, a resize, a hover), and a long conversation has many answers.
@MainActor
enum RenderCache {
    private static var blocks: [String: [MarkdownBlock]] = [:]
    private static var files: [String: (found: [URL], checked: Date)] = [:]

    /// The parsed form of an answer. An answer's text never changes, so this is parsed once.
    static func parsed(_ source: String) -> [MarkdownBlock] {
        if let cached = blocks[source] { return cached }
        if blocks.count >= CompanionConstants.Thread.renderCacheLimit { blocks.removeAll(keepingCapacity: true) }
        let result = Markdown.parse(source)
        blocks[source] = result
        return result
    }

    /// The files an answer mentions that exist. Looked up again after a while, since a file the
    /// session is still writing may appear a moment after the answer does.
    static func mentionedFiles(in text: String, now: Date = Date()) -> [URL] {
        if let cached = files[text], now.timeIntervalSince(cached.checked) < CompanionConstants.Thread.fileMentionsLifetime {
            return cached.found
        }
        if files.count >= CompanionConstants.Thread.renderCacheLimit { files.removeAll(keepingCapacity: true) }
        let found = FileMentions.find(in: text)
        files[text] = (found, now)
        return found
    }
}
