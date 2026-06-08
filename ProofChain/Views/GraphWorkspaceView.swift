import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
                Text(store.selectedBranch?.name ?? "All Branches")
                    .font(.headline)
                    .lineLimit(1)

                if let summary = store.selectedBranch?.summary, !summary.isEmpty {
                    Text(summary)
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

    private let canvasSize = CGSize(width: 1600, height: 1050)

    var body: some View {
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

                ForEach(store.visibleNodes) { node in
                    GraphNodeCard(node: node)
                        .position(CGPoint(x: node.position.x, y: node.position.y))
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .background(canvasBackground)
        }
    }

    private var canvasBackground: some View {
        ZStack {
            Color.appSecondaryBackground
            GridPattern()
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
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

    private func drawEdges(in context: GraphicsContext) {
        for edge in visibleEdges {
            guard let source = node(edge.sourceID), let target = node(edge.targetID) else { continue }

            let start = CGPoint(x: source.position.x + 110, y: source.position.y)
            let end = CGPoint(x: target.position.x - 110, y: target.position.y)
            let controlOffset = max(80, abs(end.x - start.x) * 0.35)
            let controlA = CGPoint(x: start.x + controlOffset, y: start.y)
            let controlB = CGPoint(x: end.x - controlOffset, y: end.y)

            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: controlA, control2: controlB)

            context.stroke(path, with: .color(edge.kind.tint.opacity(0.72)), lineWidth: 2.5)

            drawArrow(in: context, from: start, to: end, color: edge.kind.tint)
        }
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
        CGPoint(
            x: (source.position.x + target.position.x) / 2,
            y: (source.position.y + target.position.y) / 2 - 18
        )
    }
}

private struct EdgeLabel: View {
    let edge: ProofEdge

    var body: some View {
        Text(edge.label.isEmpty ? edge.kind.title : edge.label)
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
}

private struct GraphNodeCard: View {
    @EnvironmentObject private var store: ProofStore
    let node: ProofNode
    @State private var dragStart: GraphPoint?

    private let cardSize = CGSize(width: 230, height: 132)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: node.kind.systemImage)
                    .foregroundStyle(node.kind.tint)
                    .frame(width: 20)

                Text(node.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(node.kind.tint)

                Spacer()

                Circle()
                    .fill(node.status.tint)
                    .frame(width: 8, height: 8)
            }

            Text(node.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(node.statement.isEmpty ? "No statement" : node.statement)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                StatusChip(text: node.status.title, color: node.status.tint)
                if node.verification != .unchecked {
                    StatusChip(text: node.verification.title, color: node.verification.tint)
                }
            }
        }
        .padding(12)
        .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: store.selectedNodeID == node.id ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(store.selectedNodeID == node.id ? 0.14 : 0.07), radius: 10, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            store.selectedNodeID = node.id
        }
        .gesture(dragGesture)
        .contextMenu {
            Button(role: .destructive) {
                store.deleteNode(id: node.id)
            } label: {
                Label("Delete Node", systemImage: "trash")
            }
        }
    }

    private var borderColor: Color {
        store.selectedNodeID == node.id ? node.kind.tint : Color.primary.opacity(0.12)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil {
                    dragStart = node.position
                    store.selectedNodeID = node.id
                }
                guard let dragStart else { return }
                store.moveNode(
                    id: node.id,
                    to: GraphPoint(
                        x: dragStart.x + value.translation.width,
                        y: dragStart.y + value.translation.height
                    )
                )
            }
            .onEnded { _ in
                dragStart = nil
            }
    }
}

private struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
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
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    static var appSecondaryBackground: Color {
        #if os(iOS)
        Color(UIColor.secondarySystemBackground)
        #else
        Color(NSColor.controlBackgroundColor)
        #endif
    }
}
