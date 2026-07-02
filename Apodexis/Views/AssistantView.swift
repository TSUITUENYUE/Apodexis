import SwiftUI
import Security

// MARK: - Chat transcript model

struct AssistantMessage: Identifiable {
    enum Role { case user, assistant, status }
    let id = UUID()
    let role: Role
    let text: String
}

// MARK: - View model (the agent loop)

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published var messages: [AssistantMessage] = []
    @Published var input: String = ""
    @Published var isWorking = false
    @Published var hasAPIKey: Bool
    @AppStorage("assistant.model") var model: String = AssistantModel.default.rawValue

    private let store: ProofStore
    /// Raw Anthropic Messages API conversation, retained across turns.
    private var apiConversation: [[String: Any]] = []

    init(store: ProofStore) {
        self.store = store
        self.hasAPIKey = KeychainStore.read() != nil
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.save(trimmed)
        hasAPIKey = true
    }

    func clearAPIKey() {
        KeychainStore.delete()
        hasAPIKey = false
    }

    func newConversation() {
        apiConversation.removeAll()
        messages.removeAll()
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        guard store.hasOpenProject else {
            messages.append(.init(role: .status, text: "Open or create a project first, then I can build its graph."))
            return
        }
        input = ""
        messages.append(.init(role: .user, text: text))
        apiConversation.append(["role": "user", "content": [["type": "text", "text": text]]])
        isWorking = true
        Task { await runLoop() }
    }

    private func runLoop() async {
        defer { isWorking = false }
        guard let apiKey = KeychainStore.read() else {
            messages.append(.init(role: .status, text: "Add your Anthropic API key to use the assistant."))
            hasAPIKey = false
            return
        }

        do {
            for _ in 0..<6 {
                let body: [String: Any] = [
                    "model": model,
                    "max_tokens": 8192,
                    "system": systemPrompt(),
                    "tools": [Self.applyToolSchema],
                    "messages": apiConversation
                ]
                let bodyData = try JSONSerialization.data(withJSONObject: body)
                let response = try await AnthropicClient.perform(bodyData: bodyData, apiKey: apiKey)

                var assistantBlocks: [[String: Any]] = []
                var assistantText = ""
                var toolUses: [(id: String, name: String, input: JSONValue)] = []

                for block in response.content {
                    switch block.type {
                    case "text":
                        let text = block.text ?? ""
                        assistantText += text
                        assistantBlocks.append(["type": "text", "text": text])
                    case "tool_use":
                        guard let id = block.id, let name = block.name else { continue }
                        let input = block.input ?? .object([:])
                        assistantBlocks.append(["type": "tool_use", "id": id, "name": name, "input": input.foundationObject])
                        toolUses.append((id, name, input))
                    default:
                        break
                    }
                }

                apiConversation.append(["role": "assistant", "content": assistantBlocks])
                let trimmed = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    messages.append(.init(role: .assistant, text: trimmed))
                }

                guard response.stopReason == "tool_use", !toolUses.isEmpty else { break }

                var toolResults: [[String: Any]] = []
                for use in toolUses {
                    let (resultText, isError) = applyTool(use)
                    var result: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": use.id,
                        "content": resultText
                    ]
                    if isError { result["is_error"] = true }
                    toolResults.append(result)
                    if !isError {
                        messages.append(.init(role: .status, text: "✏️ \(resultText)"))
                    }
                }
                apiConversation.append(["role": "user", "content": toolResults])
            }
        } catch {
            messages.append(.init(role: .status, text: "⚠️ \(error.localizedDescription)"))
        }
    }

    /// Executes one tool call against the store. Returns (message, isError).
    private func applyTool(_ use: (id: String, name: String, input: JSONValue)) -> (String, Bool) {
        guard use.name == Self.applyToolName else {
            return ("Unknown tool '\(use.name)'.", true)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: use.input.foundationObject)
            let result = try store.applyAssistantGraph(jsonData: data)
            return (result.isEmpty ? "No changes were needed." : "Graph updated: \(result.summary).", false)
        } catch {
            return ("Could not apply graph: \(error.localizedDescription)", true)
        }
    }

    private func systemPrompt() -> String {
        """
        You are the Apodexis assistant. Apodexis visualizes a mathematical or \
        scientific proof as a typed dependency graph: nodes have a type and edges \
        express semantic relationships. Help the user turn proofs, LaTeX, papers, \
        or notes into a graph — and edit the current one — by calling the \
        `\(Self.applyToolName)` tool.

        Decomposition: one node per claim or move (not per sentence). Choose the node \
        `type` from: theorem, conjecture, definition, assumption, lemma, claim, \
        proposal, strategy, conclusion, goal, reduction, caseSplit, inductionStep, \
        construction, counterexample, failedAttempt, formalCode. Connect nodes with \
        edges whose `type` is one of: uses, implies, reducesTo, equivalentTo, caseOf, \
        generalizes, contradicts, dependsOnAssumption, forksFrom, refines, supports, \
        requires, motivates, blocks, diagnoses, witnesses, constrains, summarizes \
        (edges point from cause to effect). Node `status`: open, inProgress, blocked, \
        needsReview, proven, failed, abandoned. Put remaining work in `subgoals` \
        ([{title, detail, status}]). Use LaTeX in `statement`. Never send `position`.

        To CREATE nodes, give each a new string `id` and reference those ids in edges. \
        To EDIT an existing node, use its exact `id` from the current graph below and \
        include only the fields you want to change. Keep edits minimal and precise. \
        After calling the tool, tell the user briefly what you changed.

        Current graph (ids shown are the real node/branch ids to reuse when editing):
        \(store.currentGraphImportJSON())
        """
    }

    static let applyToolName = "apply_apodexis_graph"

    static let applyToolSchema: [String: Any] = [
        "name": applyToolName,
        "description": """
        Add to or edit the open Apodexis proof graph. Provide `nodes` and/or `edges` \
        (and optionally `branches`, `title`). Nodes: {id, type, title, statement, \
        context, proofSketch, status, verification, assumptions, subgoals, symbols, \
        formalDialect, formalCode, tags, branch}. Only `id` and `title` are required \
        for a new node; for an edit, send the existing id plus the changed fields. \
        Edges: {from, to, type, label}. Do not include `position`.
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "branches": ["type": "array", "items": ["type": "object"]],
                "nodes": ["type": "array", "items": ["type": "object"]],
                "edges": ["type": "array", "items": ["type": "object"]]
            ]
        ]
    ]
}

enum AssistantModel: String, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5"
    case opus = "claude-opus-4-8"
    case haiku = "claude-haiku-4-5-20251001"

    static let `default` = AssistantModel.sonnet
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sonnet: "Sonnet 5 · balanced"
        case .opus: "Opus 4.8 · most capable"
        case .haiku: "Haiku 4.5 · fastest"
        }
    }
}

// MARK: - Anthropic Messages API client

private enum AnthropicClient {
    static func perform(bodyData: Data, apiKey: String) async throws -> APIResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.message("No response from the API.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AssistantError.message("API error (HTTP \(http.statusCode)): \(Self.errorMessage(from: data))")
        }
        do {
            return try JSONDecoder().decode(APIResponse.self, from: data)
        } catch {
            throw AssistantError.message("Could not read the API response.")
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "unknown error"
    }
}

private struct APIResponse: Decodable {
    let content: [Block]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }

    struct Block: Decodable {
        let type: String
        let text: String?
        let id: String?
        let name: String?
        let input: JSONValue?
    }
}

enum AssistantError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

// MARK: - JSONValue (arbitrary JSON, round-trippable)

enum JSONValue: Codable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// A Foundation object suitable for `JSONSerialization`.
    var foundationObject: Any {
        switch self {
        case .string(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(\.foundationObject)
        case .array(let value): value.map(\.foundationObject)
        case .null: NSNull()
        }
    }
}

// MARK: - Keychain storage for the API key

enum KeychainStore {
    private static let service = "com.local.Apodexis"
    private static let account = "anthropic-api-key"

    static func save(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - The panel

struct AssistantView: View {
    @EnvironmentObject private var assistant: AssistantViewModel
    @State private var draftKey = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if assistant.hasAPIKey {
                conversation
                inputBar
            } else {
                apiKeySetup
            }
        }
        .frame(minWidth: 300)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Assistant")
                .font(.headline)
            Spacer()
            Picker("Model", selection: $assistant.model) {
                ForEach(AssistantModel.allCases) { model in
                    Text(model.title).tag(model.rawValue)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 150)

            Menu {
                Button("New Conversation", systemImage: "square.and.pencil") {
                    assistant.newConversation()
                }
                if assistant.hasAPIKey {
                    Button("Remove API Key", systemImage: "key.slash", role: .destructive) {
                        assistant.clearAPIKey()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if assistant.messages.isEmpty {
                        emptyState
                    }
                    ForEach(assistant.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if assistant.isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").foregroundStyle(.secondary).font(.callout)
                        }
                        .id("working")
                    }
                }
                .padding(14)
            }
            .onChange(of: assistant.messages.count) {
                if let last = assistant.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Describe a proof, paste LaTeX, or ask for a change.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                SuggestionChip("Turn this LaTeX proof into a graph…") { assistant.input = "Turn this LaTeX proof into a graph:\n\n" }
                SuggestionChip("Add a lemma that 2q² = p² and link it") { assistant.input = "Add a lemma that 2q² = p² and link it into the graph." }
                SuggestionChip("Mark the main theorem as proven") { assistant.input = "Mark the main theorem as proven." }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the assistant…", text: $assistant.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1)
                }
                .onSubmit { assistant.send() }

            Button {
                assistant.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(assistant.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.isWorking)
        }
        .padding(12)
        .background(.bar)
    }

    private var apiKeySetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect the assistant")
                .font(.headline)
            Text("The assistant builds and edits your graph with Claude. Paste an Anthropic API key to enable it — it's stored in your macOS Keychain and only sent to Anthropic.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-ant-…", text: $draftKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }

            Button {
                save()
            } label: {
                Label("Save Key", systemImage: "key.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Link("Get an API key from the Anthropic Console",
                 destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .font(.caption)

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func save() {
        assistant.saveAPIKey(draftKey)
        draftKey = ""
    }
}

private struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    init(_ text: String, action: @escaping () -> Void) {
        self.text = text
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct MessageRow: View {
    let message: AssistantMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 24)
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .frame(alignment: .trailing)
            }
        case .assistant:
            Text(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .status:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
