import Foundation

enum MobileConversationKind: Equatable, Sendable { case user, assistant, activity, notice }

enum MobileConversationSectionStyle: Equatable, Sendable {
    case markdown
    case code(language: String?)
    case diff
}

struct MobileConversationSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String?
    let text: String
    let style: MobileConversationSectionStyle
}

struct MobileConversationAttachment: Identifiable, Equatable, Sendable {
    let attachmentId: String
    let mediaType: String
    let width: Int
    let height: Int
    let name: String?
    var id: String { attachmentId }
}

struct MobileConversationItem: Identifiable, Equatable, Sendable {
    let id: String
    let seq: Int
    let kind: MobileConversationKind
    let title: String?
    let text: String
    let detail: String?
    let isRunning: Bool
    let failed: Bool
    let sections: [MobileConversationSection]
    let attachments: [MobileConversationAttachment]

    init(
        id: String,
        seq: Int,
        kind: MobileConversationKind,
        title: String?,
        text: String,
        detail: String?,
        isRunning: Bool,
        failed: Bool,
        sections: [MobileConversationSection] = [],
        attachments: [MobileConversationAttachment] = []
    ) {
        self.id = id
        self.seq = seq
        self.kind = kind
        self.title = title
        self.text = text
        self.detail = detail
        self.isRunning = isRunning
        self.failed = failed
        self.sections = sections
        self.attachments = attachments
    }
}

enum MobileConversationProjector {
    private struct StepKey: Hashable { let turn: Int; let step: Int }
    private struct Partial {
        var textByIndex: [Int: String] = [:]
        var reasoningByIndex: [Int: String] = [:]
        var seq = 0
    }
    private struct ToolResult {
        let output: String
        let failed: Bool
        let view: MobileJSONValue?
    }
    private struct ToolPresentation {
        let title: String
        let summary: String?
        let sections: [MobileConversationSection]
    }

