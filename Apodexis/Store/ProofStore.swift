import Combine
import Foundation
import SwiftUI

@MainActor
final class ProofStore: ObservableObject {
    @Published var project: ProofProject
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var projectFiles: [ProjectFileItem] = []
    @Published var activeProjectID: UUID?
    @Published var selectedBranchID: UUID?
    @Published var selectedNodeID: UUID?
    @Published var layoutRevision = 0

    private var projectIndex = ProjectIndex()
    private let appDirectory: URL
    private var activeProjectDirectoryURL: URL?
    private var activeGraphFileName = ProofStore.defaultGraphFileName

    private static let defaultGraphFileName = "apodexis.json"

    init(appDirectory: URL = ProofStore.defaultAppDirectory()) {
        self.appDirectory = appDirectory
        project = .blank(title: "No Project")

        loadProjectIndex()
        migrateLegacyWorkspaceIfNeeded()

        let initialProjectID = projectIndex.lastOpenProjectID.flatMap { id in
            projects.contains(where: { $0.id == id }) ? id : nil
        } ?? projects.first?.id

        if let initialProjectID {
            openProject(id: initialProjectID)
        }
    }

    var hasOpenProject: Bool {
        activeProjectID != nil
    }

    var selectedBranch: ProofBranch? {
        guard hasOpenProject else { return nil }
        guard let selectedBranchID else { return nil }
        return project.branches.first { $0.id == selectedBranchID }
    }

    var selectedNode: ProofNode? {
        guard hasOpenProject else { return nil }
        guard let selectedNodeID else { return nil }
        return project.nodes.first { $0.id == selectedNodeID }
    }

    var visibleNodes: [ProofNode] {
        guard hasOpenProject else { return [] }
        guard let selectedBranchID else { return project.nodes }
        return project.nodes.filter { $0.branchID == selectedBranchID }
    }

    var openSubgoals: [(node: ProofNode, subgoal: ProofSubgoal)] {
        guard hasOpenProject else { return [] }
        return project.nodes.flatMap { node in
            node.subgoals
                .filter { $0.status != .proven }
                .map { (node: node, subgoal: $0) }
        }
    }

    func createProject(title: String = "Untitled Proof Project") {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var newProject = ProofProject.blank(title: trimmedTitle.isEmpty ? "Untitled Proof Project" : trimmedTitle)
        newProject.updatedAt = Date()
        let directoryURL = managedProjectDirectoryURL(for: newProject.id)
        activateNewProject(newProject, directoryURL: directoryURL, graphFileName: Self.defaultGraphFileName, isManaged: true)
    }

    func openProject(id: UUID) {
        guard let summary = projects.first(where: { $0.id == id }) else { return }
        do {
            let graphURL = projectGraphFileURL(for: summary)
            var loadedProject = try loadProjectDocument(from: graphURL)
            loadedProject.id = summary.id
            project = loadedProject
            activeProjectID = summary.id
            activeProjectDirectoryURL = projectDirectoryURL(for: summary)
            activeGraphFileName = summary.graphFileName
            selectInitialNode()
            refreshProjectFiles()
            projectIndex.lastOpenProjectID = summary.id
            persistIndex()
        } catch {
            assertionFailure("Failed to open Apodexis project: \(error)")
        }
    }

    func closeProject() {
        activeProjectID = nil
        selectedBranchID = nil
        selectedNodeID = nil
        activeProjectDirectoryURL = nil
        activeGraphFileName = Self.defaultGraphFileName
        projectFiles = []
        projectIndex.lastOpenProjectID = nil
        persistIndex()
    }

    func deleteProject(id: UUID) {
        guard let summary = projects.first(where: { $0.id == id }) else { return }
        if summary.isManaged {
            try? FileManager.default.removeItem(at: projectDirectoryURL(for: summary))
        }
        projects.removeAll { $0.id == id }
        projectIndex.projects = projects

        if activeProjectID == id {
            closeProject()
        } else {
            persistIndex()
        }
    }

