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

struct ConversationAttachment: Identifiable, Equatable, Sendable {
    let attachmentId: String
    let mediaType: String
    let width: Int
    let height: Int
    let name: String?

    var id: String { attachmentId }
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
    let attachments: [ConversationAttachment]

    init(
        id: String,
        seq: Int,
        time: Double,
        kind: ConversationItemKind,
        title: String?,
        text: String,
        detail: String?,
        activityState: ActivityState?,
        card: String?,
        isStreaming: Bool,
        attachments: [ConversationAttachment] = []
    ) {
        self.id = id
        self.seq = seq
        self.time = time
        self.kind = kind
        self.title = title
        self.text = text
        self.detail = detail
        self.activityState = activityState
        self.card = card
        self.isStreaming = isStreaming
        self.attachments = attachments
    }
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

    private struct NativeToolState {
        let id: String
        let seq: Int
        let time: Double
        var title: String
        var kind: String?
        var status: String?
        var rawInput: JSONValue?
        var rawOutput: JSONValue?
        var content: JSONValue?
        var locations: JSONValue?
    }

    private struct NativePlanState {
        let id: String
        let seq: Int
        let time: Double
        var text: String
        var detail: String?
        var completed: Bool
    }

    static func project(_ records: [SessionEventRecord]) -> [ConversationItem] {
        let ordered = records.sorted { $0.event.seq < $1.event.seq }
        var results: [String: ToolResult] = [:]
        var finalizedSteps: Set<StepKey> = []
        var partials: [StepKey: Partial] = [:]
        var nativeTools: [String: NativeToolState] = [:]
        var nativePlans: [String: NativePlanState] = [:]

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
            if event.type == "harness/native-event", let native = event.data["event"] {
                foldNativeEvent(
                    native,
                    event: event,
                    tools: &nativeTools,
                    plans: &nativePlans
                )
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


        for tool in nativeTools.values {
            items.append(nativeToolItem(tool))
        }
        for plan in nativePlans.values {
            items.append(ConversationItem(
                id: "harness-plan:\(plan.id)",
                seq: plan.seq,
                time: plan.time,
                kind: .activity,
                title: "Plan",
                text: plan.text,
                detail: plan.detail,
                activityState: plan.completed ? .completed : .running,
                card: "plan",
                isStreaming: !plan.completed
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
        let attachments = imageAttachments(event.data["content"])

        if sourceKind == "user" || sourceKind == nil {
            guard !text.isEmpty || !attachments.isEmpty else { return nil }
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
                isStreaming: false,
                attachments: attachments
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
        let attachments = imageAttachments(message["content"])
        guard !text.isEmpty || !reasoning.isEmpty || !attachments.isEmpty else { return nil }
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
            isStreaming: false,
            attachments: attachments
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

    private static func imageAttachments(_ value: JSONValue?) -> [ConversationAttachment] {
        value?.arrayValue?.compactMap { block in
            guard block["type"]?.stringValue == "image",
                  let attachment = block["attachment"],
                  let attachmentId = attachment["attachmentId"]?.stringValue,
                  let mediaType = attachment["mediaType"]?.stringValue,
                  let width = attachment["width"]?.intValue,
                  let height = attachment["height"]?.intValue,
                  mediaType.lowercased().hasPrefix("image/") else { return nil }
            return ConversationAttachment(
                attachmentId: attachmentId,
                mediaType: mediaType,
                width: max(1, width),
                height: max(1, height),
                name: attachment["name"]?.stringValue
            )
        } ?? []
    }

    private static func foldNativeEvent(
        _ native: JSONValue,
        event: SessionEvent,
        tools: inout [String: NativeToolState],
        plans: inout [String: NativePlanState]
    ) {
        if let updateType = native["sessionUpdate"]?.stringValue {
            switch updateType {
            case "tool_call", "tool_call_update":
                guard let id = native["toolCallId"]?.stringValue else { return }
                var state = tools[id] ?? NativeToolState(
                    id: id,
                    seq: event.seq,
                    time: event.time,
                    title: native["title"]?.stringValue ?? "Harness tool",
                    kind: nil,
                    status: nil,
                    rawInput: nil,
                    rawOutput: nil,
                    content: nil,
                    locations: nil
                )
                if let title = native["title"]?.stringValue { state.title = title }
                if let kind = native["kind"]?.stringValue { state.kind = kind }
                if let status = native["status"]?.stringValue { state.status = status }
                if let rawInput = native["rawInput"], rawInput != .null { state.rawInput = rawInput }
                if let rawOutput = native["rawOutput"], rawOutput != .null { state.rawOutput = rawOutput }
                if let content = native["content"], content != .null { state.content = content }
                if let locations = native["locations"], locations != .null { state.locations = locations }
                tools[id] = state
            case "plan":
                let entries = native["entries"]?.arrayValue ?? []
                plans["default"] = nativePlan(
                    id: "default",
                    seq: event.seq,
                    time: event.time,
                    entries: entries
                )
            case "plan_update":
                guard let plan = native["plan"], let id = plan["id"]?.stringValue else { return }
                switch plan["type"]?.stringValue {
                case "items":
                    plans[id] = nativePlan(
                        id: id,
                        seq: plans[id]?.seq ?? event.seq,
                        time: plans[id]?.time ?? event.time,
                        entries: plan["entries"]?.arrayValue ?? []
                    )
                case "markdown":
                    let value = plan["content"]?.stringValue ?? ""
                    plans[id] = NativePlanState(
                        id: id,
                        seq: plans[id]?.seq ?? event.seq,
                        time: plans[id]?.time ?? event.time,
                        text: value,
                        detail: "Harness plan",
                        completed: false
                    )
                case "file":
                    let uri = plan["uri"]?.stringValue ?? "Plan file"
                    plans[id] = NativePlanState(
                        id: id,
                        seq: plans[id]?.seq ?? event.seq,
                        time: plans[id]?.time ?? event.time,
                        text: uri,
                        detail: "Plan stored by the Harness",
                        completed: false
                    )
                default:
                    break
                }
            case "plan_removed":
                if let id = native["id"]?.stringValue { plans.removeValue(forKey: id) }
            default:
                break
            }
            return
        }

        guard let method = native["method"]?.stringValue,
              method.hasPrefix("item/"),
              let item = native["params"]?["item"],
              let itemType = item["type"]?.stringValue,
              itemType != "agentMessage", itemType != "reasoning" else { return }
        let id = item["id"]?.stringValue
            ?? native["params"]?["itemId"]?.stringValue
            ?? "codex-\(event.seq)"
        var state = tools[id] ?? NativeToolState(
            id: id,
            seq: event.seq,
            time: event.time,
            title: codexItemTitle(itemType: itemType, item: item),
            kind: itemType,
            status: nil,
            rawInput: nil,
            rawOutput: nil,
            content: nil,
            locations: nil
        )
        state.title = codexItemTitle(itemType: itemType, item: item)
        state.status = method == "item/completed" ? codexItemTerminalStatus(item) : "in_progress"
        state.rawInput = item["command"] ?? item["query"] ?? item["input"] ?? state.rawInput
        state.rawOutput = item["aggregatedOutput"] ?? item["output"] ?? item["result"] ?? state.rawOutput
        state.content = item["changes"] ?? item["content"] ?? state.content
        tools[id] = state
    }

    private static func nativePlan(id: String, seq: Int, time: Double, entries: [JSONValue]) -> NativePlanState {
        let completedCount = entries.filter { $0["status"]?.stringValue == "completed" }.count
        let text = entries.map { entry -> String in
            let status = entry["status"]?.stringValue ?? "pending"
            let marker = status == "completed" ? "x" : " "
            return "- [\(marker)] \(entry["content"]?.stringValue ?? "Untitled step")"
        }.joined(separator: "\n")
        return NativePlanState(
            id: id,
            seq: seq,
            time: time,
            text: text,
            detail: entries.isEmpty ? "Empty plan" : "\(completedCount) of \(entries.count) complete",
            completed: !entries.isEmpty && completedCount == entries.count
        )
    }

    private static func nativeToolItem(_ tool: NativeToolState) -> ConversationItem {
        let output = nativeToolOutput(tool)
        let detail = nativeToolDetail(tool)
        let state: ActivityState
        switch tool.status {
        case "completed": state = .completed
        case "failed": state = .failed
        default: state = .running
        }
        return ConversationItem(
            id: "harness-tool:\(tool.id)",
            seq: tool.seq,
            time: tool.time,
            kind: .activity,
            title: tool.title,
            text: output,
            detail: detail,
            activityState: state,
            card: tool.kind ?? "generic",
            isStreaming: state == .running
        )
    }

    private static func nativeToolDetail(_ tool: NativeToolState) -> String? {
        if let locations = tool.locations?.arrayValue, !locations.isEmpty {
            let paths = locations.compactMap { $0["path"]?.stringValue }
            if !paths.isEmpty { return paths.joined(separator: ", ") }
        }
        guard let input = tool.rawInput else { return nil }
        return concise(displayJSON(input))
    }

    private static func nativeToolOutput(_ tool: NativeToolState) -> String {
        var parts: [String] = []
        if let content = tool.content?.arrayValue {
            for block in content {
                switch block["type"]?.stringValue {
                case "content":
                    let payload = block["content"] ?? block
                    if payload["type"]?.stringValue == "text", let text = payload["text"]?.stringValue {
                        parts.append(text)
                    } else if payload["type"]?.stringValue == "resource_link", let uri = payload["uri"]?.stringValue {
                        parts.append(uri)
                    }
                case "diff":
                    let path = block["path"]?.stringValue ?? "File change"
                    let oldText = block["oldText"]?.stringValue ?? ""
                    let newText = block["newText"]?.stringValue ?? ""
                    parts.append("\(path)\n--- before\n\(oldText)\n+++ after\n\(newText)")
                case "terminal":
                    if let id = block["terminalId"]?.stringValue { parts.append("Terminal \(id)") }
                default:
                    break
                }
            }
        }
        if let raw = tool.rawOutput {
            let value = displayJSON(raw)
            if !value.isEmpty && !parts.contains(value) { parts.append(value) }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func codexItemTitle(itemType: String, item: JSONValue) -> String {
        if let title = item["title"]?.stringValue, !title.isEmpty { return title }
        if itemType == "commandExecution", let command = item["command"]?.stringValue {
            return command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "Command"
        }
        if itemType == "webSearch", let query = item["query"]?.stringValue { return "Search: \(query)" }
        return humanizedToolName(itemType)
    }

    private static func codexItemTerminalStatus(_ item: JSONValue) -> String {
        let status = item["status"]?.stringValue ?? "completed"
        return ["failed", "declined", "error"].contains(status) ? "failed" : "completed"
    }

    private static func displayJSON(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return "" }
        return text
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