    static func project(_ records: [MobileEventRecord]) -> [MobileConversationItem] {
        let ordered = records.sorted { $0.event.seq < $1.event.seq }
        var results: [String: ToolResult] = [:]
        var finalized: Set<StepKey> = []
        var partials: [StepKey: Partial] = [:]

        for record in ordered {
            if record.event.type == "assistant/message", let key = stepKey(record.event.data) {
                finalized.insert(key)
            }
            if record.event.type == "assistant/chunk",
               let key = stepKey(record.event.data), let chunk = record.event.data["chunk"] {
                var partial = partials[key] ?? Partial()
                apply(chunk, to: &partial)
                partial.seq = record.event.seq
                partials[key] = partial
            }
            guard record.event.type == "tool/result" else { continue }
            let message = record.event.data["message"] ?? record.event.data
            let blocks = message["content"]?.arrayValue ?? []
            let callId = message["source"]?["callId"]?.stringValue
                ?? blocks.compactMap { $0["toolCallId"]?.stringValue }.first
            if let callId {
                results[callId] = ToolResult(
                    output: flattenContent(message["content"]),
                    failed: blocks.contains { $0["isError"]?.boolValue == true } || record.event.data["error"] != nil,
                    view: record.view
                )
            }
        }

        var output: [MobileConversationItem] = []
        for record in ordered {
            let event = record.event
            switch event.type {
            case "user/message":
                let source = event.data["source"]
                let value = visibleText(event.data["content"])
                let images = imageAttachments(event.data["content"])
                guard !value.isEmpty || !images.isEmpty else { continue }
                if source?["kind"]?.stringValue == "user" || source == nil {
                    output.append(.init(
                        id: "event:\(event.seq)", seq: event.seq, kind: .user,
                        title: nil, text: value, detail: nil, isRunning: false, failed: false,
                        attachments: images
                    ))
                } else if source?["form"]?.stringValue == "notice" {
                    output.append(.init(
                        id: "notice:\(event.seq)", seq: event.seq, kind: .notice,
                        title: "Context", text: source?["summary"]?.stringValue ?? value,
                        detail: nil, isRunning: false, failed: false
                    ))
                }
            case "assistant/message":
                let message = event.data["message"] ?? event.data
                let value = visibleText(message["content"])
                let thought = reasoning(message["content"])
                let images = imageAttachments(message["content"])
                guard !value.isEmpty || !thought.isEmpty || !images.isEmpty else { continue }
                output.append(.init(
                    id: "event:\(event.seq)", seq: event.seq, kind: .assistant,
                    title: nil, text: value,
                    detail: thought.isEmpty ? nil : thought,
                    isRunning: false, failed: false, attachments: images
                ))
            case "tool/call":
                guard let callId = event.data["callId"]?.stringValue else { continue }
                let result = results[callId]
                let presentation = toolPresentation(
                    name: event.data["name"]?.stringValue ?? "Tool",
                    arguments: event.data["arguments"]?.stringValue,
                    callView: record.view?["view"],
                    resultView: result?.view?["view"],
                    rawOutput: result?.output ?? ""
                )
                output.append(.init(
                    id: "tool:\(callId)", seq: event.seq, kind: .activity,
                    title: presentation.title, text: "", detail: presentation.summary,
                    isRunning: result == nil, failed: result?.failed == true,
                    sections: presentation.sections
                ))
            case "turn/end":
                let reason = event.data["reason"]?["kind"]?.stringValue
                if reason == "error" || reason == "aborted" || reason == "interrupted" {
                    let failure = event.data["reason"]?["failure"]
                    let failureText = failure?["message"]?.stringValue ?? failure?["code"]?.stringValue
                    output.append(.init(
                        id: "turn:\(event.seq)", seq: event.seq, kind: .notice,
                        title: reason == "error" ? "Task failed" : "Task stopped",
                        text: failureText ?? (reason == "error" ? "The agent reported an error." : "The run ended before completion."),
                        detail: nil, isRunning: false, failed: reason == "error"
                    ))
                }
            default:
                break
            }
        }

        for (key, partial) in partials where !finalized.contains(key) {
            let answer = partial.textByIndex.keys.sorted().compactMap { partial.textByIndex[$0] }.joined()
            let thought = partial.reasoningByIndex.keys.sorted().compactMap { partial.reasoningByIndex[$0] }.joined()
            guard !answer.isEmpty || !thought.isEmpty else { continue }
            output.append(.init(
                id: "partial:\(key.turn):\(key.step)", seq: partial.seq, kind: .assistant,
                title: nil, text: answer, detail: thought.isEmpty ? nil : thought,
                isRunning: true, failed: false
            ))
        }
        return output.sorted { $0.seq == $1.seq ? $0.id < $1.id : $0.seq < $1.seq }
    }

    private static func stepKey(_ data: MobileJSONValue) -> StepKey? {
        guard let turn = data["turn"]?.intValue, let step = data["step"]?.intValue else { return nil }
        return StepKey(turn: turn, step: step)
    }

    private static func apply(_ chunk: MobileJSONValue, to partial: inout Partial) {
        guard let type = chunk["type"]?.stringValue else { return }
        let index = chunk["index"]?.intValue ?? 0
        switch type {
        case "text-delta": partial.textByIndex[index, default: ""] += chunk["text"]?.stringValue ?? ""
        case "reasoning-delta": partial.reasoningByIndex[index, default: ""] += chunk["text"]?.stringValue ?? ""
        case "block-end":
            guard let block = chunk["block"], let blockType = block["type"]?.stringValue else { return }
            if blockType == "text" { partial.textByIndex[index] = block["text"]?.stringValue ?? partial.textByIndex[index] }
            if blockType == "reasoning" { partial.reasoningByIndex[index] = block["text"]?.stringValue ?? partial.reasoningByIndex[index] }
        default: break
        }
    }