    func openProjectDirectory(from url: URL) throws {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let directoryURL = url.standardizedFileURL
        var graphURL = try findGraphFile(in: directoryURL)
        var loadedProject: ProofProject

        if let graphURL {
            loadedProject = try loadProjectDocument(from: graphURL)
        } else {
            loadedProject = .blank(title: directoryURL.lastPathComponent)
            loadedProject.updatedAt = Date()
            graphURL = directoryURL.appendingPathComponent(Self.defaultGraphFileName)
        }

        if let existing = projects.first(where: { $0.directoryPath == directoryURL.path }) {
            loadedProject.id = existing.id
        } else if projects.contains(where: { $0.id == loadedProject.id }) {
            loadedProject.id = UUID()
        }

        activateNewProject(
            loadedProject,
            directoryURL: directoryURL,
            graphFileName: graphURL?.lastPathComponent ?? Self.defaultGraphFileName,
            isManaged: false
        )
    }

    func selectBranch(id: UUID) {
        guard hasOpenProject else { return }
        selectedBranchID = id
        selectedNodeID = nil
    }

    func selectNode(id: UUID) {
        guard hasOpenProject, let node = project.nodes.first(where: { $0.id == id }) else { return }
        selectedBranchID = node.branchID
        selectedNodeID = node.id
    }

    func addNode(kind: NodeKind = .claim) {
        guard hasOpenProject else { return }
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
        guard hasOpenProject else { return }
        mutate {
            guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
            var updated = node
            updated.updatedAt = Date()
            project.nodes[index] = updated
        }
    }

    func moveNode(id: UUID, to point: GraphPoint) {
        guard hasOpenProject else { return }
        objectWillChange.send()
        guard let index = project.nodes.firstIndex(where: { $0.id == id }) else { return }
        project.nodes[index].position = GraphPoint(
            x: max(120, point.x),
            y: max(90, point.y)
        )
        project.nodes[index].updatedAt = Date()
        project.updatedAt = Date()
        persist()
    }

    func deleteNode(id: UUID) {
        guard hasOpenProject else { return }
        mutate {
            project.nodes.removeAll { $0.id == id }
            project.edges.removeAll { $0.sourceID == id || $0.targetID == id }

            if selectedNodeID == id {
                selectedNodeID = visibleNodes.first?.id ?? project.nodes.first?.id
            }
        }
    }

    func addEdge(from sourceID: UUID, to targetID: UUID, kind: EdgeKind, label: String = "") {
        guard hasOpenProject else { return }
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
        guard hasOpenProject else { return }
        mutate {
            project.edges.removeAll { $0.id == id }
        }
    }

    func createBranchFromSelected() {
        guard hasOpenProject else { return }
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
        guard hasOpenProject else { return }
        mutate {
            guard let index = project.branches.firstIndex(where: { $0.id == branch.id }) else { return }
            project.branches[index] = branch
        }
    }

    func markSelectedBranchMerged() {
        guard hasOpenProject else { return }
        guard let selectedBranchID,
              var branch = project.branches.first(where: { $0.id == selectedBranchID }) else { return }
        branch.status = .merged
        updateBranch(branch)
    }

    func syncFormalHoles(for nodeID: UUID) {
        guard hasOpenProject else { return }
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

        if node.verification == .unchecked || node.verification == .checked || node.verification == .verified {
            node.verification = .partial
        }

        updateNode(node)
    }

    func resetToSample() {
        guard hasOpenProject else { return }
        mutate {
            project = .sample()
            project.id = activeProjectID ?? project.id
            selectedBranchID = project.branches.first?.id
            selectedNodeID = project.nodes.first?.id
        }
    }

    func autoLayoutSelectedBranch() {
        guard hasOpenProject, let selectedBranchID else { return }
        objectWillChange.send()
        applyAutoLayout(to: selectedBranchID)
    }

    func autoLayoutAllBranches() {
        guard hasOpenProject else { return }
        objectWillChange.send()
        for branch in project.branches {
            applyAutoLayout(to: branch.id, persistImmediately: false)
        }
        project.updatedAt = Date()
        layoutRevision += 1
        persist()
    }

    func importProject(from url: URL) throws {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var imported = try loadProjectDocument(from: url)

        if projects.contains(where: { $0.id == imported.id }) {
            imported.id = UUID()
        }

        activateNewProject(
            imported,
            directoryURL: managedProjectDirectoryURL(for: imported.id),
            graphFileName: Self.defaultGraphFileName,
            isManaged: true
        )
    }

