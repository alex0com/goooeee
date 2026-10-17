import Foundation

public enum SyntaxTokenKind: String, Sendable, Hashable, CaseIterable {
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case attribute
    case variable
    case property
    case tag
    case literal
    case meta
    case inserted
    case deleted
}

/// A highlighted range in UTF-16 offsets (ready for `NSAttributedString`).
public struct SyntaxToken: Sendable, Hashable {
    public var location: Int
    public var length: Int
    public var kind: SyntaxTokenKind

    public init(location: Int, length: Int, kind: SyntaxTokenKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }
}

/// A fast, dependency-free syntax highlighter for code blocks.
///
/// One combined regular expression per language, applied in a single pass. Runs off the main
/// thread; results are cached by the app per code block. Covers the languages models produce
/// most often; anything else gets a generic strings/numbers/comments pass.
public enum SyntaxHighlighter {
    public static func tokens(for code: String, language: String?) -> [SyntaxToken] {
        guard !code.isEmpty else { return [] }
        let spec = LanguageSpec.spec(for: language)
        guard let regex = spec.regex else { return [] }
        let nsCode = code as NSString
        var tokens: [SyntaxToken] = []
        regex.enumerateMatches(in: code, options: [], range: NSRange(location: 0, length: nsCode.length)) { match, _, _ in
            guard let match else { return }
            for (index, kind) in spec.kinds.enumerated() {
                let range = match.range(at: index + 1)
                if range.location != NSNotFound, range.length > 0 {
                    var resolved = kind
                    if kind == .function, spec.keywords.contains(nsCode.substring(with: range)) {
                        resolved = .keyword
                    }
                    tokens.append(SyntaxToken(location: range.location, length: range.length, kind: resolved))
                    break
                }
            }
        }
        return tokens
    }

    /// Canonical language name for a fence info string (`py` → `python`, `sh` → `bash`, …).
    public static func normalizedLanguage(_ name: String?) -> String? {
        guard let name = name?.lowercased().trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return LanguageSpec.aliases[name] ?? name
    }

    /// Display name for the code block header.
    public static func displayName(_ language: String?) -> String {
        guard let canonical = normalizedLanguage(language) else { return "text" }
        return LanguageSpec.displayNames[canonical] ?? canonical
    }

    /// Shell-like languages get a "Run in terminal" button.
    public static func isShell(_ language: String?) -> Bool {
        ["bash", "shell", "console"].contains(normalizedLanguage(language) ?? "")
    }

    /// Languages with a "Preview" button.
    public static func isPreviewable(_ language: String?) -> Bool {
        ["html", "svg", "xml"].contains(normalizedLanguage(language) ?? "")
    }
}

struct LanguageSpec: @unchecked Sendable {
    let regex: NSRegularExpression?
    let kinds: [SyntaxTokenKind]
    let keywords: Set<String>

    init(rules: [(pattern: String, kind: SyntaxTokenKind)], keywords: Set<String> = [], caseInsensitive: Bool = false) {
        kinds = rules.map(\.kind)
        self.keywords = keywords
        guard !rules.isEmpty else {
            regex = nil
            return
        }
        let combined = rules.map { "(\($0.pattern))" }.joined(separator: "|")
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseInsensitive { options.insert(.caseInsensitive) }
        regex = try? NSRegularExpression(pattern: combined, options: options)
    }

    static let aliases: [String: String] = [
        "py": "python", "python3": "python", "sh": "bash", "zsh": "bash", "shell": "bash", "console": "bash", "shellscript": "bash",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "node": "javascript", "ts": "typescript", "tsx": "typescript",
        "c++": "cpp", "cc": "cpp", "hpp": "cpp", "h": "c", "objective-c": "objc", "objectivec": "objc", "cs": "csharp", "c#": "csharp",
        "rs": "rust", "golang": "go", "kt": "kotlin", "kts": "kotlin", "rb": "ruby", "yml": "yaml", "md": "markdown",
        "html5": "html", "htm": "html", "svg": "xml", "plist": "xml", "jsonc": "json", "json5": "json", "patch": "diff",
        "docker": "dockerfile", "psql": "sql", "mysql": "sql", "postgres": "sql", "sqlite": "sql", "ini": "toml", "cfg": "toml",
        "scss": "css", "less": "css", "mm": "objc",
    ]

