import SwiftUI
import Security

// MARK: - Chat transcript model

struct AssistantMessage: Identifiable {
    enum Role { case user, assistant, status }
    let id = UUID()
    let role: Role
    let text: String
}

// MARK: - Providers & models

enum AssistantProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openai
    case claudeCode

    var id: String { rawValue }

    /// API providers need a key in the Keychain; Claude Code uses the local CLI's
    /// own subscription/login instead.
    var requiresKey: Bool { self != .claudeCode }

    var title: String {
        switch self {
        case .anthropic: "Claude API"
        case .openai: "OpenAI"
        case .claudeCode: "Claude Code"
        }
    }
    var keychainAccount: String {
        switch self {
        case .anthropic: "anthropic-api-key"
        case .openai: "openai-api-key"
        case .claudeCode: "claude-code-unused"
        }
    }
    var models: [AssistantModel] {
        switch self {
        case .anthropic: AssistantModel.anthropic
        case .openai: AssistantModel.openai
        case .claudeCode: AssistantModel.claudeCode
        }
    }
    var defaultModelID: String { models.first!.id }
    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openai: "sk-…"
        case .claudeCode: ""
        }
    }
    var consoleTitle: String {
        switch self {
        case .anthropic: "Get a key from the Anthropic Console"
        case .openai: "Get a key from the OpenAI Platform"
        case .claudeCode: "Install Claude Code"
        }
    }
    var consoleURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        case .claudeCode: URL(string: "https://docs.claude.com/en/docs/claude-code/overview")!
        }
    }
}

struct AssistantModel: Identifiable, Hashable {
    let id: String        // the model id sent to the API
    let title: String

    static let anthropic: [AssistantModel] = [
        .init(id: "claude-sonnet-5", title: "Sonnet 5 · balanced"),
        .init(id: "claude-opus-4-8", title: "Opus 4.8 · most capable"),
        .init(id: "claude-haiku-4-5-20251001", title: "Haiku 4.5 · fastest")
    ]
    static let openai: [AssistantModel] = [
        .init(id: "gpt-5.5", title: "GPT-5.5 · most capable"),
        .init(id: "gpt-5.4", title: "GPT-5.4 · balanced"),
        .init(id: "gpt-5.4-mini", title: "GPT-5.4 mini · fastest")
    ]
    static let claudeCode: [AssistantModel] = [
        .init(id: "default", title: "Default (your Claude Code model)"),
        .init(id: "opus", title: "Opus"),
        .init(id: "sonnet", title: "Sonnet")
    ]
}