    private func applyAutoLayout(to branchID: UUID, persistImmediately: Bool = true) {
        let branchNodes = project.nodes.filter { $0.branchID == branchID }
        guard branchNodes.count > 1 else { return }

        let nodeIDs = Set(branchNodes.map(\.id))
        let branchEdges = project.edges.filter {
            nodeIDs.contains($0.sourceID) && nodeIDs.contains($0.targetID)
        }
        let positions = GraphLayoutEngine.layout(nodes: branchNodes, edges: branchEdges)

        for index in project.nodes.indices {
            guard let position = positions[project.nodes[index].id] else { continue }
            project.nodes[index].position = position
            project.nodes[index].updatedAt = Date()
        }

        if persistImmediately {
            project.updatedAt = Date()
            layoutRevision += 1
            persist()
        }
    }

    func markdownExport() -> String {
        guard hasOpenProject else { return "" }
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
                if let sourceFile = node.sourceFile, !sourceFile.isEmpty {
                    let line = node.sourceLine.map { ":\($0)" } ?? ""
                    lines.append("Source: \(sourceFile)\(line)")
                }

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
        guard hasOpenProject else { return }
        objectWillChange.send()
        updates()
        project.updatedAt = Date()
        persist()
    }

    private func activateNewProject(
        _ newProject: ProofProject,
        directoryURL: URL,
        graphFileName: String,
        isManaged: Bool
    ) {
        project = newProject
        activeProjectID = newProject.id
        activeProjectDirectoryURL = directoryURL
        activeGraphFileName = graphFileName
        selectInitialNode()
        projectIndex.lastOpenProjectID = newProject.id
        upsertSummary(for: newProject, directoryURL: directoryURL, graphFileName: graphFileName, isManaged: isManaged)
        refreshProjectFiles()
        persist()
    }

    private func selectInitialNode() {
        selectedBranchID = project.branches.first(where: { $0.status == .active })?.id ?? project.branches.first?.id
        selectedNodeID = project.nodes.first(where: { $0.branchID == selectedBranchID })?.id ?? project.nodes.first?.id
    }

    private func persist() {
        do {
            guard let activeProjectID else {
                persistIndex()
                return
            }
            guard let activeProjectDirectoryURL else {
                assertionFailure("No active project directory for project \(activeProjectID).")
                persistIndex()
                return
            }

            try FileManager.default.createDirectory(
                at: activeProjectDirectoryURL,
                withIntermediateDirectories: true
            )

            project.id = activeProjectID
            upsertSummary(
                for: project,
                directoryURL: activeProjectDirectoryURL,
                graphFileName: activeGraphFileName,
                isManaged: activeProjectDirectoryURL.path.hasPrefix(projectsDirectory.path)
            )
            let data = try JSONEncoder.proofChain.encode(project)
            try data.write(to: activeProjectDirectoryURL.appendingPathComponent(activeGraphFileName), options: [.atomic])
            refreshProjectFiles()
            persistIndex()
        } catch {
            assertionFailure("Failed to persist Apodexis project: \(error)")
        }
    }

