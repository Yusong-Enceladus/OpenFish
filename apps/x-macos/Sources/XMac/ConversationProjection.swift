import Foundation

enum ConversationItemKind: Equatable, Sendable {
    case user
    case assistant
    case activity
    case notice
}

enum ActivityState: Equatable, Sendable {
    case running
    case completed
    case failed
}

struct ConversationItem: Identifiable, Equatable, Sendable {
    let id: String
    let seq: Int
    let time: Double
    let kind: ConversationItemKind
    let title: String?
    let text: String
    let detail: String?
    let activityState: ActivityState?
    let card: String?
    let isStreaming: Bool
}

/// Pure, ephemeral rendering projection over DSH's authoritative event records.
/// Unknown event/plugin data remains on the wire and degrades to a compact notice only when
/// it explicitly opted into the conversation surface.
enum ConversationProjector {
    private struct StepKey: Hashable {
        let turn: Int
        let step: Int
    }

    private struct Partial {
        var textByIndex: [Int: String] = [:]
        var reasoningByIndex: [Int: String] = [:]
        var seq = 0
        var time: Double = 0
    }

    private struct ToolResult {
        let record: SessionEventRecord
        let callId: String
        let output: String
        let failed: Bool
    }

    static func project(_ records: [SessionEventRecord]) -> [ConversationItem] {
        let ordered = records.sorted { $0.event.seq < $1.event.seq }
        var results: [String: ToolResult] = [:]
        var finalizedSteps: Set<StepKey> = []
        var partials: [StepKey: Partial] = [:]

        for record in ordered {
            let event = record.event
            if event.type == "tool/result", let result = toolResult(from: record) {
                results[result.callId] = result
            }
            if event.type == "assistant/message",
               let key = stepKey(from: event.data) {
                finalizedSteps.insert(key)
            }
            if event.type == "assistant/chunk",
               let key = stepKey(from: event.data),
               let chunk = event.data["chunk"] {
                var partial = partials[key] ?? Partial()
                apply(chunk: chunk, to: &partial)
                partial.seq = event.seq
                partial.time = event.time
                partials[key] = partial
            }
        }

        var items: [ConversationItem] = []
        for record in ordered {
            let event = record.event
            switch event.type {
            case "user/message":
                if let item = userItem(from: event) { items.append(item) }
            case "assistant/message":
                if let item = assistantItem(from: event) { items.append(item) }
            case "tool/call":
                if let item = toolItem(from: record, result: callId(from: event.data).flatMap { results[$0] }) {
                    items.append(item)
                }
            case "turn/end":
                if let item = turnNotice(from: event) { items.append(item) }
            case "assistant/chunk", "tool/result", "turn/start", "step/start", "step/end":
                break
            default:
                if let item = unknownSurfaceItem(from: event) { items.append(item) }
            }
        }

        for (key, partial) in partials where !finalizedSteps.contains(key) {
            let text = partial.textByIndex.keys.sorted().compactMap { partial.textByIndex[$0] }.joined()
            let reasoning = partial.reasoningByIndex.keys.sorted().compactMap { partial.reasoningByIndex[$0] }.joined()
            guard !text.isEmpty || !reasoning.isEmpty else { continue }
            items.append(ConversationItem(
                id: "partial:\(key.turn):\(key.step)",
                seq: partial.seq,
                time: partial.time,
                kind: .assistant,
                title: nil,
                text: text,
                detail: reasoning.isEmpty ? nil : reasoning,
                activityState: nil,
                card: nil,
                isStreaming: true
            ))
        }

        return items.sorted {
            if $0.seq != $1.seq { return $0.seq < $1.seq }
            return $0.id < $1.id
        }
    }

    private static func userItem(from event: SessionEvent) -> ConversationItem? {
        let source = event.data["source"]
        let sourceKind = source?["kind"]?.stringValue
        let text = textFromContent(event.data["content"])

        if sourceKind == "user" || sourceKind == nil {
            guard !text.isEmpty else { return nil }
            return ConversationItem(
                id: "event:\(event.seq)",
                seq: event.seq,
                time: event.time,
                kind: .user,
                title: nil,
                text: text,
                detail: nil,
                activityState: nil,
                card: nil,
                isStreaming: false
            )
        }

        let form = source?["form"]?.stringValue
        guard form == "notice" else { return nil }
        let summary = source?["summary"]?.stringValue ?? text
        guard !summary.isEmpty else { return nil }
        return ConversationItem(
            id: "context:\(event.seq)",
            seq: event.seq,
            time: event.time,
            kind: .notice,
            title: "Context",
            text: summary,
            detail: nil,
            activityState: nil,
            card: "context",
            isStreaming: false
        )
    }

    private static func assistantItem(from event: SessionEvent) -> ConversationItem? {
        let message = event.data["message"] ?? event.data
        let text = textFromContent(message["content"])
        let reasoning = reasoningFromContent(message["content"])
        guard !text.isEmpty || !reasoning.isEmpty else { return nil }
        return ConversationItem(
            id: "event:\(event.seq)",
            seq: event.seq,
            time: event.time,
            kind: .assistant,
            title: nil,
            text: text,
            detail: reasoning.isEmpty ? nil : reasoning,
            activityState: nil,
            card: nil,
            isStreaming: false
        )
    }

