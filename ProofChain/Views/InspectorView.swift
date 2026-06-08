import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var store: ProofStore

    var body: some View {
        Group {
            if let node = selectedNodeBinding {
                NodeInspectorView(node: node)
            } else if let branch = selectedBranchBinding {
                BranchInspectorView(branch: branch)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right")
            }
        }
        .frame(minWidth: 300)
    }

    private var selectedNodeBinding: Binding<ProofNode>? {
        guard let id = store.selectedNodeID,
              store.project.nodes.contains(where: { $0.id == id }) else { return nil }

        return Binding(
            get: {
                store.project.nodes.first(where: { $0.id == id })!
            },
            set: { updated in
                store.updateNode(updated)
            }
        )
    }

    private var selectedBranchBinding: Binding<ProofBranch>? {
        guard let id = store.selectedBranchID,
              store.project.branches.contains(where: { $0.id == id }) else { return nil }

        return Binding(
            get: {
                store.project.branches.first(where: { $0.id == id })!
            },
            set: { updated in
                store.updateBranch(updated)
            }
        )
    }
}

private struct NodeInspectorView: View {
    @EnvironmentObject private var store: ProofStore
    @Binding var node: ProofNode

    @State private var edgeTargetID: UUID?
    @State private var edgeKind: EdgeKind = .uses
    @State private var edgeLabel = ""

