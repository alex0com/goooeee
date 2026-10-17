import Foundation
import GRDB

/// SQLite storage (GRDB, WAL). Records are stored as JSON with a few indexed columns, so
/// models can evolve without schema migrations; attachments' bytes live in their own table.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    /// Whether SQLite has FTS5 (system SQLite on macOS does).
    public let hasFullTextSearch: Bool

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
        hasFullTextSearch = (try? writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT count(*) > 0 FROM sqlite_master WHERE name = 'message_fts'") ?? false
        }) ?? false
    }

    /// Opens (or creates) the database file. The directory is created if needed.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    /// `~/Library/Application Support/goooeee/goooeee.sqlite`.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".goooeee")
        return base.appendingPathComponent("goooeee", isDirectory: true).appendingPathComponent("goooeee.sqlite")
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE connection (id TEXT PRIMARY KEY, json BLOB NOT NULL, updatedAt DOUBLE NOT NULL);
                CREATE TABLE workspace (id TEXT PRIMARY KEY, json BLOB NOT NULL, sortIndex INTEGER NOT NULL DEFAULT 0, isOpen INTEGER NOT NULL DEFAULT 1);
                CREATE TABLE conversation (
                    id TEXT PRIMARY KEY,
                    workspaceID TEXT NOT NULL,
                    title TEXT NOT NULL,
                    isPinned INTEGER NOT NULL DEFAULT 0,
                    updatedAt DOUBLE NOT NULL,
                    deletedAt DOUBLE,
                    json BLOB NOT NULL
                );
                CREATE INDEX conversation_workspace ON conversation(workspaceID, deletedAt, updatedAt);
                CREATE TABLE message (
                    id TEXT PRIMARY KEY,
                    conversationID TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
                    parentID TEXT,
                    createdAt DOUBLE NOT NULL,
                    json BLOB NOT NULL
                );
                CREATE INDEX message_conversation ON message(conversationID, createdAt);
                CREATE TABLE attachment_data (
                    id TEXT PRIMARY KEY,
                    messageID TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    data BLOB,
                    pages BLOB
                );
                CREATE INDEX attachment_message ON attachment_data(messageID);
                CREATE TABLE mcp_server (id TEXT PRIMARY KEY, json BLOB NOT NULL, sortIndex INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE tool_grant (id TEXT PRIMARY KEY, workspaceID TEXT NOT NULL, json BLOB NOT NULL);
                CREATE TABLE tool_log (id TEXT PRIMARY KEY, workspaceID TEXT NOT NULL, createdAt DOUBLE NOT NULL, json BLOB NOT NULL);
                CREATE INDEX tool_log_workspace ON tool_log(workspaceID, createdAt);
                CREATE TABLE custom_profile (id TEXT PRIMARY KEY, json BLOB NOT NULL);
                """)
            // Full-text search is optional: not every SQLite build has FTS5.
            try? db.execute(sql: """
                CREATE VIRTUAL TABLE message_fts USING fts5(body, messageID UNINDEXED, conversationID UNINDEXED, workspaceID UNINDEXED, tokenize = 'unicode61');
                """)
        }
        return migrator
    }
}

// MARK: - Coding

enum DBCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Connections, workspaces, MCP servers, profiles

extension AppDatabase {
    public func connections() async throws -> [ServerConnection] {
        try await writer.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM connection ORDER BY updatedAt").compactMap { try? DBCoding.decode(ServerConnection.self, $0) }
        }
    }

    public func save(_ connection: ServerConnection) async throws {
        let data = try DBCoding.encode(connection)
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO connection (id, json, updatedAt) VALUES (?, ?, ?)",
                           arguments: [connection.id.uuidString, data, connection.updatedAt.timeIntervalSince1970])
        }
    }

    public func deleteConnection(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM connection WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func workspaces() async throws -> [Workspace] {
        try await writer.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM workspace ORDER BY sortIndex").compactMap { try? DBCoding.decode(Workspace.self, $0) }
        }
    }

    public func workspace(id: UUID) async throws -> Workspace? {
        try await writer.read { db in
            try Data.fetchOne(db, sql: "SELECT json FROM workspace WHERE id = ?", arguments: [id.uuidString]).flatMap { try? DBCoding.decode(Workspace.self, $0) }
        }
    }

    public func save(_ workspace: Workspace) async throws {
        let data = try DBCoding.encode(workspace)
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO workspace (id, json, sortIndex, isOpen) VALUES (?, ?, ?, ?)",
                           arguments: [workspace.id.uuidString, data, workspace.sortIndex, workspace.isOpen])
        }
    }

    /// Deletes a workspace with its conversations.
    public func deleteWorkspace(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM message_fts WHERE workspaceID = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM conversation WHERE workspaceID = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM tool_grant WHERE workspaceID = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM tool_log WHERE workspaceID = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM workspace WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func mcpServers() async throws -> [MCPServerConfig] {
        try await writer.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM mcp_server ORDER BY sortIndex").compactMap { try? DBCoding.decode(MCPServerConfig.self, $0) }
        }
    }

    public func save(_ server: MCPServerConfig, sortIndex: Int = 0) async throws {
        let data = try DBCoding.encode(server)
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO mcp_server (id, json, sortIndex) VALUES (?, ?, ?)",
                           arguments: [server.id.uuidString, data, sortIndex])
        }
    }

    public func deleteMCPServer(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM mcp_server WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func customProfiles() async throws -> [ModelProfile] {
        try await writer.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM custom_profile").compactMap { try? DBCoding.decode(ModelProfile.self, $0) }
        }
    }

    public func saveCustomProfiles(_ profiles: [ModelProfile]) async throws {
        let rows = try profiles.map { ($0.id, try DBCoding.encode($0)) }
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM custom_profile")
            for (id, data) in rows {
                try db.execute(sql: "INSERT INTO custom_profile (id, json) VALUES (?, ?)", arguments: [id, data])
            }
        }
    }
}

// MARK: - Conversations and messages

extension AppDatabase {
    public func conversations(workspaceID: UUID, includeDeleted: Bool = false) async throws -> [Conversation] {
        try await writer.read { db in
            let sql = includeDeleted
                ? "SELECT json FROM conversation WHERE workspaceID = ? ORDER BY updatedAt DESC"
                : "SELECT json FROM conversation WHERE workspaceID = ? AND deletedAt IS NULL ORDER BY updatedAt DESC"
            return try Data.fetchAll(db, sql: sql, arguments: [workspaceID.uuidString]).compactMap { try? DBCoding.decode(Conversation.self, $0) }
        }
    }

    public func deletedConversations(workspaceID: UUID) async throws -> [Conversation] {
        try await writer.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM conversation WHERE workspaceID = ? AND deletedAt IS NOT NULL ORDER BY deletedAt DESC",
                              arguments: [workspaceID.uuidString]).compactMap { try? DBCoding.decode(Conversation.self, $0) }
        }
    }

    public func conversation(id: UUID) async throws -> Conversation? {
        try await writer.read { db in
            try Data.fetchOne(db, sql: "SELECT json FROM conversation WHERE id = ?", arguments: [id.uuidString]).flatMap { try? DBCoding.decode(Conversation.self, $0) }
        }
    }

    public func save(_ conversation: Conversation) async throws {
        let data = try DBCoding.encode(conversation)
        try await writer.write { db in
            try Self.upsert(conversation, data: data, db: db)
        }
    }

    static func upsert(_ conversation: Conversation, data: Data, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO conversation (id, workspaceID, title, isPinned, updatedAt, deletedAt, json) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET workspaceID = excluded.workspaceID, title = excluded.title, isPinned = excluded.isPinned,
                updatedAt = excluded.updatedAt, deletedAt = excluded.deletedAt, json = excluded.json
            """,
            arguments: [conversation.id.uuidString, conversation.workspaceID.uuidString, conversation.title, conversation.isPinned,
                        conversation.updatedAt.timeIntervalSince1970, conversation.deletedAt?.timeIntervalSince1970, data])
    }

    /// Moves conversations to Recently Deleted (soft delete).
    public func softDelete(conversationIDs: [UUID], at date: Date = Date()) async throws {
        try await writer.write { db in
            for id in conversationIDs {
                guard let data = try Data.fetchOne(db, sql: "SELECT json FROM conversation WHERE id = ?", arguments: [id.uuidString]),
                    var conversation = try? DBCoding.decode(Conversation.self, data)
                else { continue }
                conversation.deletedAt = date
                try Self.upsert(conversation, data: try DBCoding.encode(conversation), db: db)
            }
        }
    }

    public func restore(conversationIDs: [UUID]) async throws {
        try await writer.write { db in
            for id in conversationIDs {
                guard let data = try Data.fetchOne(db, sql: "SELECT json FROM conversation WHERE id = ?", arguments: [id.uuidString]),
                    var conversation = try? DBCoding.decode(Conversation.self, data)
                else { continue }
                conversation.deletedAt = nil
                try Self.upsert(conversation, data: try DBCoding.encode(conversation), db: db)
            }
        }
    }

    /// Permanently deletes conversations and their messages.
    public func purge(conversationIDs: [UUID]) async throws {
        try await writer.write { db in
            for id in conversationIDs {
                try db.execute(sql: "DELETE FROM message_fts WHERE conversationID = ?", arguments: [id.uuidString])
                try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [id.uuidString])
            }
        }
    }

    /// Purges conversations deleted before `date`.
    @discardableResult
    public func purgeDeleted(before date: Date) async throws -> Int {
        let ids: [String] = try await writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM conversation WHERE deletedAt IS NOT NULL AND deletedAt < ?", arguments: [date.timeIntervalSince1970])
        }
        try await purge(conversationIDs: ids.compactMap(UUID.init(uuidString:)))
        return ids.count
    }

    /// All messages of a conversation, with attachment bytes.
    public func messages(conversationID: UUID) async throws -> [Message] {
        try await writer.read { db in
            let rows = try Data.fetchAll(db, sql: "SELECT json FROM message WHERE conversationID = ? ORDER BY createdAt", arguments: [conversationID.uuidString])
            var messages = rows.compactMap { try? DBCoding.decode(Message.self, $0) }
            let attachmentRows = try Row.fetchAll(db, sql: """
                SELECT a.id, a.data, a.pages FROM attachment_data a JOIN message m ON m.id = a.messageID WHERE m.conversationID = ?
                """, arguments: [conversationID.uuidString])
            var bytes: [String: (Data?, Data?)] = [:]
            for row in attachmentRows {
                bytes[row["id"]] = (row["data"], row["pages"])
            }
            if !bytes.isEmpty {
                for index in messages.indices {
                    for attachmentIndex in messages[index].attachments.indices {
                        let id = messages[index].attachments[attachmentIndex].id.uuidString
                        guard let (data, pages) = bytes[id] else { continue }
                        messages[index].attachments[attachmentIndex].data = data
                        if let pages { messages[index].attachments[attachmentIndex].pageImages = try? DBCoding.decode([Data].self, pages) }
                    }
                }
            }
            return messages
        }
    }

    /// Saves a message. Attachment bytes go to `attachment_data`; `indexText` updates full-text search.
    public func save(_ message: Message, workspaceID: UUID? = nil, indexText: Bool = false) async throws {
        var stored = message
        var attachmentRows: [(String, Data?, Data?)] = []
        for index in stored.attachments.indices {
            let attachment = stored.attachments[index]
            if attachment.data != nil || attachment.pageImages != nil {
                let pages = try attachment.pageImages.map { try DBCoding.encode($0) }
                attachmentRows.append((attachment.id.uuidString, attachment.data, pages))
                stored.attachments[index].data = nil
                stored.attachments[index].pageImages = nil
            }
        }
        let data = try DBCoding.encode(stored)
        let attachments = attachmentRows
        let ftsBody = indexText ? (message.text + (message.attachments.isEmpty ? "" : "\n" + message.attachments.map(\.name).joined(separator: " "))) : nil
        let fts = hasFullTextSearch
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO message (id, conversationID, parentID, createdAt, json) VALUES (?, ?, ?, ?, ?)",
                           arguments: [message.id.uuidString, message.conversationID.uuidString, message.parentID?.uuidString,
                                       message.createdAt.timeIntervalSince1970, data])
            for (id, bytes, pages) in attachments {
                try db.execute(sql: "INSERT OR REPLACE INTO attachment_data (id, messageID, data, pages) VALUES (?, ?, ?, ?)",
                               arguments: [id, message.id.uuidString, bytes, pages])
            }
            if fts, let ftsBody, let workspaceID, !ftsBody.isEmpty {
                try db.execute(sql: "DELETE FROM message_fts WHERE messageID = ?", arguments: [message.id.uuidString])
                try db.execute(sql: "INSERT INTO message_fts (body, messageID, conversationID, workspaceID) VALUES (?, ?, ?, ?)",
                               arguments: [ftsBody, message.id.uuidString, message.conversationID.uuidString, workspaceID.uuidString])
            }
        }
    }

    public func deleteMessages(ids: [UUID]) async throws {
        try await writer.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM message_fts WHERE messageID = ?", arguments: [id.uuidString])
                try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [id.uuidString])
            }
        }
    }
}

