import Combine
import Foundation
import SwiftUI

@MainActor
final class ProofStore: ObservableObject {
    @Published var project: ProofProject
    @Published var selectedBranchID: UUID?
    @Published var selectedNodeID: UUID?

    private let storageURL: URL

    init(storageURL: URL = ProofStore.defaultStorageURL()) {
        self.storageURL = storageURL

        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder.proofChain.decode(ProofProject.self, from: data) {
            project = decoded
        } else {
            project = .sample()
            try? FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            persist()
        }

        selectedBranchID = project.branches.first(where: { $0.status == .active })?.id ?? project.branches.first?.id
        selectedNodeID = project.nodes.first(where: { $0.branchID == selectedBranchID })?.id ?? project.nodes.first?.id
    }

    var selectedBranch: ProofBranch? {
        guard let selectedBranchID else { return nil }
        return project.branches.first { $0.id == selectedBranchID }
    }

    var selectedNode: ProofNode? {
        guard let selectedNodeID else { return nil }
        return project.nodes.first { $0.id == selectedNodeID }
    }

    var visibleNodes: [ProofNode] {
        guard let selectedBranchID else { return project.nodes }
        return project.nodes.filter { $0.branchID == selectedBranchID }
    }

    var openSubgoals: [(node: ProofNode, subgoal: ProofSubgoal)] {
        project.nodes.flatMap { node in
            node.subgoals
                .filter { $0.status != .proven }
                .map { (node: node, subgoal: $0) }
        }
    }

    func addNode(kind: NodeKind = .claim) {
        let branchID = selectedBranchID ?? project.branches.first?.id ?? createMainBranch()
        let count = project.nodes.filter { $0.branchID == branchID }.count
        let node = ProofNode(
            title: "New \(kind.title)",
            kind: kind,
            statement: "",
            context: "",
            proofSketch: "",
            formalCode: "",
            formalDialect: .latex,
            status: .open,
            verification: .unchecked,
            branchID: branchID,
            position: GraphPoint(x: 250 + Double(count % 4) * 260, y: 180 + Double(count / 4) * 220),
            assumptions: [],
            subgoals: [],
            symbols: [],
            tags: []
        )

        mutate {
            project.nodes.append(node)
            selectedBranchID = branchID
            selectedNodeID = node.id
        }
    }

    func updateNode(_ node: ProofNode) {
        mutate {
            guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
            var updated = node
            updated.updatedAt = Date()
            project.nodes[index] = updated
        }
    }

    func moveNode(id: UUID, to point: GraphPoint) {
        objectWillChange.send()
        guard let index = project.nodes.firstIndex(where: { $0.id == id }) else { return }
        project.nodes[index].position = GraphPoint(
            x: max(120, min(point.x, 1480)),
            y: max(90, min(point.y, 940))
        )
        project.nodes[index].updatedAt = Date()
        project.updatedAt = Date()
        persist()
    }

    func deleteNode(id: UUID) {
        mutate {
            project.nodes.removeAll { $0.id == id }
            project.edges.removeAll { $0.sourceID == id || $0.targetID == id }

            if selectedNodeID == id {
                selectedNodeID = visibleNodes.first?.id ?? project.nodes.first?.id
            }
        }
    }

    func addEdge(from sourceID: UUID, to targetID: UUID, kind: EdgeKind, label: String = "") {
        guard sourceID != targetID else { return }
        guard project.nodes.contains(where: { $0.id == sourceID }),
              project.nodes.contains(where: { $0.id == targetID }) else { return }

        let exists = project.edges.contains {
            $0.sourceID == sourceID && $0.targetID == targetID && $0.kind == kind
        }
        guard !exists else { return }

        mutate {
            project.edges.append(ProofEdge(sourceID: sourceID, targetID: targetID, kind: kind, label: label))
        }
    }

    func deleteEdge(id: UUID) {
        mutate {
            project.edges.removeAll { $0.id == id }
        }
    }

