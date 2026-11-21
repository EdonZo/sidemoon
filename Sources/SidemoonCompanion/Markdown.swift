import Foundation

/// One block of an agent's reply. Inline formatting (bold, italic, code, links) stays in the text
/// and is rendered by the view.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case code(language: String?, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

public struct MarkdownListItem: Equatable, Sendable {
    /// Nesting depth, 0 for top level.
    public let depth: Int
    /// The number of an ordered item ("3" for "3."), nil for a bullet.
    public let number: String?
    public let text: String

    public init(depth: Int, number: String?, text: String) {
        self.depth = depth
        self.number = number
        self.text = text
    }
}

/// A small block-level Markdown parser covering what coding agents write: headings, paragraphs,
/// bullet and numbered lists, fenced code, block quotes, tables and rules.
public enum Markdown {
    enum Syntax {
        static let fences = ["```", "~~~"]
        static let maxHeadingLevel = 6
        static let ruleCharacters: Set<Character> = ["-", "*", "_"]
        static let minimumRuleLength = 3
        static let bulletMarkers: Set<Character> = ["-", "*", "+"]
        static let orderedDelimiters: Set<Character> = [".", ")"]
        static let quoteMarker: Character = ">"
        static let cellSeparator: Character = "|"
        /// Spaces of indentation that make one level of list nesting.
        static let indentPerLevel = 2
        static let tabWidth = 4
    }

    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            if let fence = Syntax.fences.first(where: { trimmed.hasPrefix($0) }) {
                flushParagraph()
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i])
                    i += 1
                }
                i += 1 // closing fence, or the end of the text when the fence was never closed
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }

            if let heading = heading(trimmed) { flushParagraph(); blocks.append(heading); i += 1; continue }
            if isRule(trimmed) { flushParagraph(); blocks.append(.rule); i += 1; continue }

            if trimmed.first == Syntax.quoteMarker {
                flushParagraph()
                var body: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.first == Syntax.quoteMarker else { break }
                    body.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(body.joined(separator: "\n")))
                continue
            }

            if trimmed.contains(Syntax.cellSeparator), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains(Syntax.cellSeparator) else { break }
                    var row = cells(t)
                    // Every row gets exactly as many cells as the header.
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if listItem(line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while i < lines.count {
                    let current = lines[i]
                    if let item = listItem(current) {
                        // Bullets followed by numbers (or the reverse) at the top level are two lists.
                        if item.depth == 0, let first = items.first(where: { $0.depth == 0 }),
                           (first.number == nil) != (item.number == nil) { break }
                        items.append(item)
                        i += 1
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty, indentation(current) > 0, !items.isEmpty {
                        // An indented line continues the item above it.
                        let last = items.removeLast()
                        items.append(MarkdownListItem(depth: last.depth, number: last.number,
                                                      text: last.text + "\n" + current.trimmingCharacters(in: .whitespaces)))
                        i += 1
                    } else if current.trimmingCharacters(in: .whitespaces).isEmpty, i + 1 < lines.count, listItem(lines[i + 1]) != nil {
                        i += 1 // a blank line between items of the same list
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= Syntax.maxHeadingLevel else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes ("## Title ##") are decoration.
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= Syntax.minimumRuleLength, let first = marks.first, Syntax.ruleCharacters.contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains(Syntax.cellSeparator) || t.contains(":") || t.allSatisfy({ $0 == "-" }) else { return false }
        let parts = cells(t)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// Splits a table row into trimmed cells, ignoring the optional outer pipes.
    static func cells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.first == Syntax.cellSeparator { t.removeFirst() }
        if t.last == Syntax.cellSeparator { t.removeLast() }
        return t.split(separator: Syntax.cellSeparator, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func indentation(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 } else if ch == "\t" { width += Syntax.tabWidth } else { break }
        }
        return width
    }

    static func listItem(_ line: String) -> MarkdownListItem? {
        let depth = indentation(line) / Syntax.indentPerLevel
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first else { return nil }
        if Syntax.bulletMarkers.contains(first) {
            let rest = body.dropFirst()
            guard rest.first == " " else { return nil }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return MarkdownListItem(depth: depth, number: nil, text: text)
        }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, Syntax.orderedDelimiters.contains(delimiter) else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownListItem(depth: depth, number: String(digits), text: text)
    }
}
