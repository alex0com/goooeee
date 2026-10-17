import Foundation

/// Finds the file a code block is meant to be saved as, for the code block's Save As button.
///
/// Models usually say it in the text before the block ("Save this as `hello.sh`:") or in the
/// block's first comment (`# hello.sh`). A block that mentions the name in its own code
/// (`bash hello.sh`) uses the file rather than being it, so that name isn't suggested.
public enum CodeFileName {
    /// The named file, or `nil` when neither the code nor the text before it names one.
    public static func suggested(code: String, precedingText: String?) -> String? {
        if let name = nameInFirstComment(code) { return name }
        guard let precedingText else { return nil }
        let paragraph = lastParagraph(precedingText)
        // The last name mentioned is the one closest to the block.
        guard let name = fileNames(in: paragraph).last(where: { !mentions(code, $0) }) else { return nil }
        return name
    }

    /// Whether the block is worth saving: it has a `#!` line or a file name was found.
    public static func isSaveable(code: String, suggestedName: String?) -> Bool {
        suggestedName != nil || code.hasPrefix("#!")
    }

    /// A fallback name from the block's language, such as `script.sh` or `script.py`.
    public static func defaultName(language: String?) -> String {
        let language = SyntaxHighlighter.normalizedLanguage(language)
        return "script." + (language.flatMap { extensions[$0] } ?? "txt")
    }

    /// The markdown before the code block whose code is `code`: text since the previous block,
    /// without the opening fence. `nil` when the block isn't found in `markdown`.
    public static func precedingText(of code: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        let firstCodeLine = code.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        var inFence = false
        var start = 0
        for (index, line) in lines.enumerated() {
            guard isFence(line) else { continue }
            if inFence {
                inFence = false
                start = index + 1
                continue
            }
            inFence = true
            // Fenced blocks inside lists are indented, so compare trimmed lines.
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            if next == firstCodeLine {
                return lines[start..<index].joined(separator: "\n")
            }
        }
        return nil
    }

    // MARK: Details

    static let extensions: [String: String] = [
        "bash": "sh", "python": "py", "javascript": "js", "typescript": "ts", "ruby": "rb", "perl": "pl",
        "swift": "swift", "go": "go", "rust": "rs", "c": "c", "cpp": "cpp", "objc": "m", "csharp": "cs",
        "java": "java", "kotlin": "kt", "php": "php", "lua": "lua", "r": "r", "sql": "sql", "html": "html",
        "css": "css", "xml": "xml", "json": "json", "yaml": "yaml", "toml": "toml", "markdown": "md",
        "dockerfile": "Dockerfile", "makefile": "Makefile", "powershell": "ps1",
    ]

    /// Extensions accepted in prose, so "example.com" or "v1.2" aren't taken for file names.
    static let knownExtensions: Set<String> = Set(extensions.values.map { $0.lowercased() }).union([
        "zsh", "bash", "fish", "command", "mjs", "cjs", "jsx", "tsx", "h", "hpp", "cc", "mm", "yml", "ini",
        "cfg", "conf", "env", "txt", "csv", "tsv", "plist", "svg", "ipynb", "vue", "svelte", "scss", "gradle",
    ])

    /// Names without an extension that are still files.
    static let bareNames: Set<String> = ["Makefile", "Dockerfile", "Gemfile", "Procfile", "Rakefile", "Brewfile", "Justfile"]

    private static let namePattern = try! NSRegularExpression(
        pattern: #"(?<![\w.-])((?:~?/)?(?:[\w.-]+/)*[\w-][\w.-]*\.([A-Za-z0-9]{1,8})|Makefile|Dockerfile|Gemfile|Procfile|Rakefile|Brewfile|Justfile)(?![\w/-])"#
    )

    private static let fencePattern = try! NSRegularExpression(pattern: #"^\s*(?:(?:[-*+]|\d+[.)])\s+)?(?:```|~~~)"#)

    /// `# hello.sh`, `// file: main.swift`, `-- filename: init.sql` on the first line after `#!`.
    private static let commentPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:#|//|--|;|/\*)\s*(?:file(?:name)?\s*:\s*)?(\S+?)\s*(?:\*/)?\s*$"#,
        options: [.caseInsensitive]
    )

    static func nameInFirstComment(_ code: String) -> String? {
        let lines = code.components(separatedBy: "\n")
        guard var line = lines.first else { return nil }
        if line.hasPrefix("#!") {
            guard lines.count > 1 else { return nil }
            line = lines[1]
        }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = commentPattern.firstMatch(in: line, range: range),
              let nameRange = Range(match.range(at: 1), in: line)
        else { return nil }
        // The comment has to be just the name, not a sentence that mentions one.
        let candidate = String(line[nameRange])
        let whole = NSRange(candidate.startIndex..., in: candidate)
        guard namePattern.firstMatch(in: candidate, range: whole)?.range == whole else { return nil }
        return fileNames(in: candidate).first
    }

    /// File names in prose, in order. Paths keep only their last component.
    static func fileNames(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return namePattern.matches(in: text, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text) else { return nil }
            let name = String(text[nameRange])
            let last = (name as NSString).lastPathComponent
            if bareNames.contains(last) { return last }
            guard let extRange = Range(match.range(at: 2), in: text),
                  knownExtensions.contains(text[extRange].lowercased())
            else { return nil }
            return last
        }
    }

    private static func lastParagraph(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return paragraphs.last(where: { !$0.isEmpty }) ?? ""
    }

    private static func mentions(_ code: String, _ name: String) -> Bool {
        fileNames(in: code).contains(name)
    }

    private static func isFence(_ line: String) -> Bool {
        // A fence can follow a list marker: "1. ```bash" or "- ```".
        let range = NSRange(line.startIndex..., in: line)
        return fencePattern.firstMatch(in: line, range: range) != nil
    }
}
