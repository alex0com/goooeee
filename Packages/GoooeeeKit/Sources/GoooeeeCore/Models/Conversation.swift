import Foundation

/// Unsent composer state, saved per conversation.
public struct Draft: Codable, Sendable, Hashable {
    public var text: String
    public var attachments: [Attachment]

    public init(text: String = "", attachments: [Attachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
}

public struct Conversation: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var workspaceID: UUID
    public var title: String
    public var isPinned: Bool
    /// Tip of the branch currently shown.
    public var currentLeafID: UUID?
    public var overrides: SettingsOverrides
    /// `nil` = inherit the workspace's tool selection.
    public var tools: ToolSelection?
    public var draft: Draft?
    /// Short preview of the last message, for the sidebar.
    public var preview: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when moved to Recently Deleted.
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        title: String = "New chat",
        isPinned: Bool = false,
        currentLeafID: UUID? = nil,
        overrides: SettingsOverrides = SettingsOverrides(),
        tools: ToolSelection? = nil,
        draft: Draft? = nil,
        preview: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.isPinned = isPinned
        self.currentLeafID = currentLeafID
        self.overrides = overrides
        self.tools = tools
        self.draft = draft
        self.preview = preview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }

    public static let untitled = "New chat"
}

/// Sidebar sections: Pinned, Today, Yesterday, Previous 7 days, then by month.
public enum ConversationGrouping {
    public struct Section: Identifiable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var conversations: [Conversation]
    }

    public static func sections(_ conversations: [Conversation], now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        let live = conversations.filter { !$0.isDeleted }.sorted { $0.updatedAt > $1.updatedAt }
        var sections: [Section] = []
        let pinned = live.filter(\.isPinned)
        if !pinned.isEmpty { sections.append(Section(id: "pinned", title: "Pinned", conversations: pinned)) }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday

        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var week: [Conversation] = []
        var months: [(key: String, title: String, items: [Conversation])] = []
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.dateFormat = "LLLL yyyy"

        for conversation in live where !conversation.isPinned {
            let date = conversation.updatedAt
            if date >= startOfToday {
                today.append(conversation)
            } else if date >= startOfYesterday {
                yesterday.append(conversation)
            } else if date >= startOfWeek {
                week.append(conversation)
            } else {
                let parts = calendar.dateComponents([.year, .month], from: date)
                let key = "\(parts.year ?? 0)-\(parts.month ?? 0)"
                if let index = months.firstIndex(where: { $0.key == key }) {
                    months[index].items.append(conversation)
                } else {
                    months.append((key, monthFormatter.string(from: date), [conversation]))
                }
            }
        }
        if !today.isEmpty { sections.append(Section(id: "today", title: "Today", conversations: today)) }
        if !yesterday.isEmpty { sections.append(Section(id: "yesterday", title: "Yesterday", conversations: yesterday)) }
        if !week.isEmpty { sections.append(Section(id: "week", title: "Previous 7 days", conversations: week)) }
        for month in months {
            sections.append(Section(id: "month-\(month.key)", title: month.title, conversations: month.items))
        }
        return sections
    }
}

/// Conversation titles from the first non-empty line, as in the llama.cpp UI.
public enum ConversationTitle {
    public static func fromFirstLine(_ text: String, maxLength: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var title = line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        if title.count > maxLength {
            title = String(title.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return title.isEmpty ? Conversation.untitled : title
    }

    /// Cleans a model-generated title: strips quotes, thinking and trailing punctuation.
    public static func cleanGenerated(_ raw: String) -> String {
        var text = raw
        if let range = text.range(of: "</think>") { text = String(text[range.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = text.split(whereSeparator: \.isNewline).first { text = String(firstLine) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#. "))
        if text.lowercased().hasPrefix("title:") { text = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return fromFirstLine(text)
    }

    public static let defaultPrompt = """
        Write a short title (3 to 6 words) for this conversation. Reply with the title only, no quotes.

        User: {{USER}}

        Assistant: {{ASSISTANT}}
        """
}
