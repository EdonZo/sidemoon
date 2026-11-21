import AppKit
import SwiftUI
import SidemoonCompanion

/// Inline Markdown (bold, italic, code, links) as styled text.
enum InlineMarkdown {
    static func attributed(_ source: String, color: Color = .ink) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var text = try? AttributedString(markdown: source, options: options) else { return AttributedString(source) }
        let runs = text.runs.map { (range: $0.range, isCode: $0.inlinePresentationIntent?.contains(.code) == true, isLink: $0.link != nil) }
        for run in runs {
            if run.isCode {
                text[run.range].swiftUI.font = Font.system(size: Design.TypeScale.inlineCode, design: .monospaced)
                text[run.range].swiftUI.backgroundColor = Color.paper2
            }
            if run.isLink {
                text[run.range].swiftUI.foregroundColor = color
                text[run.range].swiftUI.underlineStyle = Text.LineStyle.single
            }
        }
        return text
    }
}

/// An agent's reply rendered as headings, paragraphs, lists, code, quotes, tables and rules.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    @MainActor init(_ source: String) { blocks = RenderCache.parsed(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : spacingBefore(block))
                    .padding(.bottom, spacingAfter(block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .tint(.signal)
    }

    private func spacingBefore(_ block: MarkdownBlock) -> CGFloat {
        switch block {
        case .heading(1, _): return Design.Prose.h1Before
        case .heading: return Design.Prose.h2Before
        case .rule: return Design.Prose.ruleSpacing
        default: return 0
        }
    }

    private func spacingAfter(_ block: MarkdownBlock) -> CGFloat {
        switch block {
        case .heading(1, _): return Design.Prose.h1After
        case .heading: return Design.Prose.h2After
        case .rule: return Design.Prose.ruleSpacing
        default: return Design.Prose.paragraphSpacing
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text): heading(level, text)
        case let .paragraph(text): prose(text)
        case let .list(items): list(items)
        case let .code(language, text): CodeBlockView(language: language, code: text)
        case let .quote(text): quote(text)
        case let .table(header, rows): table(header, rows)
        case .rule: Rectangle().fill(Color.line).frame(height: Design.Bubble.hairline)
        }
    }

    private func prose(_ text: String, color: Color = .ink) -> some View {
        Text(InlineMarkdown.attributed(text, color: color))
            .font(.prose)
            .foregroundStyle(color)
            .lineSpacing(Design.TypeScale.bodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func heading(_ level: Int, _ text: String) -> some View {
        switch level {
        case 1:
            Text(InlineMarkdown.attributed(text))
                .font(.text(Design.TypeScale.h1, weight: .semibold))
                .tracking(Design.TypeScale.headingTracking)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        case 2:
            Text(InlineMarkdown.attributed(text))
                .font(.text(Design.TypeScale.h2, weight: .semibold))
                .tracking(Design.TypeScale.headingTracking)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        default:
            // Lower headings speak in the readout voice.
            ReadoutText(text)
        }
    }

    private func list(_ items: [MarkdownListItem]) -> some View {
        VStack(alignment: .leading, spacing: Design.Prose.listItemSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Design.Prose.numberGap) {
                    if let number = item.number {
                        Text("\(number).")
                            .font(.system(size: Design.TypeScale.small, design: .monospaced))
                            .foregroundStyle(Color.signal)
                            .frame(minWidth: Design.Prose.numberColumn, alignment: .trailing)
                    } else {
                        Circle()
                            .fill(Color.signal)
                            .frame(width: Design.Prose.bulletSize, height: Design.Prose.bulletSize)
                            .frame(width: Design.Prose.listIndent - Design.Prose.numberGap, alignment: .center)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + Design.Prose.bulletSize }
                    }
                    prose(item.text)
                }
                .padding(.leading, CGFloat(item.depth) * Design.Prose.listIndent)
            }
        }
    }

    private func quote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Design.Prose.quoteIndent - Design.Prose.quoteBar) {
            Rectangle().fill(Color.signal).frame(width: Design.Prose.quoteBar)
            prose(text, color: .mute)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Every column gets a definite width: as wide as its longest cell, up to a limit. A cell longer
    /// than the limit wraps inside its column and its row grows with it, so rows never overlap. A table
    /// wider than the bubble scrolls sideways.
    private func table(_ header: [String], _ rows: [[String]]) -> some View {
        let gap = Design.Prose.tableColumnGap
        let widths = Self.columnWidths(header: header, rows: rows, gap: gap,
                                       available: Design.Bubble.width - Design.Space.bubbleHorizontal * 2)
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        ReadoutText(cell).frame(width: widths[column], alignment: .leading)
                    }
                }
                .padding(.vertical, Design.Prose.tableCellVertical)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(Color.line).frame(height: Design.Bubble.hairline)
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            Text(InlineMarkdown.attributed(cell))
                                .font(.text(Design.TypeScale.table))
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: column < widths.count ? widths[column] : Design.Prose.tableColumnMin, alignment: .leading)
                        }
                    }
                    .padding(.vertical, Design.Prose.tableCellVertical)
                }
            }
        }
    }

    /// The width each column needs, measured from its text and kept within the column limits.
    /// When the table would be wider than `available`, the widest column gives up width (its text wraps)
    /// so the whole table stays in view; only a table that still does not fit scrolls sideways.
    static func columnWidths(header: [String], rows: [[String]], gap: CGFloat, available: CGFloat) -> [CGFloat] {
        var widths = naturalWidths(header: header, rows: rows)
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
        if total > available, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            let others = total - widths[widest]
            widths[widest] = max(Design.Prose.tableColumnWrapMin, min(widths[widest], available - others))
        }
        return widths
    }

    static func naturalWidths(header: [String], rows: [[String]]) -> [CGFloat] {
        let design: NSFontDescriptor.SystemDesign = Design.theme.isMonospaced ? .monospaced : .default
        func font(_ size: CGFloat, bold: Bool, mono: Bool) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            return base.fontDescriptor.withDesign(mono ? .monospaced : design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
        // Measured as bold, without the Markdown marks, so emphasised cells still fit on one line.
        let body = font(Design.TypeScale.table, bold: true, mono: false)
        let label = font(Design.TypeScale.label, bold: false, mono: true)
        func width(_ text: String, _ font: NSFont, tracking: CGFloat = 0) -> CGFloat {
            let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            return (plain as NSString).size(withAttributes: [.font: font]).width + tracking * CGFloat(plain.count)
        }
        return header.indices.map { column in
            var widest = width(header[column].uppercased(), label, tracking: Design.TypeScale.labelTracking)
            for row in rows where column < row.count { widest = max(widest, width(row[column], body)) }
            return min(Design.Prose.tableColumnMax, max(Design.Prose.tableColumnMin, widest.rounded(.up) + Design.Prose.tableColumnSlack))
        }
    }
}

/// A fenced code block: mono text on a quiet fill, its language in the corner, and its own copy.
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack {
                if let language { ReadoutText(language) }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + CompanionConstants.Timing.copiedConfirmation) { copied = false }
                } label: {
                    ReadoutText(copied ? Design.Copy.copied : Design.Copy.copy, color: copied ? .signal : .mute)
                }
                .buttonStyle(PressStyle())
                .opacity(hovering || copied || language != nil ? 1 : 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.code)
                    .foregroundStyle(Color.ink)
                    .lineSpacing(Design.TypeScale.codeLineSpacing)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(.vertical, Design.Prose.codePaddingVertical)
        .padding(.horizontal, Design.Prose.codePaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Color.paper2))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Color.line, lineWidth: Design.Bubble.hairline))
        .onHover { hovering = $0 }
    }
}