// MARK: - View model (the agent loop)

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published var messages: [AssistantMessage] = []
    @Published var input: String = ""
    @Published var isWorking = false
    @Published var hasAPIKey: Bool
    /// Whether the local `claude` CLI (Claude Code) was found.
    @Published var claudeCodeAvailable = false
    private var claudeLocation: ClaudeCodeLocation?

    @Published var provider: AssistantProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "assistant.provider.v2")
            model = Self.loadModel(for: provider)
            hasAPIKey = KeychainStore.read(account: provider.keychainAccount) != nil
            newConversation()
            if provider == .claudeCode { Task { await detectClaudeCode() } }
        }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "assistant.model.\(provider.rawValue)") }
    }

    var currentModels: [AssistantModel] { provider.models }

    /// The active provider is usable: an API key is present, or Claude Code is found.
    var isReady: Bool { provider.requiresKey ? hasAPIKey : claudeCodeAvailable }

    private let store: ProofStore
    /// Provider-native API conversation, retained across turns and cleared when the
    /// provider changes (the providers use different message shapes).
    private var apiConversation: [[String: Any]] = []

    init(store: ProofStore) {
        self.store = store
        let p = AssistantProvider(rawValue: UserDefaults.standard.string(forKey: "assistant.provider.v2") ?? "") ?? .claudeCode
        self.provider = p
        self.model = Self.loadModel(for: p)
        self.hasAPIKey = KeychainStore.read(account: p.keychainAccount) != nil
        Task { await detectClaudeCode() }
    }

    func detectClaudeCode() async {
        let location = await ClaudeCodeClient.locate()
        claudeLocation = location
        claudeCodeAvailable = (location != nil)
    }

    private static func loadModel(for provider: AssistantProvider) -> String {
        let stored = UserDefaults.standard.string(forKey: "assistant.model.\(provider.rawValue)")
        if let stored, provider.models.contains(where: { $0.id == stored }) { return stored }
        return provider.defaultModelID
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.save(trimmed, account: provider.keychainAccount)
        hasAPIKey = true
    }

    func clearAPIKey() {
        KeychainStore.delete(account: provider.keychainAccount)
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
        switch provider {
        case .anthropic:
            apiConversation.append(["role": "user", "content": [["type": "text", "text": text]]])
        case .openai:
            apiConversation.append(["role": "user", "content": text])
        case .claudeCode:
            break   // stateless per turn; the request is rebuilt from the graph + message
        }
        isWorking = true
        Task { await runLoop(userText: text) }
    }

    private func runLoop(userText: String) async {
        defer { isWorking = false }
        if provider == .claudeCode {
            await runClaudeCode(userText: userText)
            return
        }
        guard let apiKey = KeychainStore.read(account: provider.keychainAccount) else {
            messages.append(.init(role: .status, text: "Add your \(provider.title) API key to use the assistant."))
            hasAPIKey = false
            return
        }
        switch provider {
        case .anthropic: await runAnthropic(apiKey: apiKey)
        case .openai: await runOpenAI(apiKey: apiKey)
        case .claudeCode: break
        }
    }

    // MARK: Claude Code (local CLI, uses the user's subscription)

    private func runClaudeCode(userText: String) async {
        if claudeLocation == nil { await detectClaudeCode() }
        guard let location = claudeLocation else {
            messages.append(.init(role: .status, text: "Claude Code (the `claude` CLI) wasn't found. Install it and sign in, then reopen this panel."))
            return
        }
        do {
            let prompt = claudeCodePrompt(userText: userText)
            let modelFlag = (model == "default") ? nil : model
            let text = try await ClaudeCodeClient.run(prompt: prompt, model: modelFlag, location: location)
            handleClaudeCodeResult(text)
        } catch {
            messages.append(.init(role: .status, text: "⚠️ \(error.localizedDescription)"))
        }
    }

    private func handleClaudeCodeResult(_ text: String) {
        let (json, prose) = Self.splitReplyAndJSON(text)
        if let prose, !prose.isEmpty {
            messages.append(.init(role: .assistant, text: prose))
        }
        if let json {
            let (resultText, isError) = applyGraphData(Data(json.utf8), toolName: Self.applyToolName)
            messages.append(.init(role: .status, text: (isError ? "⚠️ " : "✏️ ") + resultText))
        } else if prose == nil {
            messages.append(.init(role: .assistant, text: "No changes were suggested."))
        }
    }

    private func claudeCodePrompt(userText: String) -> String {
        """
        \(systemPrompt())

        You are running headless and cannot call tools. Reply in two parts:
        1. A short (1–3 sentence) message to the user explaining what you are adding or
           changing (this is shown in the chat).
        2. Then the graph edit as a single JSON object inside a ```json fenced block.

        Schema: \(Self.applyToolDescription)

        Rules: every node MUST have a string "id" and a short "title". Edges use "from"
        and "to" (node ids) plus a "type" — never "source"/"target". A node's branch
        field is "branch" (not "branchId"). Reference existing ids from the current
        graph above when editing. Example of the exact format to follow:

        Added the two lemmas and linked them to the main theorem.
        ```json
        {"nodes":[{"id":"lem","type":"lemma","title":"Area lemma"}],"edges":[{"from":"lem","to":"thm","type":"supports"}]}
        ```

        User request:
        \(userText)
        """
    }

    /// Extracts the first balanced top-level JSON object from arbitrary text.
    static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Splits a Claude Code response into the graph JSON and the conversational reply.
    static func splitReplyAndJSON(_ text: String) -> (json: String?, prose: String?) {
        if let fence = firstFencedBlock(text), let json = extractJSONObject(fence.body) {
            let prose = text.replacingOccurrences(of: fence.full, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (json, prose.isEmpty ? nil : prose)
        }
        if let json = extractJSONObject(text) {
            let prose = text.replacingOccurrences(of: json, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t`"))
            return (json, prose.isEmpty ? nil : prose)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (nil, trimmed.isEmpty ? nil : trimmed)
    }

    private static func firstFencedBlock(_ text: String) -> (full: String, body: String)? {
        guard let open = text.range(of: "```") else { return nil }
        var bodyStart = open.upperBound
        // Skip an optional language tag (e.g. "json") up to the first newline.
        if let newline = text[bodyStart...].firstIndex(of: "\n") {
            let tag = text[bodyStart..<newline]
            if !tag.contains("{") { bodyStart = text.index(after: newline) }
        }
        guard let close = text.range(of: "```", range: bodyStart..<text.endIndex) else { return nil }
        let body = String(text[bodyStart..<close.lowerBound])
        let full = String(text[open.lowerBound..<close.upperBound])
        return (full, body)
    }

    // MARK: Anthropic loop

    private func runAnthropic(apiKey: String) async {
        do {
            for _ in 0..<6 {
                let body: [String: Any] = [
                    "model": model,
                    "max_tokens": 8192,
                    "system": systemPrompt(),
                    "tools": [Self.anthropicToolSchema],
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
                if !trimmed.isEmpty { messages.append(.init(role: .assistant, text: trimmed)) }

                guard response.stopReason == "tool_use", !toolUses.isEmpty else { break }

                var toolResults: [[String: Any]] = []
                for use in toolUses {
                    let (resultText, isError) = applyGraphData(Data(jsonValue: use.input), toolName: use.name)
                    var result: [String: Any] = ["type": "tool_result", "tool_use_id": use.id, "content": resultText]
                    if isError { result["is_error"] = true }
                    toolResults.append(result)
                    if !isError { messages.append(.init(role: .status, text: "✏️ \(resultText)")) }
                }
                apiConversation.append(["role": "user", "content": toolResults])
            }
        } catch {
            messages.append(.init(role: .status, text: "⚠️ \(error.localizedDescription)"))
        }
    }

    // MARK: OpenAI loop (Chat Completions)

    private func runOpenAI(apiKey: String) async {
        do {
            for _ in 0..<6 {
                var requestMessages: [[String: Any]] = [["role": "system", "content": systemPrompt()]]
                requestMessages.append(contentsOf: apiConversation)
                let body: [String: Any] = [
                    "model": model,
                    "messages": requestMessages,
                    "tools": [Self.openAIToolSchema],
                    "tool_choice": "auto"
                ]
                let bodyData = try JSONSerialization.data(withJSONObject: body)
                let response = try await OpenAIClient.perform(bodyData: bodyData, apiKey: apiKey)
                guard let choice = response.choices.first else { break }

                let toolCalls = choice.message.tool_calls ?? []
                var assistantMessage: [String: Any] = ["role": "assistant"]
                // Content may be null when the model only makes tool calls; keep it an
                // empty string otherwise so the message stays valid if it is re-sent.
                assistantMessage["content"] = choice.message.content ?? (toolCalls.isEmpty ? "" : NSNull())
                if !toolCalls.isEmpty {
                    assistantMessage["tool_calls"] = toolCalls.map { call in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.function.name, "arguments": call.function.arguments]]
                    }
                }
                apiConversation.append(assistantMessage)

                if let text = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    messages.append(.init(role: .assistant, text: text))
                }

                guard !toolCalls.isEmpty else { break }

                for call in toolCalls {
                    let (resultText, isError) = applyGraphData(Data(call.function.arguments.utf8), toolName: call.function.name)
                    apiConversation.append(["role": "tool", "tool_call_id": call.id, "content": resultText])
                    if !isError { messages.append(.init(role: .status, text: "✏️ \(resultText)")) }
                }
            }
        } catch {
            messages.append(.init(role: .status, text: "⚠️ \(error.localizedDescription)"))
        }
    }

    /// Applies a tool call's JSON arguments to the graph. Returns (message, isError).
    private func applyGraphData(_ data: Data, toolName: String) -> (String, Bool) {
        guard toolName == Self.applyToolName else { return ("Unknown tool '\(toolName)'.", true) }
        do {
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

    private static let applyToolDescription = """
        Add to or edit the open Apodexis proof graph. Provide `nodes` and/or `edges` \
        (and optionally `branches`, `title`). Nodes: {id, type, title, statement, \
        context, proofSketch, status, verification, assumptions, subgoals, symbols, \
        formalDialect, formalCode, tags, branch}. Only `id` and `title` are required \
        for a new node; for an edit, send the existing id plus the changed fields. \
        Edges: {from, to, type, label}. Do not include `position`.
        """

    private static let applyToolParameters: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "branches": ["type": "array", "items": ["type": "object"]],
            "nodes": ["type": "array", "items": ["type": "object"]],
            "edges": ["type": "array", "items": ["type": "object"]]
        ]
    ]

    /// Anthropic Messages API tool shape.
    static let anthropicToolSchema: [String: Any] = [
        "name": applyToolName,
        "description": applyToolDescription,
        "input_schema": applyToolParameters
    ]

    /// OpenAI Chat Completions tool shape.
    static let openAIToolSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": applyToolName,
            "description": applyToolDescription,
            "parameters": applyToolParameters
        ]
    ]
}