// MARK: - Search

public struct SearchHit: Identifiable, Sendable, Hashable {
    public var conversationID: UUID
    public var workspaceID: UUID
    public var title: String
    public var snippet: String

    public var id: UUID { conversationID }
}

extension AppDatabase {
    /// Searches conversation titles and message text. `workspaceID == nil` searches all workspaces.
    public func search(_ query: String, workspaceID: UUID?, limit: Int = 50) async throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let fts = hasFullTextSearch
        return try await writer.read { db in
            var hits: [UUID: SearchHit] = [:]
            var order: [UUID] = []
            let like = "%\(trimmed.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"
            let titleSQL = workspaceID == nil
                ? "SELECT id, workspaceID, title FROM conversation WHERE deletedAt IS NULL AND title LIKE ? ESCAPE '\\' ORDER BY updatedAt DESC LIMIT ?"
                : "SELECT id, workspaceID, title FROM conversation WHERE deletedAt IS NULL AND workspaceID = ? AND title LIKE ? ESCAPE '\\' ORDER BY updatedAt DESC LIMIT ?"
            let titleArguments: StatementArguments = workspaceID == nil ? [like, limit] : [workspaceID!.uuidString, like, limit]
            for row in try Row.fetchAll(db, sql: titleSQL, arguments: titleArguments) {
                guard let id = UUID(uuidString: row["id"]), let workspace = UUID(uuidString: row["workspaceID"]) else { continue }
                hits[id] = SearchHit(conversationID: id, workspaceID: workspace, title: row["title"], snippet: "")
                order.append(id)
            }

            let rows: [Row]
            if fts {
                let match = Self.ftsQuery(trimmed)
                let sql = """
                    SELECT f.conversationID, f.workspaceID, snippet(message_fts, 0, '', '', '…', 12) AS snippet, c.title
                    FROM message_fts f JOIN conversation c ON c.id = f.conversationID
                    WHERE message_fts MATCH ? AND c.deletedAt IS NULL \(workspaceID == nil ? "" : "AND f.workspaceID = ?")
                    ORDER BY rank LIMIT ?
                    """
                rows = try Row.fetchAll(db, sql: sql, arguments: workspaceID == nil ? [match, limit] : [match, workspaceID!.uuidString, limit])
            } else {
                rows = []
            }
            for row in rows {
                guard let id = UUID(uuidString: row["conversationID"]), let workspace = UUID(uuidString: row["workspaceID"]) else { continue }
                if hits[id] == nil {
                    hits[id] = SearchHit(conversationID: id, workspaceID: workspace, title: row["title"], snippet: row["snippet"] ?? "")
                    order.append(id)
                } else if hits[id]?.snippet.isEmpty == true {
                    hits[id]?.snippet = row["snippet"] ?? ""
                }
            }
            return order.compactMap { hits[$0] }
        }
    }

    /// Quotes each word and adds a prefix wildcard to the last one.
    static func ftsQuery(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !words.isEmpty else { return "\"\"" }
        return words.dropLast().joined(separator: " ") + (words.count > 1 ? " " : "") + words.last! + "*"
    }
}