    private func loadProjectIndex() {
        do {
            try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: projectIndexURL),
               let decoded = try? JSONDecoder.proofChain.decode(ProjectIndex.self, from: data) {
                projectIndex = decoded
                projects = decoded.projects.sorted { $0.updatedAt > $1.updatedAt }
            }
        } catch {
            assertionFailure("Failed to load Apodexis project index: \(error)")
        }
    }

    private func persistIndex() {
        do {
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            projectIndex.projects = projects.sorted { $0.updatedAt > $1.updatedAt }
            projects = projectIndex.projects
            let data = try JSONEncoder.proofChain.encode(projectIndex)
            try data.write(to: projectIndexURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to persist Apodexis project index: \(error)")
        }
    }

    private func migrateLegacyWorkspaceIfNeeded() {
        guard projects.isEmpty else { return }
        guard let data = try? Data(contentsOf: legacyWorkspaceURL),
              var legacyProject = try? JSONDecoder.proofChain.decode(ProofProject.self, from: data) else { return }

        legacyProject.updatedAt = Date()
        let directoryURL = managedProjectDirectoryURL(for: legacyProject.id)
        upsertSummary(
            for: legacyProject,
            directoryURL: directoryURL,
            graphFileName: Self.defaultGraphFileName,
            isManaged: true
        )
        projectIndex.lastOpenProjectID = legacyProject.id

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder.proofChain.encode(legacyProject)
            try data.write(to: directoryURL.appendingPathComponent(Self.defaultGraphFileName), options: [.atomic])
            persistIndex()
        } catch {
            assertionFailure("Failed to migrate legacy Apodexis workspace: \(error)")
        }
    }

    private func upsertSummary(
        for project: ProofProject,
        directoryURL: URL,
        graphFileName: String,
        isManaged: Bool
    ) {
        let summary = ProjectSummary(
            id: project.id,
            title: project.title,
            branchCount: project.branches.count,
            nodeCount: project.nodes.count,
            updatedAt: project.updatedAt,
            directoryPath: directoryURL.standardizedFileURL.path,
            graphFileName: graphFileName,
            storageFileName: nil,
            isManaged: isManaged
        )

        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = summary
        } else {
            projects.append(summary)
        }

        projects.sort { $0.updatedAt > $1.updatedAt }
        projectIndex.projects = projects
    }

    private func loadProjectDocument(from url: URL) throws -> ProofProject {
        let data = try Data(contentsOf: url)

        if let internalProject = try? JSONDecoder.proofChain.decode(ProofProject.self, from: data) {
            return internalProject
        }

        return try JSONDecoder.proofChain
            .decode(ApodexisImportDocument.self, from: data)
            .makeProject()
    }

    private func findGraphFile(in directoryURL: URL) throws -> URL? {
        let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw ApodexisImportError.notDirectory(directoryURL.path)
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let jsonFiles = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let preferredNames = [
            Self.defaultGraphFileName,
            "proof-chain.json",
            "project.json",
            "workspace.json"
        ]

        for name in preferredNames {
            guard let candidate = jsonFiles.first(where: { $0.lastPathComponent == name }) else { continue }
            if (try? loadProjectDocument(from: candidate)) != nil {
                return candidate
            }
        }

        for candidate in jsonFiles {
            if (try? loadProjectDocument(from: candidate)) != nil {
                return candidate
            }
        }

        return nil
    }

    private func refreshProjectFiles() {
        guard let activeProjectDirectoryURL else {
            projectFiles = []
            return
        }

        projectFiles = fileItems(in: activeProjectDirectoryURL, root: activeProjectDirectoryURL, depth: 0)
    }

    private func fileItems(in directoryURL: URL, root: URL, depth: Int) -> [ProjectFileItem] {
        guard depth < 5 else { return [] }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .sorted { lhs, rhs in
                let lhsDirectory = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rhsDirectory = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if lhsDirectory != rhsDirectory {
                    return lhsDirectory
                }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .compactMap { url -> ProjectFileItem? in
                let name = url.lastPathComponent
                guard !ignoredProjectFileNames.contains(name) else { return nil }

                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let relativePath = relativePath(for: url, root: root)

                if isDirectory {
                    let children = fileItems(in: url, root: root, depth: depth + 1)
                    guard !children.isEmpty else { return nil }
                    return ProjectFileItem(
                        id: relativePath,
                        name: name,
                        relativePath: relativePath,
                        url: url,
                        isDirectory: true,
                        children: children
                    )
                }

                guard shouldDisplayProjectFile(url) else { return nil }
                return ProjectFileItem(
                    id: relativePath,
                    name: name,
                    relativePath: relativePath,
                    url: url,
                    isDirectory: false,
                    children: nil
                )
            }
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private var ignoredProjectFileNames: Set<String> {
        [".git", ".build", ".lake", "build", "DerivedData", ".DS_Store"]
    }

    private func shouldDisplayProjectFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let allowedExtensions: Set<String> = [
            "json", "lean", "md", "txt", "tex", "toml", "yaml", "yml",
            "py", "jl", "r", "v", "thy", "coq", "agda", "lagda", "hs"
        ]

        return allowedExtensions.contains(ext) || name == "lakefile.lean" || name == "lean-toolchain"
    }

    func projectURL(for relativePath: String) -> URL? {
        guard let activeProjectDirectoryURL else { return nil }
        if relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: relativePath)
        }
        return activeProjectDirectoryURL.appendingPathComponent(relativePath)
    }

    func sourceURL(for node: ProofNode) -> URL? {
        guard let sourceFile = node.sourceFile?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceFile.isEmpty else { return nil }
        return projectURL(for: sourceFile)
    }

    private var projectIndexURL: URL {
        appDirectory.appendingPathComponent("project-index.json")
    }

    private var projectsDirectory: URL {
        appDirectory.appendingPathComponent("Projects", isDirectory: true)
    }

    private var legacyWorkspaceURL: URL {
        appDirectory.appendingPathComponent("workspace.json")
    }

    private func projectDirectoryURL(for summary: ProjectSummary) -> URL {
        if let directoryPath = summary.directoryPath {
            return URL(fileURLWithPath: directoryPath, isDirectory: true)
        }
        return managedProjectDirectoryURL(for: summary.id)
    }

    private func projectGraphFileURL(for summary: ProjectSummary) -> URL {
        if summary.directoryPath == nil, let storageFileName = summary.storageFileName {
            return projectsDirectory.appendingPathComponent(storageFileName)
        }
        return projectDirectoryURL(for: summary).appendingPathComponent(summary.graphFileName)
    }

    private func managedProjectDirectoryURL(for id: UUID) -> URL {
        projectsDirectory.appendingPathComponent("\(id.uuidString).apodexis", isDirectory: true)
    }

    nonisolated private static func defaultAppDirectory() -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return supportDirectory.appendingPathComponent("Apodexis", isDirectory: true)
    }
}

