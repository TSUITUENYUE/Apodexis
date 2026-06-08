import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: ProofStore

    var body: some View {
        List {
            Section("Branches") {
                ForEach(store.project.branches) { branch in
                    BranchRow(branch: branch, isSelected: branch.id == store.selectedBranchID)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.selectedBranchID = branch.id
                            store.selectedNodeID = store.project.nodes.first(where: { $0.branchID == branch.id })?.id
                        }
                }
            }

            Section("Nodes") {
                ForEach(store.visibleNodes) { node in
                    NodeListRow(node: node, isSelected: node.id == store.selectedNodeID)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.selectedNodeID = node.id
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
                            Text(item.subgoal.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(item.node.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.selectedNodeID = item.node.id
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
    }
}

private struct BranchRow: View {
    let branch: ProofBranch
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(branch.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(branch.status.title)
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

    private var color: Color {
        switch branch.colorName {
        case "pink": .pink
        case "green": .green
        case "orange": .orange
        case "purple": .purple
        default: .blue
        }
    }
}

private struct NodeListRow: View {
    let node: ProofNode
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.kind.systemImage)
                .foregroundStyle(node.kind.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(node.kind.title)
                    Text("·")
                    Text(node.status.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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