private extension Data {
    init(jsonValue: JSONValue) {
        self = (try? JSONSerialization.data(withJSONObject: jsonValue.foundationObject)) ?? Data("{}".utf8)
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
            throw AssistantError.message("API error (HTTP \(http.statusCode)): \(errorMessage(from: data))")
        }
        do {
            return try JSONDecoder().decode(APIResponse.self, from: data)
        } catch {
            throw AssistantError.message("Could not read the API response.")
        }
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

// MARK: - OpenAI Chat Completions client

private enum OpenAIClient {
    static func perform(bodyData: Data, apiKey: String) async throws -> OpenAIResponse {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.message("No response from the API.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AssistantError.message("API error (HTTP \(http.statusCode)): \(errorMessage(from: data))")
        }
        do {
            return try JSONDecoder().decode(OpenAIResponse.self, from: data)
        } catch {
            throw AssistantError.message("Could not read the API response.")
        }
    }
}

private struct OpenAIResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
        let finish_reason: String?

        struct Message: Decodable {
            let content: String?
            let tool_calls: [ToolCall]?
        }
        struct ToolCall: Decodable {
            let id: String
            let function: Function
            struct Function: Decodable {
                let name: String
                let arguments: String
            }
        }
    }
}

private func errorMessage(from data: Data) -> String {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let error = object["error"] as? [String: Any],
       let message = error["message"] as? String {
        return message
    }
    return String(data: data, encoding: .utf8) ?? "unknown error"
}

