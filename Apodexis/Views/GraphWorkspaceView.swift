import SwiftUI

import AppKit

struct GraphWorkspaceView: View {
    @EnvironmentObject private var store: ProofStore

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader()
            Divider()
            GraphCanvasView()
        }
        .background(Color.appBackground)
    }
}

private struct WorkspaceHeader: View {
    @EnvironmentObject private var store: ProofStore

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LaTeXRenderer.render(store.selectedBranch?.name ?? "All Branches"))
                    .font(.headline)
                    .lineLimit(1)

                if let summary = store.selectedBranch?.summary, !summary.isEmpty {
                    Text(LaTeXRenderer.render(summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            MetricPill(title: "Nodes", value: "\(store.visibleNodes.count)", systemImage: "circle.grid.2x2")
            MetricPill(title: "Edges", value: "\(visibleEdgeCount)", systemImage: "arrow.right")
            MetricPill(title: "Open", value: "\(openCount)", systemImage: "target")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var visibleNodeIDs: Set<UUID> {
        Set(store.visibleNodes.map(\.id))
    }

    private var visibleEdgeCount: Int {
        store.project.edges.filter {
            visibleNodeIDs.contains($0.sourceID) && visibleNodeIDs.contains($0.targetID)
        }.count
    }

    private var openCount: Int {
        store.visibleNodes.reduce(0) { total, node in
            total + node.subgoals.filter { $0.status != .proven }.count
        }
    }
}

private struct MetricPill: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(value)
                .fontWeight(.semibold)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct GraphCanvasView: View {
    @EnvironmentObject private var store: ProofStore

    private static let branchFocusID = "branch-focus"

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .topTrailing) {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            drawEdges(in: context)
                        }
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .allowsHitTesting(false)

                        ForEach(visibleEdges) { edge in
                            if let source = node(edge.sourceID), let target = node(edge.targetID) {
                                EdgeLabel(edge: edge)
                                    .position(edgeLabelPosition(source: source, target: target))
                            }
                        }

                        Color.clear
                            .frame(width: 1, height: 1)
                            .position(branchFocusPoint)
                            .id(Self.branchFocusID)

                        ForEach(store.visibleNodes) { node in
                            GraphNodeCard(
                                node: node,
                                onDragEnded: { point in
                                    store.moveNode(id: node.id, to: point)
                                }
                            )
                            .position(cgPosition(for: node))
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .background(canvasBackground)
                }

                HStack(spacing: 8) {
                    Button {
                        store.autoLayoutSelectedBranch()
                        centerBranch(proxy)
                    } label: {
                        Image(systemName: "rectangle.connected.to.line.below")
                            .font(.body.weight(.semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Auto layout")

                    Button {
                        centerBranch(proxy)
                    } label: {
                        Image(systemName: "scope")
                            .font(.body.weight(.semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Center branch")
                }
                .padding(14)
            }
            .onAppear {
                centerBranch(proxy, animated: false)
            }
            .onChange(of: store.selectedBranchID) {
                centerBranch(proxy)
            }
            .onChange(of: store.project.id) {
                centerBranch(proxy, animated: false)
            }
            .onChange(of: store.layoutRevision) {
                centerBranch(proxy, animated: false)
            }
        }
    }

    private var canvasBackground: some View {
        ZStack {
            Color.appSecondaryBackground
            GridPattern()
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var canvasSize: CGSize {
        let bounds = visibleBounds
        return CGSize(
            width: max(GraphMetrics.minimumCanvasSize.width, bounds.maxX + GraphMetrics.canvasPadding),
            height: max(GraphMetrics.minimumCanvasSize.height, bounds.maxY + GraphMetrics.canvasPadding)
        )
    }

    private var visibleBounds: CGRect {
        guard !store.visibleNodes.isEmpty else {
            return CGRect(origin: .zero, size: GraphMetrics.minimumCanvasSize)
        }

        let positions = store.visibleNodes.map { cgPosition(for: $0) }
        let minX = positions.map(\.x).min() ?? 0
        let maxX = positions.map(\.x).max() ?? 0
        let minY = positions.map(\.y).min() ?? 0
        let maxY = positions.map(\.y).max() ?? 0

        return CGRect(
            x: minX - GraphMetrics.cardSize.width / 2,
            y: minY - GraphMetrics.cardSize.height / 2,
            width: maxX - minX + GraphMetrics.cardSize.width,
            height: maxY - minY + GraphMetrics.cardSize.height
        )
    }

    private var branchFocusPoint: CGPoint {
        let bounds = visibleBounds
        let size = canvasSize
        return CGPoint(
            x: max(1, min(size.width - 1, bounds.midX)),
            y: max(1, min(size.height - 1, bounds.midY))
        )
    }

    private var visibleNodeIDs: Set<UUID> {
        Set(store.visibleNodes.map(\.id))
    }

    private var visibleEdges: [ProofEdge] {
        store.project.edges.filter {
            visibleNodeIDs.contains($0.sourceID) && visibleNodeIDs.contains($0.targetID)
        }
    }

    private func node(_ id: UUID) -> ProofNode? {
        store.project.nodes.first { $0.id == id }
    }

    private func cgPosition(for node: ProofNode) -> CGPoint {
        let point = node.position
        return CGPoint(x: point.x, y: point.y)
    }

    private func drawEdges(in context: GraphicsContext) {
        for edge in visibleEdges {
            guard let source = node(edge.sourceID), let target = node(edge.targetID) else { continue }

            let sourceCenter = cgPosition(for: source)
            let targetCenter = cgPosition(for: target)
            let start = connectionPoint(from: sourceCenter, toward: targetCenter)
            let end = connectionPoint(from: targetCenter, toward: sourceCenter)
            let deltaX = end.x - start.x
            let deltaY = end.y - start.y
            let horizontalOffset = max(70, min(260, abs(deltaX) * 0.38))
            let direction: CGFloat = deltaX >= 0 ? 1 : -1
            let controlA: CGPoint
            let controlB: CGPoint

            if abs(deltaX) < 50 {
                controlA = CGPoint(x: start.x, y: start.y + deltaY * 0.36)
                controlB = CGPoint(x: end.x, y: end.y - deltaY * 0.36)
            } else {
                controlA = CGPoint(x: start.x + horizontalOffset * direction, y: start.y)
                controlB = CGPoint(x: end.x - horizontalOffset * direction, y: end.y)
            }

            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: controlA, control2: controlB)

            context.stroke(path, with: .color(edge.kind.tint.opacity(0.72)), lineWidth: 2.5)
            drawArrow(in: context, from: controlB, to: end, color: edge.kind.tint)
        }
    }

    private func connectionPoint(from center: CGPoint, toward target: CGPoint) -> CGPoint {
        let vector = CGSize(width: target.x - center.x, height: target.y - center.y)
        guard vector.width != 0 || vector.height != 0 else { return center }

        let halfWidth = GraphMetrics.cardSize.width / 2
        let halfHeight = GraphMetrics.cardSize.height / 2
        let xScale = vector.width == 0 ? CGFloat.greatestFiniteMagnitude : halfWidth / abs(vector.width)
        let yScale = vector.height == 0 ? CGFloat.greatestFiniteMagnitude : halfHeight / abs(vector.height)
        let scale = min(xScale, yScale)

        return CGPoint(
            x: center.x + vector.width * scale,
            y: center.y + vector.height * scale
        )
    }

    private func drawArrow(in context: GraphicsContext, from start: CGPoint, to end: CGPoint, color: Color) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let size: CGFloat = 9
        let wingA = CGPoint(
            x: end.x - size * cos(angle - .pi / 6),
            y: end.y - size * sin(angle - .pi / 6)
        )
        let wingB = CGPoint(
            x: end.x - size * cos(angle + .pi / 6),
            y: end.y - size * sin(angle + .pi / 6)
        )

        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: wingA)
        arrow.move(to: end)
        arrow.addLine(to: wingB)

        context.stroke(arrow, with: .color(color.opacity(0.84)), lineWidth: 2.5)
    }

    private func edgeLabelPosition(source: ProofNode, target: ProofNode) -> CGPoint {
        let sourceCenter = cgPosition(for: source)
        let targetCenter = cgPosition(for: target)
        return CGPoint(
            x: (sourceCenter.x + targetCenter.x) / 2,
            y: (sourceCenter.y + targetCenter.y) / 2 - 18
        )
    }

    private func centerBranch(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(Self.branchFocusID, anchor: .center)
                }
            } else {
                proxy.scrollTo(Self.branchFocusID, anchor: .center)
            }
        }
    }
}