    static let displayNames: [String: String] = [
        "python": "Python", "bash": "Shell", "javascript": "JavaScript", "typescript": "TypeScript", "cpp": "C++", "c": "C",
        "objc": "Objective-C", "csharp": "C#", "rust": "Rust", "go": "Go", "kotlin": "Kotlin", "ruby": "Ruby", "yaml": "YAML",
        "json": "JSON", "html": "HTML", "xml": "XML", "css": "CSS", "sql": "SQL", "swift": "Swift", "java": "Java",
        "toml": "TOML", "diff": "Diff", "dockerfile": "Dockerfile", "markdown": "Markdown", "php": "PHP", "lua": "Lua",
        "dart": "Dart", "scala": "Scala", "r": "R", "julia": "Julia", "haskell": "Haskell", "zig": "Zig",
    ]

    // MARK: Shared patterns

    static let slashComment = #"//[^\n]*|/\*[\s\S]*?(?:\*/|$)"#
    static let hashComment = #"#[^\n]*"#
    static let doubleString = #""(?:\\.|[^"\\\n])*"?"#
    static let singleString = #"'(?:\\.|[^'\\\n])*'?"#
    static let backtickString = #"`(?:\\.|[^`\\])*`?"#
    static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)[a-zA-Z]*\b"#
    static let typeName = #"\b[A-Z][A-Za-z0-9_]*\b"#
    static let functionCall = #"\b[a-zA-Z_][A-Za-z0-9_]*(?=\s*\()"#
    static let attribute = #"@[A-Za-z_][\w.]*"#

    static func words(_ list: String) -> Set<String> {
        Set(list.split(separator: " ").map(String.init))
    }

    static func keywordPattern(_ keywords: Set<String>) -> String {
        #"\b(?:"# + keywords.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#
    }

    static func cLike(keywords: Set<String>, literals: Set<String>, extraStrings: [String] = [], preprocessor: Bool = false, attributes: Bool = false) -> LanguageSpec {
        var rules: [(String, SyntaxTokenKind)] = [(slashComment, .comment)]
        for pattern in extraStrings { rules.append((pattern, .string)) }
        rules += [(doubleString, .string), (singleString, .string)]
        if preprocessor { rules.append((#"^\s*#\s*\w+"#, .meta)) }
        if attributes { rules.append((attribute, .attribute)) }
        rules += [
            (keywordPattern(literals), .literal),
            (keywordPattern(keywords), .keyword),
            (number, .number),
            (typeName, .type),
            (functionCall, .function),
        ]
        return LanguageSpec(rules: rules, keywords: keywords)
    }

    // MARK: Languages

    static let swiftKeywords = words("actor any as associatedtype async await break case catch class consume continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect init inout internal is isolated lazy let macro mutating nonisolated nonmutating open operator optional override package private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet sending borrowing consuming")
    static let jsKeywords = words("as async await break case catch class const constructor continue debugger declare default delete do else enum export extends finally for from function get if implements import in instanceof interface let new of package private protected public readonly return set static super switch this throw try type typeof var void while with yield keyof namespace abstract")
    static let pythonKeywords = words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda match case nonlocal not or pass raise return try while with yield self cls print")
    static let rustKeywords = words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while macro_rules")
    static let goKeywords = words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")
    static let cKeywords = words("auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while class namespace template typename public private protected virtual override using new delete this throw try catch operator friend constexpr noexcept auto nullptr_t bool explicit mutable static_cast dynamic_cast reinterpret_cast const_cast co_await co_return co_yield concept requires")
    static let javaKeywords = words("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while var record sealed permits yield fun val when object companion data suspend inline reified lateinit init is in out by override open internal typealias")
    static let rubyKeywords = words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require attr_accessor attr_reader puts")
    static let phpKeywords = words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include instanceof insteadof interface isset list match namespace new or print private protected public readonly require return static switch throw trait try unset use var while yield")
    static let commonLiterals = words("true false null nil None True False undefined NaN Infinity")

    static let specs: [String: LanguageSpec] = [
        "swift": cLike(keywords: swiftKeywords, literals: words("true false nil"), extraStrings: [#""""[\s\S]*?(?:"""|$)"#], attributes: true),
        "javascript": cLike(keywords: jsKeywords, literals: words("true false null undefined NaN Infinity"), extraStrings: [backtickString], attributes: true),
        "typescript": cLike(keywords: jsKeywords.union(words("number string boolean any unknown never")), literals: words("true false null undefined"), extraStrings: [backtickString], attributes: true),
        "java": cLike(keywords: javaKeywords, literals: words("true false null"), extraStrings: [#""""[\s\S]*?(?:"""|$)"#], attributes: true),
        "kotlin": cLike(keywords: javaKeywords, literals: words("true false null"), extraStrings: [#""""[\s\S]*?(?:"""|$)"#], attributes: true),
        "scala": cLike(keywords: javaKeywords.union(words("def trait lazy implicit given using match")), literals: words("true false null"), attributes: true),
        "dart": cLike(keywords: javaKeywords.union(words("dynamic late required async await")), literals: words("true false null"), attributes: true),
        "c": cLike(keywords: cKeywords, literals: words("true false NULL nullptr"), preprocessor: true),
        "cpp": cLike(keywords: cKeywords, literals: words("true false NULL nullptr"), preprocessor: true),
        "objc": cLike(keywords: cKeywords.union(words("@interface @implementation @end @property @synthesize self super id instancetype")), literals: words("YES NO nil NULL true false"), preprocessor: true, attributes: true),
        "csharp": cLike(keywords: javaKeywords.union(words("using namespace string object async await var get set out ref readonly struct")), literals: words("true false null"), preprocessor: true),
        "go": cLike(keywords: goKeywords, literals: words("true false nil iota"), extraStrings: [backtickString]),
        "rust": cLike(keywords: rustKeywords, literals: words("true false None Some Ok Err"), extraStrings: [##"r#*"[\s\S]*?"#*"##], attributes: false),
        "zig": cLike(keywords: words("const var fn pub return if else while for switch struct enum union try catch defer errdefer comptime test break continue"), literals: words("true false null undefined")),
        "php": cLike(keywords: phpKeywords, literals: words("true false null TRUE FALSE NULL")),
        "python": LanguageSpec(rules: [
            (hashComment, .comment),
            (#"[rRbBuUfF]{0,2}"""[\s\S]*?(?:"""|$)|[rRbBuUfF]{0,2}'''[\s\S]*?(?:'''|$)"#, .string),
            (#"[rRbBuUfF]{0,2}"(?:\\.|[^"\\\n])*"?|[rRbBuUfF]{0,2}'(?:\\.|[^'\\\n])*'?"#, .string),
            (attribute, .attribute),
            (keywordPattern(words("True False None")), .literal),
            (keywordPattern(pythonKeywords), .keyword),
            (number, .number),
            (typeName, .type),
            (functionCall, .function),
        ], keywords: pythonKeywords),
        "ruby": LanguageSpec(rules: [
            (hashComment, .comment),
            (doubleString, .string), (singleString, .string),
            (#":[A-Za-z_]\w*"#, .literal),
            (#"@{1,2}\w+"#, .variable),
            (keywordPattern(words("true false nil")), .literal),
            (keywordPattern(rubyKeywords), .keyword),
            (number, .number), (typeName, .type), (functionCall, .function),
        ], keywords: rubyKeywords),
        "bash": LanguageSpec(rules: [
            (#"(?<![\w$])#[^\n]*"#, .comment),
            (doubleString, .string), (singleString, .string),
            (#"\$\{[^}]*\}|\$\w+|\$[@#?$!*0-9-]"#, .variable),
            (keywordPattern(words("if then else elif fi for while until do done case esac function in return export local readonly unset select time source alias break continue shift exit trap set declare eval exec")), .keyword),
            (#"(?<=\s|^)--?[A-Za-z][\w-]*"#, .attribute),
            (number, .number),
            (#"^\s*[\w.-]+(?=\s|$)"#, .function),
        ], keywords: []),
        "json": LanguageSpec(rules: [
            (#""(?:\\.|[^"\\])*"(?=\s*:)"#, .property),
            (doubleString, .string),
            (keywordPattern(words("true false null")), .literal),
            (#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, .number),
            (slashComment, .comment),
        ]),
        "yaml": LanguageSpec(rules: [
            (hashComment, .comment),
            (#"^\s*-?\s*[\w.\-/]+(?=\s*:(?:\s|$))"#, .property),
            (doubleString, .string), (singleString, .string),
            (keywordPattern(words("true false null yes no on off")), .literal),
            (#"[&*][\w-]+"#, .variable),
            (number, .number),
        ]),
        "toml": LanguageSpec(rules: [
            (#"[#;][^\n]*"#, .comment),
            (#"^\s*\[\[?[^\]\n]+\]\]?"#, .meta),
            (#"^\s*[\w.\-"]+(?=\s*=)"#, .property),
            (#""""[\s\S]*?(?:"""|$)"#, .string),
            (doubleString, .string), (singleString, .string),
            (keywordPattern(words("true false")), .literal),
            (number, .number),
        ]),
        "xml": LanguageSpec(rules: [
            (#"<!--[\s\S]*?(?:-->|$)"#, .comment),
            (#"<!\[CDATA\[[\s\S]*?\]\]>"#, .string),
            (#"</?[\w:.-]+|/?>"#, .tag),
            (#"\b[\w:-]+(?=\s*=)"#, .attribute),
            (doubleString, .string), (singleString, .string),
        ]),
        "html": LanguageSpec(rules: [
            (#"<!--[\s\S]*?(?:-->|$)"#, .comment),
            (#"<!DOCTYPE[^>]*>"#, .meta),
            (#"</?[\w:.-]+|/?>"#, .tag),
            (#"\b[\w:@.-]+(?=\s*=)"#, .attribute),
            (doubleString, .string), (singleString, .string),
        ]),
        "css": LanguageSpec(rules: [
            (#"/\*[\s\S]*?(?:\*/|$)"#, .comment),
            (doubleString, .string), (singleString, .string),
            (#"#[0-9a-fA-F]{3,8}\b"#, .number),
            (#"[\w-]+(?=\s*:[^;{]*[;}])"#, .property),
            (#"@[\w-]+"#, .keyword),
            (#"-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr|pt)?\b"#, .number),
            (#"[.#][\w-]+"#, .type),
        ]),
        "sql": LanguageSpec(rules: [
            (#"--[^\n]*|/\*[\s\S]*?(?:\*/|$)"#, .comment),
            (singleString, .string), (doubleString, .variable),
            (keywordPattern(words("select from where and or not insert into values update set delete create table index view drop alter add column primary key foreign references join left right inner outer full on group by order having limit offset as distinct union all exists in is null like between case when then else end with returning default constraint unique check begin commit rollback transaction asc desc count sum avg min max")), .keyword),
            (number, .number),
            (functionCall, .function),
        ], caseInsensitive: true),
        "diff": LanguageSpec(rules: [
            (#"^(?:\+\+\+|---)[^\n]*"#, .meta),
            (#"^@@[^\n]*"#, .meta),
            (#"^\+[^\n]*"#, .inserted),
            (#"^-[^\n]*"#, .deleted),
        ]),
        "dockerfile": LanguageSpec(rules: [
            (hashComment, .comment),
            (#"^\s*(?:FROM|RUN|CMD|LABEL|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL|AS)\b"#, .keyword),
            (doubleString, .string), (singleString, .string),
            (#"\$\{[^}]*\}|\$\w+"#, .variable),
        ], caseInsensitive: true),
        "lua": LanguageSpec(rules: [
            (#"--\[\[[\s\S]*?(?:\]\]|$)|--[^\n]*"#, .comment),
            (doubleString, .string), (singleString, .string),
            (keywordPattern(words("true false nil")), .literal),
            (keywordPattern(words("and break do else elseif end for function goto if in local not or repeat return then until while")), .keyword),
            (number, .number), (functionCall, .function),
        ]),
    ]

    static let generic = LanguageSpec(rules: [
        (#"//[^\n]*|/\*[\s\S]*?(?:\*/|$)|(?<![\w$])#[^\n]*"#, .comment),
        (doubleString, .string), (singleString, .string),
        (keywordPattern(commonLiterals), .literal),
        (number, .number),
    ])

    static func spec(for language: String?) -> LanguageSpec {
        guard let canonical = SyntaxHighlighter.normalizedLanguage(language) else { return generic }
        if canonical == "markdown" || canonical == "text" || canonical == "plaintext" || canonical == "txt" {
            return LanguageSpec(rules: [])
        }
        return specs[canonical] ?? generic
    }
}
