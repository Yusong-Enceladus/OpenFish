import Foundation

@main
struct ProjectionSmoke {
    static func main() throws {
        let records = [
            record(1, "user/message", [
                "content": .array([.object(["type": .string("text"), "text": .string("Build the feature")])]),
                "source": .object(["kind": .string("user")]),
            ]),
            record(2, "assistant/chunk", [
                "turn": .number(1), "step": .number(1),
                "chunk": .object(["type": .string("text-delta"), "index": .number(0), "text": .string("Working")]),
            ]),
            record(3, "assistant/chunk", [
                "turn": .number(1), "step": .number(1),
                "chunk": .object(["type": .string("text-delta"), "index": .number(0), "text": .string(" now")]),
            ]),
            record(4, "tool/call", [
                "turn": .number(1), "step": .number(1), "callId": .string("call-1"),
                "name": .string("bash"), "arguments": .string("{\"cmd\":\"pnpm test\"}"),
            ], view: .object([
                "for": .string("call"),
                "view": .object(["card": .string("terminal"), "title": .string("Run tests")]),
            ])),
            record(5, "tool/result", [
                "turn": .number(1), "step": .number(1),
                "message": .object([
                    "source": .object(["kind": .string("tool"), "callId": .string("call-1")]),
                    "content": .array([.object([
                        "type": .string("tool-result"), "toolCallId": .string("call-1"),
                        "isError": .bool(false),
                        "content": .array([.object(["type": .string("text"), "text": .string("12 passed")])]),
                    ])]),
                ]),
            ], view: .object([
                "for": .string("result"),
                "view": .object(["card": .string("terminal"), "output": .string("12 passed")]),
            ])),
            record(6, "assistant/message", [
                "turn": .number(1), "step": .number(2),
                "message": .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("Done")])]),
                ]),
            ]),
            record(7, "assistant/message", [
                "turn": .number(1), "step": .number(3),
                "message": .object([
                    "content": .array([
                        .object(["type": .string("reasoning"), "text": .string("Inspect first")]),
                        .object(["type": .string("text"), "text": .string("Then answer")]),
                    ]),
                ]),
            ]),
        ]

        let items = ConversationProjector.project(records)
        require(items.contains { $0.kind == .user && $0.text == "Build the feature" }, "user projection")
        require(items.contains { $0.id == "partial:1:1" && $0.text == "Working now" && $0.isStreaming }, "partial projection")
        require(items.contains {
            $0.kind == .activity && $0.title == "Run tests" && $0.text == "12 passed" && $0.activityState == .completed
        }, "tool call/result pairing")
        require(items.contains { $0.kind == .assistant && $0.text == "Done" && !$0.isStreaming }, "assistant projection")
        require(items.contains {
            $0.seq == 7 && $0.text == "Then answer" && $0.detail == "Inspect first"
        }, "reasoning precedes the answer without replacing it")

        let approvalJSON = Data(#"{"type":"server-request","rpcId":"approval-rpc","method":"approval/requested","payload":{"type":"approval/requested","sessionId":"session-1","approvalId":"approval-1","toolName":"bash","reason":"sandbox escalation"}}"#.utf8)
        let approval = try JSONDecoder().decode(DshServerRequest.self, from: approvalJSON)
        require(approval.rpcId == "approval-rpc", "answer correlation")
        require(approval.payload["approvalId"]?.stringValue == "approval-1", "approval identity")

        print("OpenFish projection smoke passed: streaming, tool pairing, reasoning order, final messages, and approval correlation")
    }

    private static func record(
        _ seq: Int,
        _ type: String,
        _ data: [String: JSONValue],
        view: JSONValue? = nil
    ) -> SessionEventRecord {
        SessionEventRecord(
            event: SessionEvent(
                type: type,
                seq: seq,
                time: Double(seq),
                data: .object(data),
                sourceEventSeqs: nil,
                surfaceOp: nil,
                ignorable: nil
            ),
            view: view
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            fputs("Projection smoke failed: \(label)\n", stderr)
            exit(1)
        }
    }
}
