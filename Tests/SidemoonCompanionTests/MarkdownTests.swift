import Testing
@testable import SidemoonCompanion

@Suite struct MarkdownTests {
    @Test func headingsParagraphsAndRules() {
        let blocks = Markdown.parse("# Title\n\nFirst line\nsecond line\n\n---\n\n### Sub ##\n#notaheading")
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("First line\nsecond line"),
            .rule,
            .heading(level: 3, text: "Sub"),
            .paragraph("#notaheading"),
        ])
    }

    @Test func bulletAndNumberedListsWithNestingAndContinuation() {
        let blocks = Markdown.parse("- one\n  - nested\n- two\n  continues here\n\n1. first\n2) second")
        #expect(blocks == [
            .list([
                MarkdownListItem(depth: 0, number: nil, text: "one"),
                MarkdownListItem(depth: 1, number: nil, text: "nested"),
                MarkdownListItem(depth: 0, number: nil, text: "two\ncontinues here"),
            ]),
            .list([
                MarkdownListItem(depth: 0, number: "1", text: "first"),
                MarkdownListItem(depth: 0, number: "2", text: "second"),
            ]),
        ])
    }

    @Test func listEndsAtParagraph() {
        let blocks = Markdown.parse("- one\n\nAfter the list")
        #expect(blocks == [.list([MarkdownListItem(depth: 0, number: nil, text: "one")]), .paragraph("After the list")])
    }

    @Test func fencedCodeKeepsContentVerbatim() {
        let blocks = Markdown.parse("Run:\n```swift\nlet a = 1\n\n# not a heading\n```\nDone")
        #expect(blocks == [
            .paragraph("Run:"),
            .code(language: "swift", text: "let a = 1\n\n# not a heading"),
            .paragraph("Done"),
        ])
    }

    @Test func unclosedFenceTakesTheRest() {
        #expect(Markdown.parse("```\nabc") == [.code(language: nil, text: "abc")])
    }

    @Test func quotesAndTables() {
        let blocks = Markdown.parse("> quoted\n> more\n\n| Name | State |\n|---|:--:|\n| a | idle |\n| b |\n")
        #expect(blocks == [
            .quote("quoted\nmore"),
            .table(header: ["Name", "State"], rows: [["a", "idle"], ["b", ""]]),
        ])
    }

    @Test func pipeWithoutSeparatorIsAParagraph() {
        #expect(Markdown.parse("a | b") == [.paragraph("a | b")])
    }

    @Test func boldLineIsNotARuleOrList() {
        #expect(Markdown.parse("**Likely cause:** text") == [.paragraph("**Likely cause:** text")])
        #expect(Markdown.parse("***") == [.rule])
    }

    @Test func emptyTextHasNoBlocks() {
        #expect(Markdown.parse("\n\n  \n").isEmpty)
    }
}
