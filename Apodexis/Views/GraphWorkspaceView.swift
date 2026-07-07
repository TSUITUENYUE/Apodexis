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
        .overlay {
            if let id = store.expandedNodeID {
                NodeExpansionOverlay(nodeID: id)
            }
        }
    }
}

private struct WorkspaceHeader: View {
    @EnvironmentObject private var store: ProofStore
    @State private var query = ""
    @State private var matchOffset = 0
    @FocusState private var searchFocused: Bool

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

            searchField

            MetricPill(title: "Nodes", value: "\(store.visibleNodes.count)", systemImage: "circle.grid.2x2")
            MetricPill(title: "Edges", value: "\(visibleEdgeCount)", systemImage: "arrow.right")
            MetricPill(title: "Open", value: "\(openCount)", systemImage: "target")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .background {
            // ⌘F focuses the search field.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Find node", text: $query)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: searchFocused || !query.isEmpty ? 150 : 90)
                .focused($searchFocused)
                .onSubmit { jump(advance: true) }
            if !query.isEmpty {
                Text(matchLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    query = ""
                    matchOffset = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .animation(.easeOut(duration: 0.15), value: searchFocused)
        .onChange(of: query) {
            matchOffset = 0
            jump(advance: false)
        }
    }

    /// Searches every branch, not just the visible one, so lost nodes are findable.
    private var matches: [ProofNode] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return store.project.nodes.filter {
            $0.title.lowercased().contains(needle)
                || LaTeXRenderer.plain($0.title).lowercased().contains(needle)
        }
    }

    private var matchLabel: String {
        matches.isEmpty ? "0" : "\((matchOffset % matches.count) + 1)/\(matches.count)"
    }

    private func jump(advance: Bool) {
        let found = matches
        guard !found.isEmpty else { return }
        if advance, found.count > 1 { matchOffset += 1 }
        store.focusNode(id: found[matchOffset % found.count].id)
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
    static let canvasSpace = "apodexis.canvas"

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .topTrailing) {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            drawEdges(in: context)
                            drawPendingConnection(in: context)
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
                            .id(node.id)
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .background(canvasBackground)
                    .coordinateSpace(name: GraphCanvasView.canvasSpace)
                    .onTapGesture(count: 2, coordinateSpace: .named(GraphCanvasView.canvasSpace)) { location in
                        store.addNode(at: GraphPoint(x: location.x, y: location.y))
                    }
                }

                if !store.visibleNodes.isEmpty {
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

                        Button {
                            exportGraphPDF()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Export graph as PDF")
                    }
                    .padding(14)
                }
            }
            .overlay {
                if store.visibleNodes.isEmpty {
                    CanvasEmptyState()
                }
            }
            .onAppear {
                centerBranch(proxy, animated: false)
            }
            .onChange(of: store.focusRevision) {
                guard let id = store.focusTargetID else { return }
                // Runs after the branch-change recenter (also async) so the
                // focused node wins when the search jumps across branches.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
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

            context.stroke(
                path,
                with: .color(edge.kind.tint.opacity(0.8)),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round, dash: edge.kind.dashPattern)
            )
            fillArrowHead(in: context, tip: end, from: controlB, color: edge.kind.tint)
            if edge.kind.isBidirectional {
                fillArrowHead(in: context, tip: start, from: controlA, color: edge.kind.tint)
            }
        }
    }

    private func fillArrowHead(in context: GraphicsContext, tip: CGPoint, from: CGPoint, color: Color) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let size: CGFloat = 11
        let spread = CGFloat.pi / 7
        let wingA = CGPoint(x: tip.x - size * cos(angle - spread), y: tip.y - size * sin(angle - spread))
        let wingB = CGPoint(x: tip.x - size * cos(angle + spread), y: tip.y - size * sin(angle + spread))

        var triangle = Path()
        triangle.move(to: tip)
        triangle.addLine(to: wingA)
        triangle.addLine(to: wingB)
        triangle.closeSubpath()
        context.fill(triangle, with: .color(color.opacity(0.9)))
    }

    private func drawPendingConnection(in context: GraphicsContext) {
        guard let pending = store.pendingConnection,
              let source = node(pending.sourceID) else { return }

        let end = CGPoint(x: pending.currentPoint.x, y: pending.currentPoint.y)
        let start = connectionPoint(from: cgPosition(for: source), toward: end)

        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(
            path,
            with: .color(Color.accentColor.opacity(0.85)),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 5])
        )
        drawArrow(in: context, from: start, to: end, color: .accentColor)
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

    private func exportGraphPDF() {
        PDFExporter.exportWithPanel(
            GraphPrintView(
                nodes: store.visibleNodes,
                edges: visibleEdges,
                title: store.project.title,
                branchName: store.selectedBranch?.name
            ),
            suggestedName: "\(store.project.title) graph",
            proposedWidth: nil
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

private struct CanvasEmptyState: View {
    @EnvironmentObject private var store: ProofStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Start your proof chain")
                    .font(.title2.weight(.semibold))
                Text("Add the theorem you're working toward, then branch out with the lemmas, cases, and steps that lead to it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                store.addNode(kind: .theorem)
            } label: {
                Label("Add your first node", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Double-click a node to edit it · use Connect to link two nodes")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}

private struct ConnectorHandle: View {
    var isActive: Bool

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 16, height: 16)
            .overlay {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay {
                Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 2)
            }
            .scaleEffect(isActive ? 1.3 : 1)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

private enum GraphMetrics {
    static let cardSize = CGSize(width: 214, height: 74)
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
            Divider()
            Button(role: .destructive) {
                store.deleteEdge(id: edge.id)
            } label: {
                Label("Remove Relation", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: edge.kind.glyph)
                    .font(.system(size: 9, weight: .bold))
                Text(labelText)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(edge.kind.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(edge.kind.tint.opacity(0.3), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Change relation")
    }

    private var labelText: String {
        if edge.label.isEmpty {
            return edge.kind.title
        }
        return "\(edge.kind.title) · \(LaTeXRenderer.plain(edge.label))"
    }
}

private struct GraphNodeCard: View {
    @EnvironmentObject private var store: ProofStore
    let node: ProofNode
    let onDragEnded: (GraphPoint) -> Void

    @State private var dragStart: GraphPoint?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.kind.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(node.kind.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.kind.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(node.kind.tint)
                Text(LaTeXRenderer.render(node.title))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 2)

            VStack(spacing: 5) {
                Circle()
                    .fill(node.status.tint)
                    .frame(width: 9, height: 9)
                    .help(node.status.title)
                if openSubgoalCount > 0 {
                    Text("\(openSubgoalCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .help("\(openSubgoalCount) open goal\(openSubgoalCount == 1 ? "" : "s")")
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(width: GraphMetrics.cardSize.width, height: GraphMetrics.cardSize.height, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(node.kind.tint)
                .frame(width: 4)
                .padding(.vertical, 12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: borderWidth)
        }
        .overlay(alignment: .trailing) {
            ConnectorHandle(isActive: isConnectionSource)
                .offset(x: 10)
                .highPriorityGesture(connectorDragGesture)
                .help("Drag to another node to connect")
        }
        .shadow(color: .black.opacity(store.selectedNodeID == node.id ? 0.16 : 0.08), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .offset(dragOffset)
        .transaction { transaction in
            transaction.animation = nil
        }
        .onTapGesture {
            expand()
        }
        .gesture(dragGesture)
        .contextMenu {
            Button {
                expand()
            } label: {
                Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                store.duplicateNode(id: node.id)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                store.deleteNode(id: node.id)
            } label: {
                Label("Delete Node", systemImage: "trash")
            }
        }
    }

    private func expand() {
        store.selectNode(id: node.id)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            store.expandedNodeID = node.id
        }
    }

    private var borderColor: Color {
        if isConnectionTarget || isConnectionSource {
            return .accentColor
        }
        return store.selectedNodeID == node.id ? node.kind.tint : Color.primary.opacity(0.12)
    }

    private var borderWidth: CGFloat {
        if isConnectionTarget || isConnectionSource {
            return 3
        }
        return store.selectedNodeID == node.id ? 2.5 : 1
    }

    private var isConnectionSource: Bool {
        store.pendingConnection?.sourceID == node.id
    }

    private var isConnectionTarget: Bool {
        guard let pending = store.pendingConnection, pending.sourceID != node.id else { return false }
        return nodeRect(for: node).contains(CGPoint(x: pending.currentPoint.x, y: pending.currentPoint.y))
    }

    private func nodeRect(for candidate: ProofNode) -> CGRect {
        CGRect(
            x: candidate.position.x - GraphMetrics.cardSize.width / 2,
            y: candidate.position.y - GraphMetrics.cardSize.height / 2,
            width: GraphMetrics.cardSize.width,
            height: GraphMetrics.cardSize.height
        )
    }

    private var connectorDragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(GraphCanvasView.canvasSpace))
            .onChanged { value in
                let point = GraphPoint(x: value.location.x, y: value.location.y)
                if store.pendingConnection == nil {
                    store.beginConnectionDrag(from: node.id, at: point)
                } else {
                    store.updateConnectionDrag(to: point)
                }
            }
            .onEnded { value in
                let point = CGPoint(x: value.location.x, y: value.location.y)
                let target = store.visibleNodes.first { candidate in
                    candidate.id != node.id && nodeRect(for: candidate).contains(point)
                }
                store.completeConnectionDrag(to: target?.id)
            }
    }

    private var openSubgoalCount: Int {
        node.subgoals.filter { $0.status != .proven }.count
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

// MARK: - Expand-to-page

private struct NodeExpansionOverlay: View {
    @EnvironmentObject private var store: ProofStore
    let nodeID: UUID

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.28))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .transition(.opacity)

            if let node = store.project.nodes.first(where: { $0.id == nodeID }) {
                NodePageView(node: node, onClose: dismiss)
                    .padding(36)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .background {
            Button("", action: dismiss)
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            store.expandedNodeID = nil
        }
    }
}

private struct NodePageView: View {
    @EnvironmentObject private var store: ProofStore
    let node: ProofNode
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(LaTeXRenderer.render(node.title))
                        .font(.title.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if !node.statement.isEmpty {
                        section("Statement") {
                            MathText(source: node.statement, fontSize: 21)
                                .font(.title3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !node.context.isEmpty {
                        section("Context") { bodyText(node.context) }
                    }
                    if !node.assumptions.isEmpty {
                        section("Assumptions") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(node.assumptions.indices, id: \.self) { index in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 5))
                                            .foregroundStyle(.secondary)
                                            .padding(.top, 6)
                                        Text(LaTeXRenderer.render(node.assumptions[index]))
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                    if !node.proofSketch.isEmpty {
                        section("Proof sketch") { bodyText(node.proofSketch) }
                    }
                    if !node.formalCode.isEmpty {
                        formalSection
                    }
                    if !node.subgoals.isEmpty {
                        subgoalsSection
                    }
                    if !node.symbols.isEmpty {
                        symbolsSection
                    }
                    if !relations.isEmpty {
                        relationsSection
                    }
                    footer
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 720, maxHeight: 720)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(node.kind.tint.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 30, y: 14)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Label(node.kind.title, systemImage: node.kind.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(node.kind.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(node.kind.tint.opacity(0.12), in: Capsule())

            Spacer()

            ProofStatusMenu(status: node.status) { setStatus($0) }
            VerificationStatusMenu(status: node.verification) { setVerification($0) }

            Button {
                exportPDF()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Export this node as PDF")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(16)
    }

    private func exportPDF() {
        let printRelations = relations.map { edge in
            let outgoing = edge.sourceID == node.id
            let otherID = outgoing ? edge.targetID : edge.sourceID
            let otherTitle = store.project.nodes.first { $0.id == otherID }?.title ?? "Unknown"
            return NodePrintView.Relation(kind: edge.kind, outgoing: outgoing, otherTitle: otherTitle)
        }
        PDFExporter.exportWithPanel(
            NodePrintView(node: node, projectTitle: store.project.title, relations: printRelations),
            suggestedName: node.title
        )
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func bodyText(_ text: String) -> some View {
        MathText(source: text, fontSize: 16)
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var formalSection: some View {
        section("Formal — \(node.formalDialect.title)") {
            VStack(alignment: .leading, spacing: 10) {
                Text(node.formalCode)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

                ForEach(FormalAnalyzer.holes(in: node.formalCode, dialect: node.formalDialect)) { hole in
                    Label("\(hole.token) · line \(hole.line)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var subgoalsSection: some View {
        section("Subgoals") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(node.subgoals) { subgoal in
                    Button {
                        toggleSubgoal(subgoal.id)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: subgoal.status == .proven ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(subgoal.status == .proven ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LaTeXRenderer.render(subgoal.title))
                                    .strikethrough(subgoal.status == .proven)
                                    .foregroundStyle(subgoal.status == .proven ? .secondary : .primary)
                                if !subgoal.detail.isEmpty {
                                    Text(LaTeXRenderer.render(subgoal.detail))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var symbolsSection: some View {
        section("Symbols") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(node.symbols) { symbol in
                    HStack(alignment: .top, spacing: 10) {
                        Text(LaTeXRenderer.render(symbol.symbol))
                            .font(.body.weight(.semibold))
                            .frame(minWidth: 28, alignment: .leading)
                        Text(symbol.meaning)
                            .foregroundStyle(.secondary)
                        if !symbol.scope.isEmpty {
                            Spacer()
                            Text(symbol.scope)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var relations: [ProofEdge] {
        store.project.edges.filter { $0.sourceID == node.id || $0.targetID == node.id }
    }

    private var relationsSection: some View {
        section("Relations") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(relations) { edge in
                    let outgoing = edge.sourceID == node.id
                    let otherID = outgoing ? edge.targetID : edge.sourceID
                    let otherTitle = store.project.nodes.first { $0.id == otherID }?.title ?? "Unknown"
                    HStack(spacing: 8) {
                        Image(systemName: outgoing ? "arrow.up.right" : "arrow.down.left")
                            .foregroundStyle(edge.kind.tint)
                            .frame(width: 16)
                        HStack(spacing: 4) {
                            Image(systemName: edge.kind.glyph).font(.caption2)
                            Text(edge.kind.title)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(edge.kind.tint)
                        Text(LaTeXRenderer.render(otherTitle))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if store.sourceURL(for: node) != nil {
                Button {
                    if let url = store.sourceURL(for: node) {
                        #if os(macOS)
                        NSWorkspace.shared.open(url)
                        #endif
                    }
                } label: {
                    Label("Open source file", systemImage: "curlybraces")
                }
            }
            Spacer()
            Button(role: .destructive) {
                store.deleteNode(id: node.id)
                onClose()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(.top, 4)
    }

    private func setStatus(_ status: ProofStatus) {
        update { $0.status = status }
    }

    private func setVerification(_ status: VerificationStatus) {
        update { $0.verification = status }
    }

    private func toggleSubgoal(_ id: UUID) {
        update { node in
            guard let index = node.subgoals.firstIndex(where: { $0.id == id }) else { return }
            node.subgoals[index].status = node.subgoals[index].status == .proven ? .open : .proven
        }
    }

    private func update(_ changes: (inout ProofNode) -> Void) {
        guard var updated = store.project.nodes.first(where: { $0.id == node.id }) else { return }
        changes(&updated)
        store.updateNode(updated)
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
