import Foundation
import Testing
@testable import GoooeeeMarkdown

@Suite("Code block file names")
struct CodeFileNameTests {
    /// The suggestion for the block whose code is `code`, the way the transcript asks for it.
    private func suggestion(for code: String, in markdown: String) -> String? {
        CodeFileName.suggested(code: code, precedingText: CodeFileName.precedingText(of: code, in: markdown))
    }

    @Test func scriptThenTheCommandThatRunsIt() {
        let reply = """
            Save this as `hello.sh`:

            ```bash
            #!/bin/bash
            echo "Hello, World!"
            ```

            Then make it executable and run it with `bash hello.sh`:

            ```bash
            bash hello.sh
            ```
            """
        let script = "#!/bin/bash\necho \"Hello, World!\""
        #expect(suggestion(for: script, in: reply) == "hello.sh")
        #expect(CodeFileName.isSaveable(code: script, suggestedName: "hello.sh"))

        // The command uses the file; offering to save it as hello.sh would overwrite the script.
        let command = "bash hello.sh"
        let name = suggestion(for: command, in: reply)
        #expect(name == nil)
        #expect(!CodeFileName.isSaveable(code: command, suggestedName: name))
    }

    @Test func nameInFirstComment() {
        #expect(CodeFileName.suggested(code: "# hello.py\nprint('hi')", precedingText: nil) == "hello.py")
        #expect(CodeFileName.suggested(code: "// file: Sources/App/main.swift\nprint(1)", precedingText: nil) == "main.swift")
        #expect(CodeFileName.suggested(code: "#!/usr/bin/env python3\n# filename: tools/hello.py\nprint(1)", precedingText: nil) == "hello.py")
        #expect(CodeFileName.suggested(code: "/* main.c */\nint main(void) { return 0; }", precedingText: nil) == "main.c")
        // A comment that's a sentence isn't a name.
        #expect(CodeFileName.suggested(code: "# Prints the contents of notes.txt\ncat notes.txt", precedingText: nil) == nil)
    }

    @Test func shebangWithoutNameIsSaveable() {
        let code = "#!/bin/zsh\nprint -P '%F{green}ok%f'"
        let name = suggestion(for: code, in: "Here's a script:\n\n```zsh\n\(code)\n```\n")
        #expect(name == nil)
        #expect(CodeFileName.isSaveable(code: code, suggestedName: name))
        #expect(!CodeFileName.isSaveable(code: "ls -la", suggestedName: nil))
    }

    @Test func runningAFileIsNotSavingIt() {
        let reply = "Run hello.sh from the same folder:\n\n```bash\n./hello.sh\n```\n"
        #expect(suggestion(for: "./hello.sh", in: reply) == nil)
        let chmod = "Make hello.sh executable:\n\n```bash\nchmod +x hello.sh && ./hello.sh\n```\n"
        #expect(suggestion(for: "chmod +x hello.sh && ./hello.sh", in: chmod) == nil)
    }

    @Test func domainsAndVersionsAreNotFiles() {
        let reply = "Download it from example.com, version 1.2.3 or v2.0:\n\n```bash\ncurl -O https://example.com/install\n```\n"
        #expect(suggestion(for: "curl -O https://example.com/install", in: reply) == nil)
    }

    @Test func indentedBlockInAList() {
        let reply = """
            1. Create `main.py`:
               ```python
               print("hi")
               ```
            2. Run it with `python3 main.py`.
            """
        // The parser removes the list indentation from the code.
        #expect(suggestion(for: "print(\"hi\")", in: reply) == "main.py")
    }

    @Test func eachBlockUsesTheTextJustBeforeIt() {
        let reply = """
            Create `a.py`:

            ```python
            x = 1
            ```

            And `b.py`:

            ```python
            y = 2
            ```
            """
        #expect(suggestion(for: "x = 1", in: reply) == "a.py")
        #expect(suggestion(for: "y = 2", in: reply) == "b.py")
    }

    @Test func onlyTheParagraphRightBeforeTheBlock() {
        let reply = """
            Earlier we wrote config.yaml.

            Now run the build:

            ```bash
            make build
            ```
            """
        #expect(suggestion(for: "make build", in: reply) == nil)
    }

    @Test func pathsAndBareNames() {
        #expect(CodeFileName.suggested(code: "rsync -a ~/Documents /Volumes/Backup", precedingText: "Save it as `~/scripts/backup.sh`:") == "backup.sh")
        #expect(CodeFileName.suggested(code: "build:\n\tswift build", precedingText: "Add this to your Makefile:") == "Makefile")
        #expect(CodeFileName.suggested(code: "x", precedingText: "Put this in **config.toml**.") == "config.toml")
    }

    @Test func blockNotFound() {
        #expect(CodeFileName.precedingText(of: "missing", in: "```bash\nls\n```\n") == nil)
    }

    @Test func defaultNames() {
        #expect(CodeFileName.defaultName(language: "bash") == "script.sh")
        #expect(CodeFileName.defaultName(language: "zsh") == "script.sh")
        #expect(CodeFileName.defaultName(language: "py") == "script.py")
        #expect(CodeFileName.defaultName(language: nil) == "script.txt")
        #expect(CodeFileName.defaultName(language: "brainfuck") == "script.txt")
    }
}