    private static func visibleText(_ value: MobileJSONValue?) -> String {
        value?.arrayValue?.compactMap { block -> String? in
            switch block["type"]?.stringValue {
            case "text": return block["text"]?.stringValue
            case "tool-result": return flattenContent(block["content"])
            default: return nil
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n\n") ?? ""
    }

    private static func reasoning(_ value: MobileJSONValue?) -> String {
        value?.arrayValue?.compactMap {
            $0["type"]?.stringValue == "reasoning" ? $0["text"]?.stringValue : nil
        }.joined(separator: "\n\n") ?? ""
    }

    private static func imageAttachments(_ value: MobileJSONValue?) -> [MobileConversationAttachment] {
        value?.arrayValue?.compactMap { block in
            guard block["type"]?.stringValue == "image", let attachment = block["attachment"],
                  let id = attachment["attachmentId"]?.stringValue,
                  let mediaType = attachment["mediaType"]?.stringValue,
                  let width = attachment["width"]?.intValue,
                  let height = attachment["height"]?.intValue else { return nil }
            return .init(attachmentId: id, mediaType: mediaType, width: width, height: height, name: attachment["name"]?.stringValue)
        } ?? []
    }

    private static func flattenContent(_ value: MobileJSONValue?) -> String {
        guard let blocks = value?.arrayValue else { return value.map(prettyJSON) ?? "" }
        return blocks.compactMap { block -> String? in
            switch block["type"]?.stringValue {
            case "text", "reasoning": return block["text"]?.stringValue
            case "tool-result": return flattenContent(block["content"])
            case "image": return block["attachment"]?["name"]?.stringValue.map { "Image: \($0)" } ?? "Image attachment"
            default: return prettyJSON(block)
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func toolPresentation(
        name: String,
        arguments: String?,
        callView: MobileJSONValue?,
        resultView: MobileJSONValue?,
        rawOutput: String
    ) -> ToolPresentation {
        let card = resultView?["card"]?.stringValue ?? callView?["card"]?.stringValue ?? "generic"
        let callTitle = callView?["title"]?.stringValue
        let resultTitle = resultView?["title"]?.stringValue
        let description = callView?["description"]?.stringValue
        var sections: [MobileConversationSection] = []

        switch card {
        case "terminal":
            let command = callTitle ?? argumentString(arguments, keys: ["command", "cmd"])
            if let command, !command.isEmpty {
                let cwd = callView?["cwd"]?.stringValue
                sections.append(.init(id: "command", title: cwd.map { "Command · \($0)" } ?? "Command", text: command, style: .code(language: "shell")))
            }
            let output = resultView?["output"]?.stringValue ?? rawOutput
            if !output.isEmpty {
                var label = "Output"
                if let exit = resultView?["exitCode"]?.intValue { label += " · exit \(exit)" }
                if let signal = resultView?["signal"]?.stringValue { label += " · \(signal)" }
                sections.append(.init(id: "output", title: label, text: output, style: .code(language: "console")))
            }
            return .init(title: description ?? humanize(name), summary: command, sections: sections)

        case "diff":
            let diffs = resultView?["diffs"]?.arrayValue ?? callView?["diffs"]?.arrayValue ?? []
            for (index, diff) in diffs.enumerated() {
                guard let path = diff["path"]?.stringValue, let newText = diff["newText"]?.stringValue else { continue }
                sections.append(.init(
                    id: "diff:\(index)", title: path,
                    text: renderDiff(path: path, oldText: diff["oldText"]?.stringValue, newText: newText), style: .diff
                ))
            }
            addFallback(arguments: arguments, output: rawOutput, to: &sections)
            return .init(title: resultTitle ?? callTitle ?? humanize(name), summary: diffs.first?["path"]?.stringValue ?? argumentSummary(arguments), sections: sections)

        case "read":
            let path = resultView?["path"]?.stringValue
            let rendered = resultView?["lines"]?.arrayValue?.compactMap { line -> String? in
                guard let number = line["number"]?.intValue, let text = line["text"]?.stringValue else { return nil }
                return String(format: "%5d  %@", number, text)
            }.joined(separator: "\n") ?? ""
            if !rendered.isEmpty {
                let total = resultView?["totalLines"]?.intValue
                sections.append(.init(
                    id: "read", title: total.map { "\(path ?? "File") · \($0) lines" } ?? path,
                    text: rendered, style: .code(language: resultView?["lang"]?.stringValue)
                ))
            }
            addFallback(arguments: arguments, output: rendered.isEmpty ? rawOutput : "", to: &sections)
            return .init(title: resultTitle ?? callTitle ?? "Read", summary: path ?? argumentSummary(arguments), sections: sections)

        case "search":
            let rendered = renderSearch(resultView)
            if !rendered.isEmpty {
                let total = resultView?["total"]?.intValue
                let suffix = resultView?["truncated"]?.boolValue == true ? " · partial" : ""
                sections.append(.init(id: "results", title: total.map { "\($0) results\(suffix)" } ?? "Results", text: rendered, style: .code(language: nil)))
            }
            if resultView?["truncated"]?.boolValue == true, !rawOutput.isEmpty {
                sections.append(.init(id: "recovery", title: "Full result", text: rawOutput, style: .code(language: nil)))
            }
            addFallback(arguments: arguments, output: rendered.isEmpty ? rawOutput : "", to: &sections)
            return .init(title: resultTitle ?? callTitle ?? "Search", summary: argumentSummary(arguments), sections: sections)

        case "web":
            if resultView?["kind"]?.stringValue == "search" {
                if let answer = resultView?["answer"]?.stringValue, !answer.isEmpty {
                    sections.append(.init(id: "answer", title: "Answer", text: answer, style: .markdown))
                }
                let sources = renderSources(resultView?["sources"])
                if !sources.isEmpty { sections.append(.init(id: "sources", title: "Sources", text: sources, style: .markdown)) }
            } else if resultView?["kind"]?.stringValue == "fetch" {
                if let url = resultView?["url"]?.stringValue {
                    let status = resultView?["statusCode"]?.intValue
                    sections.append(.init(id: "page", title: status.map { "HTTP \($0)" } ?? "Page", text: "[\(url)](\(url))", style: .markdown))
                }
                if !rawOutput.isEmpty { sections.append(.init(id: "content", title: "Content", text: rawOutput, style: .markdown)) }
            }
            addFallback(arguments: arguments, output: sections.isEmpty ? rawOutput : "", to: &sections)
            return .init(title: resultTitle ?? callTitle ?? humanize(name), summary: argumentSummary(arguments), sections: sections)

        default:
            if let rawInput = callView?["rawInput"] {
                sections.append(.init(id: "input", title: "Input", text: prettyJSON(rawInput), style: .code(language: "json")))
            } else if let content = callView?["content"] {
                let value = flattenContent(content)
                if !value.isEmpty { sections.append(.init(id: "input", title: "Input", text: value, style: .markdown)) }
            } else if let arguments, !arguments.isEmpty {
                let body = formattedArguments(arguments, toolName: name)
                sections.append(.init(
                    id: "input", title: name == "run_code" ? "Code" : "Input", text: body,
                    style: .code(language: name == "run_code" ? "javascript" : (looksLikeJSON(body) ? "json" : nil))
                ))
            }
            let projected = resultView?["content"].map(flattenContent) ?? ""
            let finalOutput = projected.isEmpty ? rawOutput : projected
            if !finalOutput.isEmpty {
                let formatted = formatPossibleJSON(finalOutput)
                sections.append(.init(id: "output", title: "Output", text: formatted, style: .code(language: looksLikeJSON(finalOutput) ? "json" : nil)))
            }
            return .init(title: resultTitle ?? callTitle ?? humanize(name), summary: description ?? argumentSummary(arguments), sections: sections)
        }
    }

    private static func renderSearch(_ view: MobileJSONValue?) -> String {
        if view?["shape"]?.stringValue == "paths" {
            return view?["paths"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n") ?? ""
        }
        if view?["shape"]?.stringValue == "matches" {
            return view?["files"]?.arrayValue?.compactMap { file -> String? in
                guard let path = file["path"]?.stringValue else { return nil }
                let matches = file["matches"]?.arrayValue?.compactMap { match -> String? in
                    guard let line = match["line"]?.stringValue else { return nil }
                    return "\(match["lineNumber"]?.intValue.map(String.init) ?? "?"): \(line)"
                }.joined(separator: "\n") ?? ""
                return matches.isEmpty ? path : "\(path)\n\(matches)"
            }.joined(separator: "\n\n") ?? ""
        }
        return ""
    }

    private static func addFallback(arguments: String?, output: String, to sections: inout [MobileConversationSection]) {
        if sections.isEmpty, let arguments, !arguments.isEmpty {
            let formatted = formatPossibleJSON(arguments)
            sections.append(.init(id: "input", title: "Input", text: formatted, style: .code(language: looksLikeJSON(arguments) ? "json" : nil)))
        }
        if !output.isEmpty {
            let formatted = formatPossibleJSON(output)
            sections.append(.init(id: "output", title: "Output", text: formatted, style: .code(language: looksLikeJSON(output) ? "json" : nil)))
        }
    }

    private static func renderDiff(path: String, oldText: String?, newText: String) -> String {
        let oldLines = oldText?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
        let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (["--- \(path)", "+++ \(path)"] + oldLines.map { "-\($0)" } + newLines.map { "+\($0)" }).joined(separator: "\n")
    }

    private static func renderSources(_ value: MobileJSONValue?) -> String {
        value?.arrayValue?.compactMap { source -> String? in
            guard let url = source["url"]?.stringValue else { return nil }
            let title = source["title"]?.stringValue ?? URL(string: url)?.host ?? url
            var line = "- [\(title)](\(url))"
            if let snippet = source["snippet"]?.stringValue, !snippet.isEmpty { line += "\n  \(snippet)" }
            if let date = source["publishedAt"]?.stringValue, !date.isEmpty { line += "\n  \(date)" }
            return line
        }.joined(separator: "\n") ?? ""
    }

    private static func argumentSummary(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if let data = value.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data) {
            if let object = decoded as? [String: Any] {
                for key in ["description", "question", "header", "command", "cmd", "path", "file_path", "url", "query", "pattern"] {
                    if let candidate = object[key] as? String, !candidate.isEmpty { return firstLine(candidate) }
                }
                if let queries = object["queries"] as? [String], !queries.isEmpty {
                    return queries.map(firstLine).joined(separator: ", ")
                }
                if let nested = semanticSummary(in: object) { return nested }
                return object.isEmpty ? nil : "\(object.count) parameters"
            }
            if let items = decoded as? [Any] { return items.isEmpty ? nil : "\(items.count) items" }
            if let string = decoded as? String { return firstLine(string) }
            return "Structured input"
        }
        return firstLine(value.count <= 100 ? value : String(value.prefix(99)) + "…")
    }

    private static func semanticSummary(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            for key in ["description", "question", "header", "title", "command", "path", "url", "query", "pattern"] {
                if let string = object[key] as? String, !string.isEmpty { return firstLine(string) }
            }
            for child in object.values {
                if let summary = semanticSummary(in: child) { return summary }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let summary = semanticSummary(in: child) { return summary }
            }
        }
        return nil
    }

    private static func argumentString(_ value: String?, keys: [String]) -> String? {
        guard let value, let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return keys.compactMap { object[$0] as? String }.first
    }

    private static func formattedArguments(_ value: String, toolName: String) -> String {
        if toolName == "run_code", let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let code = object["code"] as? String { return code }
        return formatPossibleJSON(value)
    }

    private static func looksLikeJSON(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func formatPossibleJSON(_ value: String) -> String {
        guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8) else { return value }
        return string
    }

    private static func prettyJSON(_ value: MobileJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    private static func firstLine(_ value: String) -> String {
        value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
    }

    private static func humanize(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