    func createBranchFromSelected() {
        guard let source = selectedNode else { return }
        let branch = ProofBranch(
            name: "Fork: \(source.title)",
            summary: "Alternative route starting from \(source.title).",
            parentBranchID: source.branchID,
            forkedFromNodeID: source.id,
            status: .active,
            colorName: "pink"
        )

        var forkedNode = source
        forkedNode.id = UUID()
        forkedNode.title = "Fork of \(source.title)"
        forkedNode.branchID = branch.id
        forkedNode.position = GraphPoint(x: source.position.x + 60, y: source.position.y + 260)
        forkedNode.status = .inProgress
        forkedNode.verification = .unchecked
        forkedNode.createdAt = Date()
        forkedNode.updatedAt = Date()
        forkedNode.subgoals.append(
            ProofSubgoal(
                title: "Clarify branch delta",
                detail: "Record exactly what this fork changes compared with the parent proof route.",
                status: .open
            )
        )
        forkedNode.tags = Array(Set(forkedNode.tags + ["fork"]))

        mutate {
            project.branches.append(branch)
            project.nodes.append(forkedNode)
            project.edges.append(
                ProofEdge(sourceID: source.id, targetID: forkedNode.id, kind: .forksFrom, label: "fork")
            )
            selectedBranchID = branch.id
            selectedNodeID = forkedNode.id
        }
    }

    func updateBranch(_ branch: ProofBranch) {
        mutate {
            guard let index = project.branches.firstIndex(where: { $0.id == branch.id }) else { return }
            project.branches[index] = branch
        }
    }

    func markSelectedBranchMerged() {
        guard let selectedBranchID,
              var branch = project.branches.first(where: { $0.id == selectedBranchID }) else { return }
        branch.status = .merged
        updateBranch(branch)
    }

    func syncFormalHoles(for nodeID: UUID) {
        guard var node = project.nodes.first(where: { $0.id == nodeID }) else { return }
        let holes = FormalAnalyzer.holes(in: node.formalCode, dialect: node.formalDialect)
        guard !holes.isEmpty else { return }

        for hole in holes {
            let title = "\(hole.token) at line \(hole.line)"
            let alreadyTracked = node.subgoals.contains { $0.title == title }
            guard !alreadyTracked else { continue }

            node.subgoals.append(
                ProofSubgoal(
                    title: title,
                    detail: hole.context,
                    status: .open
                )
            )
        }

        if node.verification == .unchecked || node.verification == .verified {
            node.verification = .partial
        }

        updateNode(node)
    }

    func resetToSample() {
        mutate {
            project = .sample()
            selectedBranchID = project.branches.first?.id
            selectedNodeID = project.nodes.first?.id
        }
    }

    func importProject(from url: URL) throws {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let imported: ProofProject

        if let internalProject = try? JSONDecoder.proofChain.decode(ProofProject.self, from: data) {
            imported = internalProject
        } else {
            imported = try JSONDecoder.proofChain
                .decode(ProofChainImportDocument.self, from: data)
                .makeProject()
        }

        mutate {
            project = imported
            selectedBranchID = project.branches.first(where: { $0.status == .active })?.id ?? project.branches.first?.id
            selectedNodeID = project.nodes.first(where: { $0.branchID == selectedBranchID })?.id ?? project.nodes.first?.id
        }
    }

