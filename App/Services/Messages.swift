import AppKit
import OSLog
import SQLite3
import UniformTypeIdentifiers
import iMessage

private let log = Logger.service("messages")
private let messagesDatabasePath = "/Users/\(NSUserName())/Library/Messages/chat.db"
private let messagesDatabaseBookmarkKey: String = "me.mattt.iMCP.messagesDatabaseBookmark"
private let defaultLimit = 30
private let appleEpochOffset: TimeInterval = 978307200

final class MessageService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = MessageService()

    func activate() async throws {
        log.debug("Starting message service activation")

        if canAccessDatabaseAtDefaultPath {
            log.debug("Successfully activated using default database path")
            return
        }

        if canAccessDatabaseUsingBookmark {
            log.debug("Successfully activated using stored bookmark")
            return
        }

        log.debug("Opening file picker for manual database selection")
        guard try await showDatabaseAccessAlert() else {
            throw DatabaseAccessError.userDeclinedAccess
        }

        let selectedURL = try await showFilePicker()

        guard FileManager.default.isReadableFile(atPath: selectedURL.path) else {
            throw DatabaseAccessError.fileNotReadable
        }

        storeBookmark(for: selectedURL)
        log.debug("Successfully activated message service")
    }

    var isActivated: Bool {
        get async {
            let isActivated = canAccessDatabaseAtDefaultPath || canAccessDatabaseUsingBookmark
            log.debug("Message service activation status: \(isActivated)")
            return isActivated
        }
    }

    var tools: [Tool] {
        Tool(
            name: "messages_fetch",
            description: "Fetch messages from the Messages app",
            inputSchema: .object(
                properties: [
                    "participants": .array(
                        description:
                            "Participant handles (phone or email). Phone numbers should use E.164 format",
                        items: .string()
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "query": .string(
                        description: "Search term to filter messages by content"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return",
                        default: .int(defaultLimit)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting message fetch with arguments: \(arguments)")
            try await self.activate()

            let participants =
                arguments["participants"]?.arrayValue?.compactMap({
                    $0.stringValue
                }) ?? []

            var dateRange: Range<Date>?
            if let startDateStr = arguments["start"]?.stringValue,
                let endDateStr = arguments["end"]?.stringValue,
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startDateStr
                ),
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endDateStr
                )
            {
                let calendar = Calendar.current
                let normalizedStart = calendar.normalizedStartDate(
                    from: parsedStart.date,
                    isDateOnly: parsedStart.isDateOnly
                )
                let normalizedEnd = calendar.normalizedEndDate(
                    from: parsedEnd.date,
                    isDateOnly: parsedEnd.isDateOnly
                )

                dateRange = normalizedStart ..< normalizedEnd
            }

            let searchTerm = arguments["query"]?.stringValue
            let limit = arguments["limit"]?.intValue

            let db = try self.createDatabaseConnection()
            var messages: [[String: Value]] = []

            log.debug("Fetching handles for participants: \(participants)")
            let handles = try db.fetchParticipant(matching: participants)

            log.debug(
                "Fetching messages with date range: \(String(describing: dateRange)), limit: \(limit ?? -1)"
            )
            for message in try db.fetchMessages(
                with: Set(handles),
                in: dateRange,
                limit: max(limit ?? defaultLimit, 1024)
            ) {
                guard messages.count < (limit ?? defaultLimit) else { break }
                guard !message.text.isEmpty else { continue }

                let sender: String
                if message.isFromMe {
                    sender = "me"
                } else if message.sender == nil {
                    sender = "unknown"
                } else {
                    sender = message.sender!.rawValue
                }

                if let searchTerm {
                    guard message.text.localizedCaseInsensitiveContains(searchTerm) else {
                        continue
                    }
                }

                messages.append([
                    "@id": .string(message.id.description),
                    "sender": [
                        "@id": .string(sender)
                    ],
                    "text": .string(message.text),
                    "createdAt": .string(message.date.formatted(.iso8601)),
                ])
            }

            log.debug("Successfully fetched \(messages.count) messages")
            return [
                "@context": "https://schema.org",
                "@type": "Conversation",
                "hasPart": Value.array(messages.map({ .object($0) })),
            ]
        }

        Tool(
            name: "messages_chats",
            description: "List Messages conversations",
            inputSchema: .object(
                properties: [
                    "limit": .integer(description: "Maximum chats to return", default: .int(10)),
                    "offset": .integer(description: "Number of chats to skip", default: .int(0)),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Messages Chats",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            let limit = clampedInt(arguments["limit"]?.intValue, defaultValue: 10, minimum: 1, maximum: 100)
            let offset = clampedInt(arguments["offset"]?.intValue, defaultValue: 0, minimum: 0, maximum: 10000)
            let chats = try self.fetchChats(limit: limit + 1, offset: offset)
            return MessagesChatsPayload(
                chats: Array(chats.prefix(limit)),
                hasMore: chats.count > limit
            )
        }

        Tool(
            name: "messages_history",
            description: "Fetch Messages history for one chat",
            inputSchema: .object(
                properties: [
                    "chat_id": .integer(description: "Messages chat row id"),
                    "limit": .integer(description: "Maximum messages to return", default: .int(10)),
                    "offset": .integer(description: "Number of messages to skip", default: .int(0)),
                ],
                required: ["chat_id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Messages Chat",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            guard let chatID = arguments["chat_id"]?.intValue else {
                throw DatabaseAccessError.invalidChatID
            }
            let limit = clampedInt(arguments["limit"]?.intValue, defaultValue: 10, minimum: 1, maximum: 100)
            let offset = clampedInt(arguments["offset"]?.intValue, defaultValue: 0, minimum: 0, maximum: 10000)
            let messages = try self.fetchHistory(chatID: Int64(chatID), limit: limit + 1, offset: offset)
            return MessagesHistoryPayload(
                messages: Array(messages.prefix(limit)),
                hasMore: messages.count > limit
            )
        }
    }

    private var canAccessDatabaseAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: messagesDatabasePath)
    }

    private enum DatabaseAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case invalidParticipants
        case invalidChatID
        case userDeclinedAccess
        case invalidFileSelected
        case fileNotReadable

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for database access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .invalidParticipants:
                return "Invalid participants provided"
            case .invalidChatID:
                return "Invalid Messages chat id"
            case .userDeclinedAccess:
                return "User declined to grant access to the messages database"
            case .invalidFileSelected:
                return "Messages database access denied or invalid file selected"
            case .fileNotReadable:
                return "Selected database file is not readable"
            }
        }
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    private func resolveBookmarkURL() throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: messagesDatabaseBookmarkKey)
        else {
            throw DatabaseAccessError.noBookmarkFound
        }

        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func createDatabaseConnection() throws -> iMessage.Database {
        if canAccessDatabaseAtDefaultPath {
            return try iMessage.Database()
        }

        let databaseURL = try resolveBookmarkURL()
        return try withSecurityScopedAccess(databaseURL) { url in
            try iMessage.Database(path: url.path)
        }
    }

    func sendTarget(chatID: Int64) async throws -> MessageSendTarget {
        try await activate()
        guard let target = try fetchSendTarget(chatID: chatID) else {
            throw DatabaseAccessError.invalidChatID
        }
        return target
    }

    private func withDatabasePath<T>(_ operation: (String) throws -> T) throws -> T {
        if canAccessDatabaseAtDefaultPath {
            return try operation(messagesDatabasePath)
        }

        let databaseURL = try resolveBookmarkURL()
        return try withSecurityScopedAccess(databaseURL) { url in
            try operation(url.path)
        }
    }

    private func withSQLite<T>(_ operation: (OpaquePointer?) throws -> T) throws -> T {
        try withDatabasePath { path in
            var database: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
                defer { sqlite3_close(database) }
                throw sqliteError(database, fallback: "Could not open Messages database")
            }
            defer { sqlite3_close(database) }
            return try operation(database)
        }
    }

    private func fetchChats(limit: Int, offset: Int) throws -> [MessagesChat] {
        try withSQLite { database in
            let sql = """
                SELECT
                  c.ROWID,
                  COALESCE(c.guid, ''),
                  COALESCE(c.chat_identifier, ''),
                  COALESCE(c.display_name, ''),
                  COALESCE(c.service_name, ''),
                  COALESCE(c.style, 0),
                  COALESCE((
                    SELECT m.text
                    FROM chat_message_join cmj
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE cmj.chat_id = c.ROWID
                    ORDER BY m.date DESC
                    LIMIT 1
                  ), ''),
                  COALESCE((
                    SELECT m.date
                    FROM chat_message_join cmj
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE cmj.chat_id = c.ROWID
                    ORDER BY m.date DESC
                    LIMIT 1
                  ), 0)
                FROM chat c
                WHERE EXISTS (
                  SELECT 1 FROM chat_message_join cmj WHERE cmj.chat_id = c.ROWID
                )
                ORDER BY 8 DESC
                LIMIT ? OFFSET ?
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(database, fallback: "Could not prepare chat query")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            sqlite3_bind_int(statement, 2, Int32(offset))

            var chats: [MessagesChat] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let dateValue = sqlite3_column_int64(statement, 7)
                chats.append(MessagesChat(
                    id: sqlite3_column_int64(statement, 0),
                    guid: sqliteText(statement, 1),
                    identifier: sqliteText(statement, 2),
                    name: sqliteText(statement, 3),
                    service: normalizedService(sqliteText(statement, 4), fallback: sqliteText(statement, 2)),
                    isGroup: sqlite3_column_int(statement, 5) != 45,
                    lastMessageText: sqliteText(statement, 6),
                    lastMessageAt: dateString(dateValue)
                ))
            }
            return chats
        }
    }

    private func fetchHistory(chatID: Int64, limit: Int, offset: Int) throws -> [MessagesMessage] {
        try withSQLite { database in
            let sql = """
                SELECT
                  m.ROWID,
                  COALESCE(m.guid, ''),
                  COALESCE(m.text, ''),
                  COALESCE(m.date, 0),
                  COALESCE(m.is_from_me, 0),
                  COALESCE(h.id, '')
                FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE cmj.chat_id = ?
                ORDER BY m.date DESC
                LIMIT ? OFFSET ?
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(database, fallback: "Could not prepare message query")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, chatID)
            sqlite3_bind_int(statement, 2, Int32(limit))
            sqlite3_bind_int(statement, 3, Int32(offset))

            var messages: [MessagesMessage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                messages.append(MessagesMessage(
                    id: sqlite3_column_int64(statement, 0),
                    guid: sqliteText(statement, 1),
                    chatID: chatID,
                    text: sqliteText(statement, 2),
                    createdAt: dateString(sqlite3_column_int64(statement, 3)),
                    isFromMe: sqlite3_column_int(statement, 4) != 0,
                    sender: sqliteText(statement, 5)
                ))
            }
            return messages
        }
    }

    private func fetchSendTarget(chatID: Int64) throws -> MessageSendTarget? {
        try withSQLite { database in
            let sql = """
                SELECT
                  c.ROWID,
                  COALESCE(c.guid, ''),
                  COALESCE(c.chat_identifier, ''),
                  COALESCE(c.service_name, '')
                FROM chat c
                WHERE c.ROWID = ?
                LIMIT 1
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(database, fallback: "Could not prepare chat target query")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, chatID)

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return MessageSendTarget(
                chatID: sqlite3_column_int64(statement, 0),
                guid: sqliteText(statement, 1),
                identifier: sqliteText(statement, 2),
                service: normalizedService(sqliteText(statement, 3), fallback: sqliteText(statement, 2))
            )
        }
    }

    private var canAccessDatabaseUsingBookmark: Bool {
        do {
            let url = try resolveBookmarkURL()
            return try withSecurityScopedAccess(url) { url in
                FileManager.default.isReadableFile(atPath: url.path)
            }
        } catch {
            log.error("Error accessing database with bookmark: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    private func showDatabaseAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Messages Database Access Required"
        alert.informativeText = """
            To read your Messages history, we need to open your database file.

            In the next screen, please select the file `chat.db` and click "Grant Access".
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showFilePicker() async throws -> URL {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message = "Please select the Messages database file (chat.db)"
        openPanel.prompt = "Grant Access"
        openPanel.allowedContentTypes = [UTType.item]
        openPanel.directoryURL = URL(fileURLWithPath: messagesDatabasePath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK,
            let url = openPanel.url,
            url.lastPathComponent == "chat.db"
        else {
            throw DatabaseAccessError.invalidFileSelected
        }

        return url
    }

    private func storeBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .securityScopeAllowOnlyReadAccess,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: messagesDatabaseBookmarkKey)
            log.debug("Successfully created and stored bookmark")
        } catch {
            log.error("Failed to create bookmark: \(error.localizedDescription)")
        }
    }

    // NSOpenSavePanelDelegate method to constrain file selection
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable = url.lastPathComponent == "chat.db"
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}