enum AssistantError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

// MARK: - Claude Code CLI client (headless; uses the local login/subscription)

struct ClaudeCodeLocation: Sendable {
    let executable: String
    let pathEnv: String
}

private enum ClaudeCodeClient {
    /// Finds the `claude` binary. GUI apps launched from Finder have a minimal PATH
    /// and a non-interactive shell doesn't source ~/.zshrc, so we first probe the
    /// known install locations directly, then fall back to an interactive login shell.
    static func locate() async -> ClaudeCodeLocation? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.deno/bin/claude",
            "\(home)/.volta/bin/claude"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return ClaudeCodeLocation(executable: path, pathEnv: defaultPathEnv(home: home))
        }

        // Fall back to an interactive login shell so ~/.zshrc PATH additions apply.
        guard let output = try? await runProcess(
            executable: "/bin/zsh",
            arguments: ["-ilc", "command -v claude; printf '__PATH__%s' \"$PATH\""],
            environment: nil
        ) else { return nil }

        var executable: String?
        var pathEnv: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("__PATH__") {
                pathEnv = String(line.dropFirst("__PATH__".count))
            } else if line.contains("/claude") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if FileManager.default.isExecutableFile(atPath: trimmed) { executable = trimmed }
            }
        }
        guard let executable else { return nil }
        return ClaudeCodeLocation(executable: executable, pathEnv: pathEnv ?? defaultPathEnv(home: home))
    }

    /// A broad PATH so the CLI (and any Node it may shell out to) resolves, even
    /// when the app itself was launched with a minimal environment.
    private static func defaultPathEnv(home: String) -> String {
        var dirs = [
            "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin",
            "/usr/local/bin", "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        if let inherited = ProcessInfo.processInfo.environment["PATH"] { dirs.append(inherited) }
        return dirs.joined(separator: ":")
    }

    static func run(prompt: String, model: String?, location: ClaudeCodeLocation) async throws -> String {
        var arguments = ["-p", prompt, "--output-format", "json", "--max-turns", "1"]
        if let model, !model.isEmpty { arguments += ["--model", model] }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = location.pathEnv

        let output = try await runProcess(executable: location.executable, arguments: arguments, environment: environment)
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.message("Claude Code returned no output. Make sure you're signed in — run `claude` once in a terminal.")
        }
        if let isError = object["is_error"] as? Bool, isError {
            throw AssistantError.message((object["result"] as? String) ?? "Claude Code reported an error.")
        }
        return (object["result"] as? String) ?? ""
    }

    private static func runProcess(executable: String, arguments: [String], environment: [String: String]?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: AssistantError.message("Couldn't launch Claude Code: \(error.localizedDescription)"))
                    return
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: outData, encoding: .utf8) ?? ""
                if output.isEmpty, process.terminationStatus != 0 {
                    let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: AssistantError.message(
                        (message?.isEmpty == false) ? message! : "Claude Code exited with status \(process.terminationStatus)."))
                } else {
                    continuation.resume(returning: output)
                }
            }
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