    func markdownExport() -> String {
        var lines: [String] = []
        lines.append("# \(project.title)")
        lines.append("")
        lines.append("Updated: \(project.updatedAt.formatted())")
        lines.append("")

        lines.append("## Branches")
        for branch in project.branches {
            lines.append("- \(branch.name) [\(branch.status.title)]")
            if !branch.summary.isEmpty {
                lines.append("  \(branch.summary)")
            }
        }
        lines.append("")

        lines.append("## Open Proof Obligations")
        let obligations = openSubgoals
        if obligations.isEmpty {
            lines.append("All tracked subgoals are marked proven.")
        } else {
            for item in obligations {
                lines.append("- \(item.node.title): \(item.subgoal.title) [\(item.subgoal.status.title)]")
            }
        }
        lines.append("")

        for branch in project.branches {
            lines.append("## \(branch.name)")
            let nodes = project.nodes.filter { $0.branchID == branch.id }
            for node in nodes {
                lines.append("")
                lines.append("### \(node.kind.title): \(node.title)")
                lines.append("Status: \(node.status.title) | Formal: \(node.formalDialect.title) / \(node.verification.title)")

                appendBlock("Statement", node.statement, to: &lines)
                appendBlock("Context", node.context, to: &lines)

                if !node.assumptions.isEmpty {
                    lines.append("Assumptions:")
                    lines.append(contentsOf: node.assumptions.map { "- \($0)" })
                }

                if !node.subgoals.isEmpty {
                    lines.append("Subgoals:")
                    for subgoal in node.subgoals {
                        lines.append("- [\(subgoal.status.title)] \(subgoal.title)")
                        if !subgoal.detail.isEmpty {
                            lines.append("  \(subgoal.detail)")
                        }
                    }
                }

                appendBlock("Proof Sketch", node.proofSketch, to: &lines)

                if !node.formalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("Formal Code (\(node.formalDialect.title)):")
                    lines.append("```")
                    lines.append(node.formalCode)
                    lines.append("```")
                }

                let relations = project.edges.filter { $0.sourceID == node.id || $0.targetID == node.id }
                if !relations.isEmpty {
                    lines.append("Relations:")
                    for edge in relations {
                        let source = title(for: edge.sourceID)
                        let target = title(for: edge.targetID)
                        let label = edge.label.isEmpty ? "" : " (\(edge.label))"
                        lines.append("- \(source) \(edge.kind.title) \(target)\(label)")
                    }
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func appendBlock(_ title: String, _ value: String, to lines: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append("\(title):")
        lines.append(trimmed)
    }

    private func title(for nodeID: UUID) -> String {
        project.nodes.first(where: { $0.id == nodeID })?.title ?? "Unknown node"
    }

    @discardableResult
    private func createMainBranch() -> UUID {
        let branch = ProofBranch(
            name: "Main proof",
            summary: "",
            parentBranchID: nil,
            forkedFromNodeID: nil,
            status: .active,
            colorName: "blue"
        )
        project.branches.append(branch)
        return branch.id
    }

    private func mutate(_ updates: () -> Void) {
        objectWillChange.send()
        updates()
        project.updatedAt = Date()
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.proofChain.encode(project)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to persist ProofChain project: \(error)")
        }
    }

    private static func defaultStorageURL() -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return supportDirectory
            .appendingPathComponent("ProofChain", isDirectory: true)
            .appendingPathComponent("workspace.json")
    }
}

private extension JSONEncoder {
    static var proofChain: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var proofChain: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct ProofChainImportDocument: Decodable {
    var title: String
    var branches: [ImportBranch]?
    var nodes: [ImportNode]
    var edges: [ImportEdge]?

    func makeProject() throws -> ProofProject {
        let branchInputs = branches?.isEmpty == false
            ? branches!
            : [ImportBranch(id: "main", name: "Main proof", summary: "", status: "active", color: "blue", parent: nil, forkedFrom: nil)]

        var branchIDs: [String: UUID] = [:]
        for branch in branchInputs {
            branchIDs[branch.id] = UUID()
        }

        var nodeIDs: [String: UUID] = [:]
        for node in nodes {
            nodeIDs[node.id] = UUID()
        }

        let branches = try branchInputs.map { input in
            guard let id = branchIDs[input.id] else {
                throw ProofChainImportError.unknownBranch(input.id)
            }

            return ProofBranch(
                id: id,
                name: input.name,
                summary: input.summary ?? "",
                parentBranchID: input.parent.flatMap { branchIDs[$0] },
                forkedFromNodeID: input.forkedFrom.flatMap { nodeIDs[$0] },
                status: try input.statusValue(),
                colorName: input.color ?? "blue"
            )
        }

        let nodes = try nodes.enumerated().map { index, input in
            guard let id = nodeIDs[input.id] else {
                throw ProofChainImportError.unknownNode(input.id)
            }

            let branchKey = input.branch ?? branchInputs.first!.id
            guard let branchID = branchIDs[branchKey] else {
                throw ProofChainImportError.unknownBranch(branchKey)
            }

            let position = input.position ?? ImportPoint(
                x: 240 + Double(index % 4) * 270,
                y: 170 + Double(index / 4) * 220
            )

            return ProofNode(
                id: id,
                title: input.title,
                kind: try input.kindValue(),
                statement: input.statement ?? "",
                context: input.context ?? "",
                proofSketch: input.proofSketch ?? "",
                formalCode: input.formalCode ?? "",
                formalDialect: try input.formalDialectValue(),
                status: try input.statusValue(),
                verification: try input.verificationValue(),
                branchID: branchID,
                position: GraphPoint(x: position.x, y: position.y),
                assumptions: input.assumptions ?? [],
                subgoals: try (input.subgoals ?? []).map { try $0.makeSubgoal() },
                symbols: (input.symbols ?? []).map { $0.makeSymbol() },
                tags: input.tags ?? []
            )
        }

        let edges = try (edges ?? []).map { input in
            guard let sourceID = nodeIDs[input.from] else {
                throw ProofChainImportError.unknownNode(input.from)
            }
            guard let targetID = nodeIDs[input.to] else {
                throw ProofChainImportError.unknownNode(input.to)
            }

            return ProofEdge(
                sourceID: sourceID,
                targetID: targetID,
                kind: try input.kindValue(),
                label: input.label ?? ""
            )
        }

        return ProofProject(title: title, branches: branches, nodes: nodes, edges: edges)
    }
}

private struct ImportBranch: Decodable {
    var id: String
    var name: String
    var summary: String?
    var status: String?
    var color: String?
    var parent: String?
    var forkedFrom: String?

