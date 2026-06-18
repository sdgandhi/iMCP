import AppKit
import OSLog
import UniformTypeIdentifiers
import iMessage

private let log = Logger.service("messages")
private let messagesDatabasePath = "/Users/\(NSUserName())/Library/Messages/chat.db"
private let messagesDatabaseBookmarkKey: String = "me.mattt.iMCP.messagesDatabaseBookmark"
private let defaultLimit = 30

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
            return MessagesHistoryPayload(
                messages: messages.prefix(limit).map { MessagesMessage(chatID: chatID, message: $0) },
                hasMore: messages.count > limit
            )
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

    func sendTarget(chatID: String) async throws -> MessageSendTarget {
        try await activate()
        guard !chatID.isEmpty else { throw DatabaseAccessError.invalidChatID }
        return MessageSendTarget(chatID: chatID)
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
    let isGroup: Bool
    let lastMessageAt: String

    init(chat: Chat) {
        id = chat.id.rawValue
        name = chat.displayName ?? ""
        participants = chat.participants.map { $0.rawValue }
        service = serviceFromChatID(chat.id.rawValue)
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
    let sender: String

    init(chatID: String, message: Message) {
        id = message.id.rawValue
        self.chatID = chatID
        text = message.text
        createdAt = message.date.formatted(.iso8601)
        isFromMe = message.isFromMe
        sender = message.isFromMe ? "me" : (message.sender?.rawValue ?? "unknown")
    }
}

private func clampedInt(_ value: Int?, defaultValue: Int, minimum: Int, maximum: Int) -> Int {
    let raw = value ?? defaultValue
    return min(max(raw, minimum), maximum)
}

private func serviceFromChatID(_ chatID: String) -> String {
    return chatID.localizedCaseInsensitiveContains("sms") ? "SMS" : "iMessage"
}