// MARK: - Keychain storage for API keys (per provider)

enum KeychainStore {
    private static let service = "com.local.Apodexis"

    static func save(_ value: String, account: String) {
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

    static func read(account: String) -> String? {
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

    static func delete(account: String) {
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
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if assistant.isReady {
                conversation
                inputBar
            } else {
                setupView
            }
        }
        .frame(minWidth: 300)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Assistant")
                .font(.headline)
            Spacer()

            Text(assistant.provider.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                assistant.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("New conversation")

            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Assistant settings")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                settingsView
                    .frame(width: 320)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Assistant")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("PROVIDER")
                    .font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.secondary)
                Picker("Provider", selection: $assistant.provider) {
                    ForEach(AssistantProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("MODEL")
                    .font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.secondary)
                Picker("Model", selection: $assistant.model) {
                    ForEach(assistant.currentModels) { model in
                        Text(model.title).tag(model.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            if assistant.provider.requiresKey {
                keySettings
            } else {
                claudeCodeStatus
            }
        }
        .padding(16)
    }

    private var keySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(assistant.provider.title) KEY")
                .font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.secondary)

            if assistant.hasAPIKey {
                HStack {
                    Label("Key saved in Keychain", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Remove", role: .destructive) { assistant.clearAPIKey() }
                        .controlSize(.small)
                }
            } else {
                SecureField(assistant.provider.keyPlaceholder, text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                Button {
                    save()
                } label: {
                    Label("Save Key", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Link(assistant.provider.consoleTitle, destination: assistant.provider.consoleURL)
                .font(.caption)
        }
    }

    private var claudeCodeStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if assistant.claudeCodeAvailable {
                Label("Using your Claude subscription — no API key needed.", systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("The `claude` CLI wasn't found.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Button {
                    Task { await assistant.detectClaudeCode() }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                Link(assistant.provider.consoleTitle, destination: assistant.provider.consoleURL)
                    .font(.caption)
            }
        }
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

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up the assistant")
                .font(.headline)
            Text("Build and edit your proof graph with AI. Use your Claude subscription through Claude Code (no key needed), or add a Claude or OpenAI API key.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showSettings = true
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)

            if assistant.provider == .claudeCode {
                Button {
                    Task { await assistant.detectClaudeCode() }
                } label: {
                    Label("Re-check Claude Code", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

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
