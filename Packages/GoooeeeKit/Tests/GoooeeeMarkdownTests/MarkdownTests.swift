import Testing
@testable import GoooeeeMarkdown

@Suite("Markdown parsing")
struct MarkdownParsingTests {
    @Test func paragraphsHeadingsAndInlines() {
        let blocks = MarkdownParser.parse("# Title\n\nSome **bold** and *italic* and `code` with [a link](https://example.com).")
        #expect(blocks.count == 2)
        #expect(blocks[0] == .heading(level: 1, [.text("Title")]))
        guard case .paragraph(let inlines) = blocks[1] else {
            Issue.record("expected paragraph")
            return
        }
        #expect(inlines.contains(.strong([.text("bold")])))
        #expect(inlines.contains(.emphasis([.text("italic")])))
        #expect(inlines.contains(.code("code")))
        #expect(inlines.contains(.link(destination: "https://example.com", children: [.text("a link")])))
    }

    @Test func codeBlockWithLanguage() {
        let blocks = MarkdownParser.parse("```swift\nlet x = 1\n```\n")
        #expect(blocks == [.codeBlock(language: "swift", code: "let x = 1", isOpen: false)])
    }

    @Test func gfmTableAndTaskList() {
        let source = """
            | A | B |
            |:--|--:|
            | 1 | 2 |

            - [x] done
            - [ ] todo
            """
        let blocks = MarkdownParser.parse(source)
        guard case .table(let table) = blocks.first else {
            Issue.record("expected table")
            return
        }
        #expect(table.alignments == [.left, .right])
        #expect(table.header.map(\.plainText) == ["A", "B"])
        #expect(table.rows.first?.map(\.plainText) == ["1", "2"])
        guard case .list(let list) = blocks.last else {
            Issue.record("expected list")
            return
        }
        #expect(list.items.map(\.checkbox) == [true, false])
    }

    @Test func inlineAndDisplayMath() {
        let blocks = MarkdownParser.parse("Euler: $e^{i\\pi} + 1 = 0$ is neat.\n\n$$\n\\int_0^1 x^2 \\, dx\n$$\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("expected paragraph")
            return
        }
        #expect(inlines.contains(.math("e^{i\\pi} + 1 = 0")))
        #expect(blocks.last == .mathBlock("\\int_0^1 x^2 \\, dx"))
    }

    @Test func currencyIsNotMath() {
        let blocks = MarkdownParser.parse("It costs $5 and $10 today.")
        #expect(blocks == [.paragraph([.text("It costs $5 and $10 today.")])])
    }

    @Test func mathInsideCodeIsLeftAlone() {
        let blocks = MarkdownParser.parse("Use `$HOME/$USER` here.")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("expected paragraph")
            return
        }
        #expect(inlines.contains(.code("$HOME/$USER")))
        #expect(!inlines.contains { if case .math = $0 { return true } else { return false } })
    }

    @Test func bracketDelimiters() {
        let blocks = MarkdownParser.parse("Inline \\(a^2\\) and display:\n\n\\[b^2\\]\n")
        guard case .paragraph(let inlines) = blocks.first else {
            Issue.record("expected paragraph")
            return
        }
        #expect(inlines.contains(.math("a^2")))
        #expect(blocks.last == .mathBlock("b^2"))
    }
}

@Suite("Incremental markdown")
struct IncrementalMarkdownTests {
    static let sample = """
        # Plan

        First paragraph with **bold** text
        that spans two lines.

        - item one
        - item two

        ```python
        def f(x):
            return x * 2

        print(f(2))
        ```

        | Col | Value |
        |-----|-------|
        | a   | 1     |

        Formula: $x^2$ and a block:

        $$
        y = mx + b
        $$

        1. first
        2. second

           continuation paragraph

        Final words.
        """

    /// Feeding text in small chunks must give the same blocks as parsing it all at once.
    @Test(arguments: [1, 3, 7, 16, 64])
    func incrementalMatchesFullParse(chunkSize: Int) {
        var engine = IncrementalMarkdown()
        let characters = Array(Self.sample)
        var text = ""
        var index = 0
        while index < characters.count {
            let end = min(index + chunkSize, characters.count)
            text += String(characters[index..<end])
            _ = engine.update(text)
            index = end
        }
        let incremental = engine.update(text, isFinal: true).flatMap { $0.items.map(\.block) }
        let full = MarkdownParser.parse(Self.sample)
        #expect(incremental.map(\.plainText) == full.map(\.plainText))
        #expect(incremental.count == full.count)
    }

    @Test func freezesCompletedBlocksAndKeepsTailLive() {
        var engine = IncrementalMarkdown()
        let rows = engine.update("Para one.\n\nPara two.\n\nPara thr")
        #expect(engine.frozenCharacterCount > 0)
        let items = rows.flatMap(\.items)
        #expect(items.filter(\.isFrozen).count == 2)
        #expect(items.last?.isFrozen == false)
        // Prose blocks share one row so text can be selected across paragraphs.
        #expect(rows.count == 1)
        #expect(rows[0].id == "0")
    }

    @Test func openFenceIsMarkedOpen() {
        var engine = IncrementalMarkdown()
        let rows = engine.update("Intro\n\n```swift\nlet a = 1\nlet b")
        guard let last = rows.last, case .codeBlock(let language, let code, let isOpen) = last.items.last?.block else {
            Issue.record("expected an open code block")
            return
        }
        #expect(language == "swift")
        #expect(code.hasPrefix("let a = 1"))
        #expect(isOpen)
        #expect(last.kind == .code)
    }

    @Test func rowIDsAreStableWhileStreaming() {
        var engine = IncrementalMarkdown()
        let first = engine.update("Hello\n\n```js\nx\n```\n\nAfter")
        let second = engine.update("Hello\n\n```js\nx\n```\n\nAfter the code block, more text.")
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.kind) == [.prose, .code, .prose])
    }

    @Test func resetsWhenTextIsNotAnExtension() {
        var engine = IncrementalMarkdown()
        _ = engine.update("Alpha\n\nBeta\n\nGamma")
        let rows = engine.update("Different text")
        #expect(rows.flatMap(\.items).map(\.block.plainText) == ["Different text"])
    }

    @Test func listItemsWithBlankLinesStayInOneList() {
        let rows = IncrementalMarkdown.render("1. a\n\n   more a\n2. b\n")
        let blocks = rows.flatMap(\.items).map(\.block)
        #expect(blocks.count == 1)
        guard case .list(let list) = blocks.first else {
            Issue.record("expected list")
            return
        }
        #expect(list.items.count == 2)
    }
}