private struct ProjectIndex: Codable {
    var projects: [ProjectSummary] = []
    var lastOpenProjectID: UUID?
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

private struct ApodexisImportDocument: Decodable {
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
                throw ApodexisImportError.unknownBranch(input.id)
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
                throw ApodexisImportError.unknownNode(input.id)
            }

            let branchKey = input.branch ?? branchInputs.first!.id
            guard let branchID = branchIDs[branchKey] else {
                throw ApodexisImportError.unknownBranch(branchKey)
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
                tags: input.tags ?? [],
                sourceFile: input.sourceFile,
                sourceLine: input.sourceLine
            )
        }

        let edges = try (edges ?? []).map { input in
            guard let sourceID = nodeIDs[input.from] else {
                throw ApodexisImportError.unknownNode(input.from)
            }
            guard let targetID = nodeIDs[input.to] else {
                throw ApodexisImportError.unknownNode(input.to)
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
    var sourceFile: String?
    var sourceLine: Int?

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

private enum ApodexisImportError: LocalizedError {
    case unknownBranch(String)
    case unknownNode(String)
    case invalidEnum(value: String, allowed: String)
    case notDirectory(String)

    var errorDescription: String? {
        switch self {
        case .unknownBranch(let id):
            "Import references unknown branch id '\(id)'."
        case .unknownNode(let id):
            "Import references unknown node id '\(id)'."
        case .invalidEnum(let value, let allowed):
            "Invalid import value '\(value)'. Allowed values: \(allowed)."
        case .notDirectory(let path):
            "'\(path)' is not a project folder."
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
    throw ApodexisImportError.invalidEnum(value: value, allowed: allowed)
}

private func normalizeImportValue(_ value: String) -> String {
    value
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
}

private enum GraphLayoutEngine {
    static func layout(nodes: [ProofNode], edges: [ProofEdge]) -> [UUID: GraphPoint] {
        let nodeIDs = Set(nodes.map(\.id))
        let graphEdges = edges.filter {
            nodeIDs.contains($0.sourceID) && nodeIDs.contains($0.targetID) && $0.sourceID != $0.targetID
        }

        guard !nodes.isEmpty else { return [:] }

        let outgoing = Dictionary(grouping: graphEdges, by: \.sourceID)
        let incoming = Dictionary(grouping: graphEdges, by: \.targetID)
        let layers = computeLayers(nodes: nodes, outgoing: outgoing, incoming: incoming)
        let order = computeOrder(nodes: nodes, layers: layers, incoming: incoming, outgoing: outgoing)

        var positions: [UUID: GraphPoint] = [:]
        let grouped = Dictionary(grouping: nodes, by: { layers[$0.id] ?? 0 })
        let sortedLayers = grouped.keys.sorted()

        for layer in sortedLayers {
            let layerNodes = (grouped[layer] ?? []).sorted {
                (order[$0.id] ?? 0, $0.title) < (order[$1.id] ?? 0, $1.title)
            }
            let startY = 150.0

            for (index, node) in layerNodes.enumerated() {
                positions[node.id] = GraphPoint(
                    x: 240.0 + Double(layer) * 330.0,
                    y: startY + Double(index) * 190.0
                )
            }
        }

        return positions
    }

    private static func computeLayers(
        nodes: [ProofNode],
        outgoing: [UUID: [ProofEdge]],
        incoming: [UUID: [ProofEdge]]
    ) -> [UUID: Int] {
        var indegree = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, incoming[$0.id]?.count ?? 0) })
        var layers = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        var queue = nodes
            .filter { indegree[$0.id] == 0 }
            .sorted(by: stableNodeOrder)
            .map(\.id)
        var visited: Set<UUID> = []

        if queue.isEmpty {
            queue = nodes.sorted(by: stableNodeOrder).map(\.id)
        }

        while let current = queue.first {
            queue.removeFirst()
            guard !visited.contains(current) else { continue }
            visited.insert(current)

            for edge in outgoing[current] ?? [] {
                layers[edge.targetID] = max(layers[edge.targetID] ?? 0, (layers[current] ?? 0) + 1)
                indegree[edge.targetID, default: 0] -= 1
                if indegree[edge.targetID, default: 0] <= 0 {
                    queue.append(edge.targetID)
                }
            }

            queue.sort { lhs, rhs in
                ((layers[lhs] ?? 0), title(for: lhs, in: nodes)) < ((layers[rhs] ?? 0), title(for: rhs, in: nodes))
            }
        }

        for node in nodes where !visited.contains(node.id) {
            let predecessorLayer = (incoming[node.id] ?? [])
                .map { layers[$0.sourceID] ?? 0 }
                .max() ?? 0
            layers[node.id] = max(layers[node.id] ?? 0, predecessorLayer + 1)
        }

        return layers
    }

    private static func computeOrder(
        nodes: [ProofNode],
        layers: [UUID: Int],
        incoming: [UUID: [ProofEdge]],
        outgoing: [UUID: [ProofEdge]]
    ) -> [UUID: Int] {
        var grouped = Dictionary(grouping: nodes, by: { layers[$0.id] ?? 0 })
        var order: [UUID: Int] = [:]

        for layer in grouped.keys {
            grouped[layer]?.sort(by: stableNodeOrder)
            for (index, node) in (grouped[layer] ?? []).enumerated() {
                order[node.id] = index
            }
        }

        let sortedLayers = grouped.keys.sorted()
        guard sortedLayers.count > 1 else { return order }

        for _ in 0..<4 {
            for layer in sortedLayers.dropFirst() {
                grouped[layer]?.sort {
                    barycenter(for: $0.id, neighbors: incoming[$0.id]?.map(\.sourceID) ?? [], order: order) <
                        barycenter(for: $1.id, neighbors: incoming[$1.id]?.map(\.sourceID) ?? [], order: order)
                }
                refreshOrder(from: grouped[layer] ?? [], into: &order)
            }

            for layer in sortedLayers.dropLast().reversed() {
                grouped[layer]?.sort {
                    barycenter(for: $0.id, neighbors: outgoing[$0.id]?.map(\.targetID) ?? [], order: order) <
                        barycenter(for: $1.id, neighbors: outgoing[$1.id]?.map(\.targetID) ?? [], order: order)
                }
                refreshOrder(from: grouped[layer] ?? [], into: &order)
            }
        }

        return order
    }

    private static func barycenter(for nodeID: UUID, neighbors: [UUID], order: [UUID: Int]) -> Double {
        let values = neighbors.compactMap { order[$0] }
        guard !values.isEmpty else { return Double(order[nodeID] ?? 0) }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    private static func refreshOrder(from nodes: [ProofNode], into order: inout [UUID: Int]) {
        for (index, node) in nodes.enumerated() {
            order[node.id] = index
        }
    }

    private static func stableNodeOrder(_ lhs: ProofNode, _ rhs: ProofNode) -> Bool {
        if lhs.position.y != rhs.position.y {
            return lhs.position.y < rhs.position.y
        }
        if lhs.position.x != rhs.position.x {
            return lhs.position.x < rhs.position.x
        }
        return lhs.title < rhs.title
    }

    private static func title(for id: UUID, in nodes: [ProofNode]) -> String {
        nodes.first(where: { $0.id == id })?.title ?? ""
    }
}
