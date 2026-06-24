import AppKit
import OSLog
import SQLite3
import UniformTypeIdentifiers
import iMessage

private let log = Logger.service("messages")
private let messagesDatabasePath = "/Users/\(NSUserName())/Library/Messages/chat.db"
private let messagesDatabaseBookmarkKey: String = "me.mattt.iMCP.messagesDatabaseBookmark"
private let messagesAttachmentsBookmarkKey: String = "me.mattt.iMCP.messagesAttachmentsBookmark"
private let defaultLimit = 30
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
            let db = try self.createDatabaseConnection()
            let fetchedChats = try db.fetchChats(limit: limit + offset + 1)
            let chats = Array(fetchedChats.dropFirst(offset).prefix(limit + 1))
            return MessagesChatsPayload(
                chats: chats.prefix(limit).map { MessagesChat(chat: $0) },
                hasMore: chats.count > limit
            )
        }

        Tool(
            name: "messages_history",
            description: "Fetch Messages history for one chat",
            inputSchema: .object(
                properties: [
                    "chat_id": .string(description: "Messages chat id"),
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
            guard let chatID = arguments["chat_id"]?.stringValue, !chatID.isEmpty else {
                throw DatabaseAccessError.invalidChatID
            }
            let limit = clampedInt(arguments["limit"]?.intValue, defaultValue: 10, minimum: 1, maximum: 100)
            let offset = clampedInt(arguments["offset"]?.intValue, defaultValue: 0, minimum: 0, maximum: 10000)
            let db = try self.createDatabaseConnection()
            let fetchedMessages = try db.fetchMessages(
                for: Chat.ID(rawValue: chatID),
                limit: limit + offset + 1
            )
            let messages = Array(fetchedMessages.dropFirst(offset).prefix(limit + 1))
            let pageMessages = Array(messages.prefix(limit))
            let attachments = try self.fetchAttachments(for: pageMessages)
            return MessagesHistoryPayload(
                messages: pageMessages.map {
                    MessagesMessage(
                        chatID: chatID,
                        message: $0,
                        attachments: attachments[$0.id.rawValue] ?? []
                    )
                },
                hasMore: messages.count > limit
            )
        }

        Tool(
            name: "messages_attachment",
            description: "Fetch one Messages attachment image",
            inputSchema: .object(
                properties: [
                    "local_path": .string(description: "Messages attachment file path")
                ],
                required: ["local_path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Message Attachment",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            guard let localPath = arguments["local_path"]?.stringValue, !localPath.isEmpty else {
                throw DatabaseAccessError.invalidAttachmentPath
            }
            return try await self.fetchAttachmentData(at: localPath)
        }
    }

    private var canAccessDatabaseAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: messagesDatabasePath)
    }

    enum DatabaseAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case invalidParticipants
        case invalidChatID
        case userDeclinedAccess
        case invalidFileSelected
        case fileNotReadable
        case attachmentQueryFailed(String)
        case invalidAttachmentPath

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
            case .attachmentQueryFailed(let reason):
                return "Failed to read message attachments: \(reason)"
            case .invalidAttachmentPath:
                return "Invalid Messages attachment path"
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

    private func resolveAttachmentsBookmarkURL() throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: messagesAttachmentsBookmarkKey)
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

    private func fetchAttachments(for messages: [Message]) throws -> [String: [MessagesAttachment]] {
        let messageIDs = messages.map { $0.id.rawValue }.filter { !$0.isEmpty }
        guard !messageIDs.isEmpty else { return [:] }

        if canAccessDatabaseAtDefaultPath {
            return try fetchAttachments(at: messagesDatabasePath, messageIDs: messageIDs)
        }

        let databaseURL = try resolveBookmarkURL()
        return try withSecurityScopedAccess(databaseURL) { url in
            try fetchAttachments(at: url.path, messageIDs: messageIDs)
        }
    }

    private func fetchAttachments(at databasePath: String, messageIDs: [String]) throws -> [String: [MessagesAttachment]] {
        var db: OpaquePointer?
        let dbURI = "file:\(databasePath)?immutable=1&mode=ro"
        guard sqlite3_open_v2(dbURI, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            throw DatabaseAccessError.attachmentQueryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ",")
        let query = """
            SELECT
                m.guid,
                a.guid,
                a.filename,
                a.mime_type,
                a.uti,
                a.transfer_name,
                a.total_bytes
            FROM message m
            JOIN message_attachment_join maj ON maj.message_id = m.ROWID
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE m.guid IN (\(placeholders))
              AND a.hide_attachment = 0
            ORDER BY m.date DESC, a.ROWID ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseAccessError.attachmentQueryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, id) in messageIDs.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), id, -1, SQLITE_TRANSIENT)
        }

        var out: [String: [MessagesAttachment]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let messageID = sqliteColumnString(statement, 0) else { continue }
            let attachment = MessagesAttachment(
                id: sqliteColumnString(statement, 1) ?? "",
                localPath: messagesAttachmentPath(sqliteColumnString(statement, 2) ?? ""),
                mimeType: sqliteColumnString(statement, 3) ?? "",
                uti: sqliteColumnString(statement, 4) ?? "",
                fileName: sqliteColumnString(statement, 5) ?? "",
                size: Int(sqlite3_column_int64(statement, 6))
            )
            guard !attachment.localPath.isEmpty else { continue }
            out[messageID, default: []].append(attachment)
        }
        return out
    }

    private func fetchAttachmentData(at localPath: String) async throws -> Value {
        let resolved = messagesAttachmentPath(localPath)
        let root = messagesAttachmentDirectory()
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            throw DatabaseAccessError.invalidAttachmentPath
        }
        if FileManager.default.isReadableFile(atPath: resolved) {
            return try readAttachmentData(at: resolved)
        }

        if let attachmentsURL = try? resolveAttachmentsBookmarkURL() {
            return try withSecurityScopedAccess(attachmentsURL) { _ in
                try readAttachmentData(at: resolved)
            }
        }

        guard try await showAttachmentsAccessAlert() else {
            throw DatabaseAccessError.userDeclinedAccess
        }
        let attachmentsURL = try await showAttachmentsFolderPicker()
        storeAttachmentsBookmark(for: attachmentsURL)
        return try withSecurityScopedAccess(attachmentsURL) { _ in
            try readAttachmentData(at: resolved)
        }
    }

    private func readAttachmentData(at path: String) throws -> Value {
        guard let image = NSImage(contentsOfFile: path),
            let data = image.jpegData(compressionQuality: 0.82)
        else {
            throw DatabaseAccessError.invalidAttachmentPath
        }
        return .data(mimeType: "image/jpeg", data)
    }

    func sendTarget(chatID: String) async throws -> MessageSendTarget {
        try await activate()
        guard !chatID.isEmpty else { throw DatabaseAccessError.invalidChatID }
        return MessageSendTarget(chatID: chatID)
    }

    func chatID(forParticipant participant: String) async throws -> String? {
        let normalized = normalizeMessageHandle(participant)
        try await activate()
        guard !normalized.isEmpty else { return nil }
        let db = try createDatabaseConnection()
        let chats = try db.fetchChats(limit: 500)
        for chat in chats {
            if chat.participants.contains(where: { normalizeMessageHandle($0.rawValue) == normalized }) {
                return chat.id.rawValue
            }
        }
        return nil
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

    @MainActor
    private func showAttachmentsAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Messages Attachments Access Required"
        alert.informativeText = """
            To show iMessage images, we need to open your Messages Attachments folder.

            In the next screen, please select the folder `Attachments` and click "Grant Access".
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showAttachmentsFolderPicker() async throws -> URL {
        let openPanel = NSOpenPanel()
        openPanel.message = "Please select the Messages Attachments folder"
        openPanel.prompt = "Grant Access"
        openPanel.directoryURL = URL(fileURLWithPath: messagesAttachmentDirectory())
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK,
            let url = openPanel.url,
            url.path == messagesAttachmentDirectory()
        else {
            throw DatabaseAccessError.invalidFileSelected
        }

        return url
    }

    private func storeAttachmentsBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .securityScopeAllowOnlyReadAccess,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: messagesAttachmentsBookmarkKey)
            log.debug("Successfully created and stored attachments bookmark")
        } catch {
            log.error("Failed to create attachments bookmark: \(error.localizedDescription)")
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

struct MessageSendTarget {
    let chatID: String

    var appleScriptChatID: String {
        chatID
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
    let id: String
    let name: String
    let participants: [String]
    let service: String
    let unreadCount: Int
    let unreadMentionsCount: Int
    let isMuted: Bool
    let isGroup: Bool
    let lastMessageAt: String

    init(chat: Chat) {
        id = chat.id.rawValue
        name = chat.displayName ?? ""
        participants = chat.participants.map { $0.rawValue }
        service = serviceFromChatID(chat.id.rawValue)
        unreadCount = chat.unreadCount
        unreadMentionsCount = chat.unreadMentionsCount
        isMuted = chat.isMuted
        isGroup = participants.count > 1
        lastMessageAt = chat.lastMessageDate?.formatted(.iso8601) ?? ""
    }
}

struct MessagesMessage: Encodable {
    let id: String
    let chatID: String
    let text: String
    let createdAt: String
    let isFromMe: Bool
    let isUnread: Bool
    let sender: String
    let attachments: [MessagesAttachment]

    init(chatID: String, message: Message, attachments: [MessagesAttachment] = []) {
        id = message.id.rawValue
        self.chatID = chatID
        text = message.text
        createdAt = message.date.formatted(.iso8601)
        isFromMe = message.isFromMe
        isUnread = message.isUnread
        sender = message.isFromMe ? "me" : (message.sender?.rawValue ?? "unknown")
        self.attachments = attachments
    }
}

struct MessagesAttachment: Encodable {
    let id: String
    let localPath: String
    let mimeType: String
    let uti: String
    let fileName: String
    let size: Int
}

private func sqliteColumnString(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard let text = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: text)
}

private func messagesAttachmentPath(_ value: String) -> String {
    if value.hasPrefix("~/") {
        return NSString(string: value).expandingTildeInPath
    }
    if value.hasPrefix("/") {
        return value
    }
    if value.hasPrefix("Library/Messages/") {
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(value).path
    }
    if value.hasPrefix("Attachments/") {
        return URL(fileURLWithPath: messagesAttachmentRoot()).appendingPathComponent(value).path
    }
    return value
}

private func messagesAttachmentRoot() -> String {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Messages").path
}

private func messagesAttachmentDirectory() -> String {
    URL(fileURLWithPath: messagesAttachmentRoot()).appendingPathComponent("Attachments").path
}

private func clampedInt(_ value: Int?, defaultValue: Int, minimum: Int, maximum: Int) -> Int {
    let raw = value ?? defaultValue
    return min(max(raw, minimum), maximum)
}

private func serviceFromChatID(_ chatID: String) -> String {
    return chatID.localizedCaseInsensitiveContains("sms") ? "SMS" : "iMessage"
}

func normalizeMessageHandle(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let digits = trimmed.filter { $0.isNumber }
    if digits.count >= 7 {
        return digits.hasPrefix("1") && digits.count == 11 ? String(digits.dropFirst()) : String(digits)
    }
    return trimmed
}