    var body: some View {
        Form {
            Section("Node") {
                TextField("Title", text: $node.title)

                Picker("Type", selection: $node.kind) {
                    ForEach(NodeKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.systemImage)
                            .tag(kind)
                    }
                }

                Picker("Status", selection: $node.status) {
                    ForEach(ProofStatus.allCases) { status in
                        Text(status.title).tag(status)
                    }
                }

                Picker("Formal State", selection: $node.verification) {
                    ForEach(VerificationStatus.allCases) { status in
                        Text(status.title).tag(status)
                    }
                }
            }

            Section("Statement") {
                MultilineField(text: $node.statement, minHeight: 92)
            }

            Section("Context") {
                MultilineField(text: $node.context, minHeight: 82)
                EditableStringList(title: "Assumptions", items: $node.assumptions, placeholder: "Assumption")
            }

            Section("Proof Sketch") {
                MultilineField(text: $node.proofSketch, minHeight: 110)
            }

            Section("Formal Block") {
                Picker("Language", selection: $node.formalDialect) {
                    ForEach(FormalDialect.allCases) { dialect in
                        Text(dialect.title).tag(dialect)
                    }
                }

                MultilineField(text: $node.formalCode, minHeight: 145, monospaced: true)

                let holes = FormalAnalyzer.holes(in: node.formalCode, dialect: node.formalDialect)
                if !holes.isEmpty {
                    ForEach(holes) { hole in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(hole.token), line \(hole.line)")
                                    .font(.caption.weight(.semibold))
                                Text(hole.context)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }

                    Button {
                        store.syncFormalHoles(for: node.id)
                    } label: {
                        Label("Create Subgoals From Holes", systemImage: "target")
                    }
                }
            }

            Section("Subgoals") {
                if node.subgoals.isEmpty {
                    Text("No subgoals")
                        .foregroundStyle(.secondary)
                }

                ForEach($node.subgoals) { $subgoal in
                    SubgoalEditor(subgoal: $subgoal) {
                        node.subgoals.removeAll { $0.id == subgoal.id }
                    }
                }

                Button {
                    node.subgoals.append(ProofSubgoal(title: "New subgoal", detail: ""))
                } label: {
                    Label("Add Subgoal", systemImage: "plus")
                }
            }

            Section("Symbols") {
                if node.symbols.isEmpty {
                    Text("No symbols")
                        .foregroundStyle(.secondary)
                }

                ForEach($node.symbols) { $symbol in
                    SymbolEditor(symbol: $symbol) {
                        node.symbols.removeAll { $0.id == symbol.id }
                    }
                }

                Button {
                    node.symbols.append(SymbolEntry(symbol: "", meaning: "", scope: ""))
                } label: {
                    Label("Add Symbol", systemImage: "plus")
                }
            }

            Section("Relations") {
                RelationCreator(
                    node: node,
                    edgeTargetID: $edgeTargetID,
                    edgeKind: $edgeKind,
                    edgeLabel: $edgeLabel
                )

                let relations = store.project.edges.filter { $0.sourceID == node.id || $0.targetID == node.id }
                if relations.isEmpty {
                    Text("No relations")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(relations) { edge in
                        RelationRow(edge: edge, currentNodeID: node.id)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    store.deleteNode(id: node.id)
                } label: {
                    Label("Delete Node", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: updateDefaultTarget)
        .onChange(of: node.id) {
            updateDefaultTarget()
        }
    }

    private func updateDefaultTarget() {
        edgeTargetID = store.project.nodes.first(where: { $0.id != node.id })?.id
    }
}

private struct BranchInspectorView: View {
    @EnvironmentObject private var store: ProofStore
    @Binding var branch: ProofBranch

    var body: some View {
        Form {
            Section("Branch") {
                TextField("Name", text: $branch.name)
                Picker("Status", selection: $branch.status) {
                    ForEach(BranchStatus.allCases) { status in
                        Text(status.title).tag(status)
                    }
                }
                MultilineField(text: $branch.summary, minHeight: 110)
            }

            Section("Fork") {
                if let parentID = branch.parentBranchID,
                   let parent = store.project.branches.first(where: { $0.id == parentID }) {
                    LabeledContent("Parent", value: parent.name)
                }

                if let nodeID = branch.forkedFromNodeID,
                   let node = store.project.nodes.first(where: { $0.id == nodeID }) {
                    LabeledContent("Forked From", value: node.title)
                }

                Button {
                    store.markSelectedBranchMerged()
                } label: {
                    Label("Mark Merged", systemImage: "arrow.triangle.merge")
                }
                .disabled(branch.status == .merged)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RelationCreator: View {
    @EnvironmentObject private var store: ProofStore
    let node: ProofNode
    @Binding var edgeTargetID: UUID?
    @Binding var edgeKind: EdgeKind
    @Binding var edgeLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Target", selection: targetSelection) {
                ForEach(store.project.nodes.filter { $0.id != node.id }) { target in
                    Text(target.title).tag(Optional(target.id))
                }
            }

            Picker("Relation", selection: $edgeKind) {
                ForEach(EdgeKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }

            TextField("Optional label", text: $edgeLabel)

            Button {
                guard let edgeTargetID else { return }
                store.addEdge(from: node.id, to: edgeTargetID, kind: edgeKind, label: edgeLabel)
                edgeLabel = ""
            } label: {
                Label("Add Relation", systemImage: "arrow.right")
            }
            .disabled(edgeTargetID == nil)
        }
    }

    private var targetSelection: Binding<UUID?> {
        Binding(
            get: { edgeTargetID },
            set: { edgeTargetID = $0 }
        )
    }
}

private struct RelationRow: View {
    @EnvironmentObject private var store: ProofStore
    let edge: ProofEdge
    let currentNodeID: UUID

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: edge.sourceID == currentNodeID ? "arrow.up.right" : "arrow.down.left")
                .foregroundStyle(edge.kind.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(relationTitle)
                    .font(.caption.weight(.semibold))
                if !edge.label.isEmpty {
                    Text(edge.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(role: .destructive) {
                store.deleteEdge(id: edge.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private var relationTitle: String {
        let source = store.project.nodes.first(where: { $0.id == edge.sourceID })?.title ?? "Unknown"
        let target = store.project.nodes.first(where: { $0.id == edge.targetID })?.title ?? "Unknown"
        return "\(source) \(edge.kind.title) \(target)"
    }
}

private struct SubgoalEditor: View {
    @Binding var subgoal: ProofSubgoal
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Subgoal", text: $subgoal.title)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            Picker("Status", selection: $subgoal.status) {
                ForEach(ProofStatus.allCases) { status in
                    Text(status.title).tag(status)
                }
            }

            MultilineField(text: $subgoal.detail, minHeight: 64)
        }
        .padding(.vertical, 5)
    }
}

private struct SymbolEditor: View {
    @Binding var symbol: SymbolEntry
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Symbol", text: $symbol.symbol)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            TextField("Meaning", text: $symbol.meaning)
            TextField("Scope", text: $symbol.scope)
        }
        .padding(.vertical, 5)
    }
}

private struct EditableStringList: View {
    let title: String
    @Binding var items: [String]
    let placeholder: String
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(items.indices, id: \.self) { index in
                HStack {
                    TextField(placeholder, text: Binding(
                        get: { items[index] },
                        set: { items[index] = $0 }
                    ))
                    Button(role: .destructive) {
                        items.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                TextField(placeholder, text: $draft)
                Button {
                    let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    items.append(value)
                    draft = ""
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

private struct MultilineField: View {
    @Binding var text: String
    let minHeight: CGFloat
    var monospaced = false

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .frame(minHeight: minHeight)
            .padding(4)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

