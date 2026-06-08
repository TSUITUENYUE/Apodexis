import SwiftUI

#if os(macOS)
import AppKit
#endif

struct SidebarView: View {
    @EnvironmentObject private var store: ProofStore

    var body: some View {
        List {
            Section("Projects") {
                if store.projects.isEmpty {
                    Text("No projects")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.projects) { project in
                        ProjectRow(project: project, isSelected: project.id == store.activeProjectID)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.openProject(id: project.id)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.deleteProject(id: project.id)
                                } label: {
                                    Label("Delete Project", systemImage: "trash")
                                }
                            }
                    }
                }
            }

            if store.hasOpenProject {
                Section("Files") {
                    if store.projectFiles.isEmpty {
                        Text("No project files")
                            .foregroundStyle(.secondary)
                    } else {
                        OutlineGroup(store.projectFiles, children: \.children) { file in
                            ProjectFileRow(file: file)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    open(file)
                                }
                        }
                    }
                }

                Section("Explorer") {
                    OutlineGroup(explorerItems, children: \.children) { item in
                        ExplorerRow(item: item, isSelected: isSelected(item))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                select(item)
                            }
                    }
                }

                Section("Open Goals") {
                    let goals = store.openSubgoals.filter { item in
                        guard let selectedBranchID = store.selectedBranchID else { return true }
                        return item.node.branchID == selectedBranchID
                    }

                    if goals.isEmpty {
                        Text("No open goals")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(goals, id: \.subgoal.id) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LaTeXRenderer.render(item.subgoal.title))
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                Text(LaTeXRenderer.render(item.node.title))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.selectNode(id: item.node.id)
                            }
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
    }

    private var explorerItems: [ExplorerItem] {
        let branches = store.project.branches
        let branchIDs = Set(branches.map(\.id))
        let childrenByParent = Dictionary(grouping: branches.filter { branch in
            branch.parentBranchID != nil && branch.parentBranchID.map(branchIDs.contains) == true
        }, by: { $0.parentBranchID! })

        func branchItem(_ branch: ProofBranch) -> ExplorerItem {
            let nodeItems = store.project.nodes
                .filter { $0.branchID == branch.id }
                .sorted { lhs, rhs in
                    if lhs.position.y != rhs.position.y {
                        return lhs.position.y < rhs.position.y
                    }
                    return lhs.title < rhs.title
                }
                .map { node in
                    ExplorerItem(
                        id: "node-\(node.id.uuidString)",
                        title: node.title,
                        subtitle: "\(node.kind.title) · \(node.status.title)",
                        systemImage: node.kind.systemImage,
                        tint: node.kind.tint,
                        branchID: branch.id,
                        nodeID: node.id,
                        children: nil
                    )
                }

            let childBranchItems = (childrenByParent[branch.id] ?? [])
                .sorted { $0.name < $1.name }
                .map(branchItem)

            let children = nodeItems + childBranchItems
            return ExplorerItem(
                id: "branch-\(branch.id.uuidString)",
                title: branch.name,
                subtitle: branch.status.title,
                systemImage: branch.parentBranchID == nil ? "point.topleft.down.curvedto.point.bottomright.up" : "arrow.triangle.branch",
                tint: branchColor(branch.colorName),
                branchID: branch.id,
                nodeID: nil,
                children: children.isEmpty ? nil : children
            )
        }

        let rootBranches = branches
            .filter { branch in
                branch.parentBranchID == nil || branch.parentBranchID.map(branchIDs.contains) == false
            }
            .sorted { lhs, rhs in
                if lhs.parentBranchID == nil && rhs.parentBranchID != nil { return true }
                if lhs.parentBranchID != nil && rhs.parentBranchID == nil { return false }
                return lhs.name < rhs.name
            }

        return rootBranches.map(branchItem)
    }

    private func isSelected(_ item: ExplorerItem) -> Bool {
        if let nodeID = item.nodeID {
            return nodeID == store.selectedNodeID
        }
        if let branchID = item.branchID {
            return branchID == store.selectedBranchID
        }
        return false
    }

    private func select(_ item: ExplorerItem) {
        if let nodeID = item.nodeID {
            store.selectNode(id: nodeID)
        } else if let branchID = item.branchID {
            store.selectBranch(id: branchID)
        }
    }

    private func open(_ file: ProjectFileItem) {
        guard !file.isDirectory else { return }
        #if os(macOS)
        NSWorkspace.shared.open(file.url)
        #endif
    }

    private func branchColor(_ name: String) -> Color {
        switch name {
        case "pink": .pink
        case "green": .green
        case "orange": .orange
        case "purple": .purple
        case "red": .red
        default: .blue
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "folder.fill" : "folder")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(LaTeXRenderer.render(project.title))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(project.branchCount) branches · \(project.nodeCount) nodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .font(.caption.weight(.bold))
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ExplorerRow: View {
    let item: ExplorerItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(LaTeXRenderer.render(item.title))
                    .font(.subheadline.weight(item.nodeID == nil ? .semibold : .medium))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ProjectFileRow: View {
    let file: ProjectFileItem

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.subheadline.weight(file.isDirectory ? .semibold : .regular))
                    .lineLimit(1)
                if !file.isDirectory {
                    Text(file.relativePath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var systemImage: String {
        if file.isDirectory {
            return "folder"
        }

        switch file.url.pathExtension.lowercased() {
        case "lean", "v", "thy", "coq", "agda":
            return "curlybraces"
        case "md", "txt", "tex":
            return "doc.text"
        case "json", "toml", "yaml", "yml":
            return "slider.horizontal.3"
        default:
            return "doc"
        }
    }
}

private struct ExplorerItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let branchID: UUID?
    let nodeID: UUID?
    let children: [ExplorerItem]?
}