// MARK: - Tool grants and log

extension AppDatabase {
    public func toolGrants(workspaceID: UUID) async throws -> [ToolGrant] {
        try await writer.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM tool_grant WHERE workspaceID = ?", arguments: [workspaceID.uuidString])
                .compactMap { try? DBCoding.decode(ToolGrant.self, $0) }
        }
    }

    public func save(_ grant: ToolGrant) async throws {
        let data = try DBCoding.encode(grant)
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO tool_grant (id, workspaceID, json) VALUES (?, ?, ?)",
                           arguments: [grant.id.uuidString, grant.workspaceID.uuidString, data])
        }
    }

    public func deleteGrant(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM tool_grant WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func append(_ entry: ToolCallLogEntry) async throws {
        let data = try DBCoding.encode(entry)
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO tool_log (id, workspaceID, createdAt, json) VALUES (?, ?, ?, ?)",
                           arguments: [entry.id.uuidString, entry.workspaceID.uuidString, entry.createdAt.timeIntervalSince1970, data])
        }
    }

    public func toolLog(workspaceID: UUID, limit: Int = 500) async throws -> [ToolCallLogEntry] {
        try await writer.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM tool_log WHERE workspaceID = ? ORDER BY createdAt DESC LIMIT ?", arguments: [workspaceID.uuidString, limit])
                .compactMap { try? DBCoding.decode(ToolCallLogEntry.self, $0) }
        }
    }

    public func pruneToolLog(before date: Date) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM tool_log WHERE createdAt < ?", arguments: [date.timeIntervalSince1970])
        }
    }
}