    private static func toolItem(from record: SessionEventRecord, result: ToolResult?) -> ConversationItem? {
        let event = record.event
        guard let callId = callId(from: event.data) else { return nil }
        let name = event.data["name"]?.stringValue ?? "tool"
        let callView = record.view?["view"]
        let resultView = result?.record.view?["view"]
        let title = resultView?["title"]?.stringValue
            ?? callView?["title"]?.stringValue
            ?? humanizedToolName(name)
        let card = resultView?["card"]?.stringValue ?? callView?["card"]?.stringValue ?? "generic"
        let rawArguments = event.data["arguments"]?.stringValue ?? ""
        let detail = callView?["description"]?.stringValue ?? concise(rawArguments)
        let output = resultView?["output"]?.stringValue ?? result?.output ?? ""
        let state: ActivityState = result == nil ? .running : (result?.failed == true ? .failed : .completed)

        return ConversationItem(
            id: "tool:\(callId)",
            seq: event.seq,
            time: event.time,
            kind: .activity,
            title: title,
            text: output,
            detail: detail,
            activityState: state,
            card: card,
            isStreaming: state == .running
        )
    }

    private static func toolResult(from record: SessionEventRecord) -> ToolResult? {
        let data = record.event.data
        let message = data["message"] ?? data
        let source = message["source"]
        let block = message["content"]?.arrayValue?.first
        let callId = source?["callId"]?.stringValue
            ?? block?["toolCallId"]?.stringValue
            ?? data["callId"]?.stringValue
        guard let callId else { return nil }

        let nestedContent = block?["content"] ?? message["content"] ?? data["content"]
        let output = textFromContent(nestedContent)
        let failed = block?["isError"]?.boolValue == true || data["error"] != nil
        return ToolResult(record: record, callId: callId, output: output, failed: failed)
    }

    private static func turnNotice(from event: SessionEvent) -> ConversationItem? {
        guard let reason = event.data["reason"], let kind = reason["kind"]?.stringValue else { return nil }
        let copy: (String, String)?
        switch kind {
        case "completed": copy = nil
        case "aborted", "interrupted": copy = ("Stopped", "The task was stopped before it finished.")
        case "max-tokens": copy = ("Output limit reached", "Continue the task to resume from this point.")
        case "error": copy = ("Task failed", reason["message"]?.stringValue ?? "The agent reported an error.")
        default: copy = nil
        }
        guard let copy else { return nil }
        return ConversationItem(
            id: "turn:\(event.seq)",
            seq: event.seq,
            time: event.time,
            kind: .notice,
            title: copy.0,
            text: copy.1,
            detail: nil,
            activityState: kind == "error" ? .failed : nil,
            card: "turn",
            isStreaming: false
        )
    }

    private static func unknownSurfaceItem(from event: SessionEvent) -> ConversationItem? {
        guard event.ignorable != true, event.surfaceOp != nil else { return nil }
        return ConversationItem(
            id: "unknown:\(event.seq)",
            seq: event.seq,
            time: event.time,
            kind: .notice,
            title: event.type,
            text: "This event is provided by a DSH extension that this client does not render yet.",
            detail: nil,
            activityState: nil,
            card: "extension",
            isStreaming: false
        )
    }

    private static func stepKey(from data: JSONValue) -> StepKey? {
        guard let turn = data["turn"]?.intValue, let step = data["step"]?.intValue else { return nil }
        return StepKey(turn: turn, step: step)
    }

    private static func callId(from data: JSONValue) -> String? {
        data["callId"]?.stringValue
    }

    private static func apply(chunk: JSONValue, to partial: inout Partial) {
        guard let type = chunk["type"]?.stringValue else { return }
        let index = chunk["index"]?.intValue ?? 0
        switch type {
        case "text-delta":
            partial.textByIndex[index, default: ""] += chunk["text"]?.stringValue ?? ""
        case "reasoning-delta":
            partial.reasoningByIndex[index, default: ""] += chunk["text"]?.stringValue ?? ""
        case "block-end":
            guard let block = chunk["block"], let blockType = block["type"]?.stringValue else { return }
            if blockType == "text" {
                partial.textByIndex[index] = block["text"]?.stringValue ?? partial.textByIndex[index]
            } else if blockType == "reasoning" {
                partial.reasoningByIndex[index] = block["text"]?.stringValue ?? partial.reasoningByIndex[index]
            }
        default:
            break
        }
    }

    private static func textFromContent(_ value: JSONValue?) -> String {
        guard let blocks = value?.arrayValue else { return "" }
        return blocks.compactMap { block -> String? in
            switch block["type"]?.stringValue {
            case "text":
                return block["text"]?.stringValue
            case "tool-result":
                return textFromContent(block["content"])
            default:
                return nil
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func reasoningFromContent(_ value: JSONValue?) -> String {
        guard let blocks = value?.arrayValue else { return "" }
        return blocks.compactMap { block in
            block["type"]?.stringValue == "reasoning" ? block["text"]?.stringValue : nil
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func concise(_ value: String) -> String? {
        let singleLine = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty, singleLine != "{}" else { return nil }
        return singleLine.count <= 120 ? singleLine : String(singleLine.prefix(119)) + "…"
    }

    private static func humanizedToolName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