private enum GraphMetrics {
    static let cardSize = CGSize(width: 246, height: 154)
    static let minimumCanvasSize = CGSize(width: 1600, height: 1050)
    static let canvasPadding: CGFloat = 360
}

private struct EdgeLabel: View {
    @EnvironmentObject private var store: ProofStore
    let edge: ProofEdge

    var body: some View {
        Menu {
            ForEach(EdgeKind.allCases) { kind in
                Button {
                    store.updateEdgeKind(id: edge.id, kind: kind)
                } label: {
                    Label(kind.title, systemImage: kind == edge.kind ? "checkmark" : "arrow.right")
                }
            }
        } label: {
            Text(labelText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(edge.kind.tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(edge.kind.tint.opacity(0.25), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help("Change relation")
    }

    private var labelText: String {
        if edge.label.isEmpty {
            return edge.kind.title
        }
        return "\(edge.kind.title) · \(LaTeXRenderer.render(edge.label))"
    }
}

private struct GraphNodeCard: View {
    @EnvironmentObject private var store: ProofStore
    let node: ProofNode
    let onDragEnded: (GraphPoint) -> Void

    @State private var dragStart: GraphPoint?
    @State private var dragOffset: CGSize = .zero
    @State private var editingField: EditableNodeField?
    @State private var draftTitle = ""
    @State private var draftStatement = ""
    @FocusState private var focusedField: EditableNodeField?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: node.kind.systemImage)
                    .foregroundStyle(node.kind.tint)
                    .frame(width: 20)

                Text(node.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(node.kind.tint)

                Spacer()

                if store.sourceURL(for: node) != nil {
                    Button {
                        openSourceFile()
                    } label: {
                        Image(systemName: "curlybraces")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Open source file")
                }

                ProofStatusDotMenu(status: node.status) { status in
                    setProofStatus(status)
                }
            }

            titleContent

            statementContent

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                ProofStatusMenu(status: node.status) { status in
                    setProofStatus(status)
                }
                VerificationStatusMenu(status: node.verification) { status in
                    setVerificationStatus(status)
                }
                if !node.subgoals.isEmpty {
                    SubgoalStatusMenu(
                        text: "\(openSubgoalCount)/\(node.subgoals.count) goals",
                        color: openSubgoalCount == 0 ? .green : .orange,
                        selectedStatus: primarySubgoalStatus
                    ) { status in
                        setPrimarySubgoalStatus(status)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: GraphMetrics.cardSize.width, height: GraphMetrics.cardSize.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: borderWidth)
        }
        .shadow(color: .black.opacity(store.selectedNodeID == node.id ? 0.14 : 0.07), radius: 10, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .offset(dragOffset)
        .transaction { transaction in
            transaction.animation = nil
        }
        .onTapGesture {
            if store.edgeCreationMode {
                store.handleEdgeCreationClick(on: node.id)
            } else {
                store.selectNode(id: node.id)
            }
        }
        .gesture(dragGesture, including: editingField == nil && !store.edgeCreationMode ? .all : .none)
        .onChange(of: focusedField) {
            guard let editingField, focusedField != editingField else { return }
            commitEditing()
        }
        .contextMenu {
            Button(role: .destructive) {
                store.deleteNode(id: node.id)
            } label: {
                Label("Delete Node", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var titleContent: some View {
        if editingField == .title {
            TextField("Title", text: $draftTitle, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .focused($focusedField, equals: .title)
                .onSubmit(commitEditing)
        } else {
            Text(LaTeXRenderer.render(node.title))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture(count: 2) {
                    beginEditing(.title)
                }
                .onLongPressGesture {
                    beginEditing(.title)
                }
        }
    }

    @ViewBuilder
    private var statementContent: some View {
        if editingField == .statement {
            TextField("Statement", text: $draftStatement, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.caption)
                .lineLimit(3)
                .focused($focusedField, equals: .statement)
                .onSubmit(commitEditing)
        } else {
            Text(node.statement.isEmpty ? "No statement" : LaTeXRenderer.render(node.statement))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .onTapGesture(count: 2) {
                    beginEditing(.statement)
                }
                .onLongPressGesture {
                    beginEditing(.statement)
                }
        }
    }

    private var borderColor: Color {
        if store.edgeCreationSourceID == node.id {
            return .accentColor
        }
        return store.selectedNodeID == node.id ? node.kind.tint : Color.primary.opacity(0.12)
    }

    private var borderWidth: CGFloat {
        if store.edgeCreationSourceID == node.id {
            return 3
        }
        return store.selectedNodeID == node.id ? 2.5 : 1
    }

    private var openSubgoalCount: Int {
        node.subgoals.filter { $0.status != .proven }.count
    }

    private var primarySubgoalStatus: ProofStatus {
        node.subgoals.first { $0.status != .proven }?.status ?? node.subgoals.first?.status ?? .proven
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil {
                    dragStart = node.position
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                let start = dragStart ?? node.position
                let finalPoint = GraphPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
                onDragEnded(finalPoint)
                dragStart = nil
                dragOffset = .zero
                store.selectNode(id: node.id)
            }
    }

    private func beginEditing(_ field: EditableNodeField) {
        let currentNode = latestNode
        draftTitle = currentNode.title
        draftStatement = currentNode.statement
        editingField = field
        store.selectNode(id: node.id)

        DispatchQueue.main.async {
            focusedField = field
        }
    }

    private func commitEditing() {
        guard let editingField else { return }

        updateLatestNode { updated in
            switch editingField {
            case .title:
                let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.title = trimmed.isEmpty ? updated.title : trimmed
            case .statement:
                updated.statement = draftStatement
            }
        }

        self.editingField = nil
        focusedField = nil
    }

    private func setProofStatus(_ status: ProofStatus) {
        updateLatestNode { node in
            node.status = status
        }
    }

    private func setVerificationStatus(_ status: VerificationStatus) {
        updateLatestNode { node in
            node.verification = status
        }
    }

    private func setPrimarySubgoalStatus(_ status: ProofStatus) {
        updateLatestNode { node in
            let targetIndex = node.subgoals.firstIndex { $0.status != .proven } ?? node.subgoals.indices.first
            guard let targetIndex else { return }
            node.subgoals[targetIndex].status = status
        }
    }

    private func openSourceFile() {
        guard let sourceURL = store.sourceURL(for: node) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(sourceURL)
        #endif
    }

    private var latestNode: ProofNode {
        store.project.nodes.first { $0.id == node.id } ?? node
    }

    private func updateLatestNode(_ updates: (inout ProofNode) -> Void) {
        var updated = latestNode
        updates(&updated)
        store.updateNode(updated)
    }
}

private enum EditableNodeField: Hashable {
    case title
    case statement
}

private struct ProofStatusDotMenu: View {
    let status: ProofStatus
    let onChange: (ProofStatus) -> Void

    var body: some View {
        Menu {
            ForEach(ProofStatus.allCases) { option in
                Button {
                    onChange(option)
                } label: {
                    Label(option.title, systemImage: option == status ? "checkmark" : "circle")
                }
            }
        } label: {
            Circle()
                .fill(status.tint)
                .frame(width: 10, height: 10)
        }
        .buttonStyle(.plain)
        .help("Proof status")
    }
}

private struct ProofStatusMenu: View {
    let status: ProofStatus
    let onChange: (ProofStatus) -> Void

    var body: some View {
        Menu {
            ForEach(ProofStatus.allCases) { option in
                Button {
                    onChange(option)
                } label: {
                    Label(option.title, systemImage: option == status ? "checkmark" : "circle")
                }
            }
        } label: {
            StatusPill(text: status.title, color: status.tint)
        }
        .buttonStyle(.plain)
        .help("Proof status")
    }
}

private struct VerificationStatusMenu: View {
    let status: VerificationStatus
    let onChange: (VerificationStatus) -> Void

    var body: some View {
        Menu {
            ForEach(VerificationStatus.allCases) { option in
                Button {
                    onChange(option)
                } label: {
                    Label(option.title, systemImage: option == status ? "checkmark" : "circle")
                }
            }
        } label: {
            StatusPill(text: status.title, color: status.tint)
        }
        .buttonStyle(.plain)
        .help("Formal status")
    }
}

private struct SubgoalStatusMenu: View {
    let text: String
    let color: Color
    let selectedStatus: ProofStatus
    let onChange: (ProofStatus) -> Void

    var body: some View {
        Menu {
            ForEach(ProofStatus.allCases) { option in
                Button {
                    onChange(option)
                } label: {
                    Label(option.title, systemImage: option == selectedStatus ? "checkmark" : "circle")
                }
            }
        } label: {
            StatusPill(text: text, color: color)
        }
        .buttonStyle(.plain)
        .help("Primary subgoal status")
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct GridPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing: CGFloat = 40

        var x = rect.minX
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }

        var y = rect.minY
        while y <= rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }

        return path
    }
}

private extension Color {
    static var appBackground: Color {
        Color(NSColor.windowBackgroundColor)
    }

    static var appSecondaryBackground: Color {
        Color(NSColor.controlBackgroundColor)
    }
}
