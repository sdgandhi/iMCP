import AppKit
import Carbon
import Foundation
import JSONSchema
import OSLog

private let sendLog = Logger.service("message-send")

final class MessageSendService: Service {
    static let shared = MessageSendService()

    var isActivated: Bool {
        get async {
            do {
                try MessagesAutomation.checkAccess()
                return true
            } catch {
                return false
            }
        }
    }

    func activate() async throws {
        try MessagesAutomation.checkAccess()
    }

    var tools: [Tool] {
        Tool(
            name: "messages_authorize_send",
            description: "Prompt for Messages send automation access",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Authorize Messages Send",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { _ in
            try MessagesAutomation.checkAccess()
            return ["ok": true]
        }

        Tool(
            name: "messages_send",
            description: "Send a text message to an existing Messages chat",
            inputSchema: .object(
                properties: [
                    "chat_id": .string(description: "Messages chat id"),
                    "text": .string(description: "Message body"),
                ],
                required: ["chat_id", "text"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Send Message",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard let chatID = arguments["chat_id"]?.stringValue else {
                throw MessageSendError.invalidChatID
            }
            let text = arguments["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw MessageSendError.emptyText
            }

            let target = try await MessageService.shared.sendTarget(chatID: chatID)
            try MessagesAutomation.send(text: text, to: target)
            sendLog.notice("Sent message through Messages chat \(chatID)")
            return MessagesSendPayload(
                status: "sent",
                chatID: target.chatID,
                pendingMessageID: "imessage-pending-\(UUID().uuidString)"
            )
        }

        Tool(
            name: "messages_send_direct",
            description: "Send a text message to a Messages recipient by phone number or email",
            inputSchema: .object(
                properties: [
                    "recipient": .string(description: "Phone number or email address"),
                    "text": .string(description: "Message body"),
                ],
                required: ["recipient", "text"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Send Direct Message",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let recipient = arguments["recipient"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = arguments["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !recipient.isEmpty else {
                throw MessageSendError.invalidRecipient
            }
            guard !text.isEmpty else {
                throw MessageSendError.emptyText
            }

            try MessagesAutomation.send(text: text, toRecipient: recipient)
            let chatID = try await MessageService.shared.chatID(forParticipant: recipient) ?? recipient
            sendLog.notice("Sent direct message through Messages")
            return MessagesSendPayload(
                status: "sent",
                chatID: chatID,
                pendingMessageID: "imessage-pending-\(UUID().uuidString)"
            )
        }
    }
}

private enum MessageSendError: LocalizedError {
    case invalidChatID
    case invalidRecipient
    case emptyText
    case missingChatIdentifier
    case appleScriptFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidChatID:
            return "Invalid Messages chat id"
        case .invalidRecipient:
            return "Valid Messages recipient required"
        case .emptyText:
            return "Message text is required"
        case .missingChatIdentifier:
            return "Messages chat has no scriptable identifier"
        case .appleScriptFailure(let message):
            return message
        }
    }
}

private struct MessagesSendPayload: Encodable {
    let status: String
    let chatID: String
    let pendingMessageID: String
}

private enum MessagesAutomation {
    static func checkAccess() throws {
        try runAppleScript("""
            tell application "Messages"
                count of services
            end tell
            """)
    }

    static func send(text: String, to target: MessageSendTarget) throws {
        let chatID = target.appleScriptChatID
        guard !chatID.isEmpty else {
            throw MessageSendError.missingChatIdentifier
        }

        try runAppleScript("""
            tell application "Messages"
                set targetChat to chat id \(appleScriptString(chatID))
                send \(appleScriptString(text)) to targetChat
            end tell
            """)
    }

    static func send(text: String, toRecipient recipient: String) throws {
        try runAppleScript("""
            tell application "Messages"
                set targetService to 1st service whose service type = iMessage
                set targetBuddy to buddy \(appleScriptString(recipient)) of targetService
                send \(appleScriptString(text)) to targetBuddy
            end tell
            """)
    }

    private static func runAppleScript(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw MessageSendError.appleScriptFailure("Unable to compile Messages AppleScript")
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        guard let errorInfo else { return }
        let message = (errorInfo[NSAppleScript.errorMessage] as? String)
            ?? "Messages automation is not authorized"
        throw MessageSendError.appleScriptFailure(message)
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
