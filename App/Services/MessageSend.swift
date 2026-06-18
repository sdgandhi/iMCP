import AppKit
import Carbon
import Foundation
import JSONSchema
import OSLog

private let sendLog = Logger.service("message-send")

final class MessageSendService: Service {
    static let shared = MessageSendService()

    var isActivated: Bool {
        get async { false }
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
                    "chat_id": .integer(description: "Messages chat row id"),
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
            guard let chatID = arguments["chat_id"]?.intValue else {
                throw MessageSendError.invalidChatID
            }
            let text = arguments["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw MessageSendError.emptyText
            }

            let target = try await MessageService.shared.sendTarget(chatID: Int64(chatID))
            try MessagesAutomation.send(text: text, to: target)
            sendLog.notice("Sent message through Messages chat \(chatID)")
            return MessagesSendPayload(
                status: "sent",
                chatID: target.chatID,
                pendingMessageID: "imessage-pending-\(UUID().uuidString)"
            )
        }
    }
}

private enum MessageSendError: LocalizedError {
    case invalidChatID
    case emptyText
    case missingChatIdentifier
    case appleScriptFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidChatID:
            return "Invalid Messages chat id"
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
    let chatID: Int64
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
            on run argv
                set targetChatID to item 1 of argv
                set messageText to item 2 of argv
                tell application "Messages"
                    set targetChat to chat id targetChatID
                    send messageText to targetChat
                end tell
            end run
            """, arguments: [chatID, text])
    }

    private static func runAppleScript(_ source: String, arguments: [String] = []) throws {
        guard let script = NSAppleScript(source: source) else {
            throw MessageSendError.appleScriptFailure("Unable to compile Messages AppleScript")
        }

        var errorInfo: NSDictionary?
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(string: "run"),
            forKeyword: AEKeyword(keyASSubroutineName)
        )
        let list = NSAppleEventDescriptor.list()
        for (index, value) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        event.setParam(list, forKeyword: keyDirectObject)
        script.executeAppleEvent(event, error: &errorInfo)

        guard let errorInfo else { return }
        let message = (errorInfo[NSAppleScript.errorMessage] as? String)
            ?? "Messages automation is not authorized"
        throw MessageSendError.appleScriptFailure(message)
    }
}