struct MessagesChatsPayload: Encodable {
    let chats: [MessagesChat]
    let hasMore: Bool
}

struct MessagesHistoryPayload: Encodable {
    let messages: [MessagesMessage]
    let hasMore: Bool
}

struct MessagesChat: Encodable {
    let id: Int64
    let guid: String
    let identifier: String
    let name: String
    let service: String
    let isGroup: Bool
    let lastMessageText: String
    let lastMessageAt: String
}

struct MessagesMessage: Encodable {
    let id: Int64
    let guid: String
    let chatID: Int64
    let text: String
    let createdAt: String
    let isFromMe: Bool
    let sender: String
}

struct MessageSendTarget {
    let chatID: Int64
    let guid: String
    let identifier: String
    let service: String

    var appleScriptChatID: String {
        if !guid.isEmpty { return guid }
        return identifier
    }
}

private func clampedInt(_ value: Int?, defaultValue: Int, minimum: Int, maximum: Int) -> Int {
    let raw = value ?? defaultValue
    return min(max(raw, minimum), maximum)
}

private func sqliteText(_ statement: OpaquePointer?, _ index: Int32) -> String {
    guard let text = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: text)
}

private func sqliteError(_ database: OpaquePointer?, fallback: String) -> NSError {
    let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? fallback
    return NSError(domain: "MessageService", code: 1, userInfo: [
        NSLocalizedDescriptionKey: message.isEmpty ? fallback : message
    ])
}

private func dateString(_ raw: Int64) -> String {
    guard raw > 0 else { return "" }
    let seconds: TimeInterval
    if raw > 10_000_000_000 {
        seconds = (Double(raw) / 1_000_000_000) + appleEpochOffset
    } else {
        seconds = Double(raw) + appleEpochOffset
    }
    return Date(timeIntervalSince1970: seconds).formatted(.iso8601)
}

private func normalizedService(_ service: String, fallback: String) -> String {
    let text = service.isEmpty ? fallback : service
    return text.localizedCaseInsensitiveContains("sms") ? "SMS" : "iMessage"
}