    func statusValue() throws -> BranchStatus {
        try decodeEnum(status ?? "active", as: BranchStatus.self)
    }
}

private struct ImportNode: Decodable {
    var id: String
    var branch: String?
    var type: String?
    var title: String
    var statement: String?
    var context: String?
    var proofSketch: String?
    var formalCode: String?
    var formalDialect: String?
    var status: String?
    var verification: String?
    var position: ImportPoint?
    var assumptions: [String]?
    var subgoals: [ImportSubgoal]?
    var symbols: [ImportSymbol]?
    var tags: [String]?

    func kindValue() throws -> NodeKind {
        try decodeEnum(type ?? "claim", as: NodeKind.self)
    }

    func formalDialectValue() throws -> FormalDialect {
        try decodeEnum(formalDialect ?? "latex", as: FormalDialect.self)
    }

    func statusValue() throws -> ProofStatus {
        try decodeEnum(status ?? "open", as: ProofStatus.self)
    }

    func verificationValue() throws -> VerificationStatus {
        try decodeEnum(verification ?? "unchecked", as: VerificationStatus.self)
    }
}

private struct ImportSubgoal: Decodable {
    var title: String
    var detail: String?
    var status: String?

    func makeSubgoal() throws -> ProofSubgoal {
        ProofSubgoal(
            title: title,
            detail: detail ?? "",
            status: try decodeEnum(status ?? "open", as: ProofStatus.self)
        )
    }
}

private struct ImportSymbol: Decodable {
    var symbol: String
    var meaning: String
    var scope: String?

    func makeSymbol() -> SymbolEntry {
        SymbolEntry(symbol: symbol, meaning: meaning, scope: scope ?? "")
    }
}

private struct ImportEdge: Decodable {
    var from: String
    var to: String
    var type: String
    var label: String?

    func kindValue() throws -> EdgeKind {
        try decodeEnum(type, as: EdgeKind.self)
    }
}

private struct ImportPoint: Decodable {
    var x: Double
    var y: Double
}

private enum ProofChainImportError: LocalizedError {
    case unknownBranch(String)
    case unknownNode(String)
    case invalidEnum(value: String, allowed: String)

    var errorDescription: String? {
        switch self {
        case .unknownBranch(let id):
            "Import references unknown branch id '\(id)'."
        case .unknownNode(let id):
            "Import references unknown node id '\(id)'."
        case .invalidEnum(let value, let allowed):
            "Invalid import value '\(value)'. Allowed values: \(allowed)."
        }
    }
}

private func decodeEnum<T>(_ value: String, as type: T.Type) throws -> T where T: CaseIterable & RawRepresentable, T.RawValue == String {
    if let exact = T.allCases.first(where: { $0.rawValue == value }) {
        return exact
    }

    let normalizedValue = normalizeImportValue(value)
    if let normalized = T.allCases.first(where: { normalizeImportValue($0.rawValue) == normalizedValue }) {
        return normalized
    }

    let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
    throw ProofChainImportError.invalidEnum(value: value, allowed: allowed)
}

private func normalizeImportValue(_ value: String) -> String {
    value
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
}
