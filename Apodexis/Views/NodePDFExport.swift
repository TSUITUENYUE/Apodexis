import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftMath

/// Writes a SwiftUI view out as a single-page vector PDF via `ImageRenderer`.
@MainActor
enum PDFExporter {
    static let pageWidth: CGFloat = 612   // US Letter width in points

    /// Asks where to save, then renders. Pass `proposedWidth: nil` to let the view
    /// use its own size (e.g. a full graph) instead of page width.
    @discardableResult
    static func exportWithPanel<Content: View>(
        _ content: Content,
        suggestedName: String,
        proposedWidth: CGFloat? = PDFExporter.pageWidth
    ) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = sanitizedFileName(suggestedName) + ".pdf"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return write(content, to: url, proposedWidth: proposedWidth) ? url : nil
    }

    static func write<Content: View>(_ content: Content, to url: URL, proposedWidth: CGFloat? = PDFExporter.pageWidth) -> Bool {
        let renderer = ImageRenderer(content: content)
        if let proposedWidth {
            renderer.proposedSize = ProposedViewSize(width: proposedWidth, height: nil)
        }
        var succeeded = false
        renderer.render { size, render in
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            context.beginPDFPage(nil)
            render(context)
            context.endPDFPage()
            context.closePDF()
            succeeded = true
        }
        return succeeded
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let plain = LaTeXRenderer.plain(name)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(plain.prefix(80))
        return trimmed.isEmpty ? "Apodexis node" : trimmed
    }
}

/// Math-aware text for PDF output. `ImageRenderer` cannot draw NSViewRepresentable
/// content, so single equations are typeset through SwiftMath's `MathImage` into a
/// plain `Image`; prose falls back to the Unicode renderer.
private struct PrintMathText: View {
    let source: String
    var fontSize: CGFloat = 12

    var body: some View {
        if let latex = MathText.renderableEquation(in: source),
           let image = Self.equationImage(latex: latex, fontSize: fontSize + 4) {
            Image(nsImage: image)
        } else {
            Text(LaTeXRenderer.render(source))
                .font(.system(size: fontSize))
        }
    }

    private static func equationImage(latex: String, fontSize: CGFloat) -> NSImage? {
        var math = MathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: .black,
            labelMode: .display,
            textAlignment: .left
        )
        let (error, image, _) = math.asImage()
        guard error == nil else { return nil }
        return image
    }
}

/// A static, print-friendly rendering of the whole proof graph (nodes, connection
/// curves, relation labels) at its natural size, with a title bar and footer.
struct GraphPrintView: View {
    let nodes: [ProofNode]
    let edges: [ProofEdge]
    let title: String
    let branchName: String?

    private static let cardSize = CGSize(width: 214, height: 74)
    private static let margin: CGFloat = 70

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            graphArea
            footer
        }
        .background(Color.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LaTeXRenderer.render(title))
                .font(.system(size: 20, weight: .bold))
            if let branchName {
                Text(LaTeXRenderer.render(branchName))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.black.opacity(0.55))
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 32)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        Text("\(nodes.count) nodes · \(edges.count) relations — exported from Apodexis on \(Date.now.formatted(date: .abbreviated, time: .shortened))")
            .font(.system(size: 9))
            .foregroundStyle(Color.black.opacity(0.45))
            .padding(.horizontal, 40)
            .padding(.bottom, 28)
    }

    private var graphArea: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawEdges(in: context)
            }

            ForEach(edges) { edge in
                if let source = positions[edge.sourceID], let target = positions[edge.targetID] {
                    edgeLabel(for: edge)
                        .position(x: (source.x + target.x) / 2, y: (source.y + target.y) / 2 - 18)
                }
            }

            ForEach(nodes) { node in
                chip(for: node)
                    .position(positions[node.id] ?? .zero)
            }
        }
        .frame(width: graphSize.width, height: graphSize.height)
    }

    // MARK: Geometry

    private var boundsRect: CGRect {
        guard !nodes.isEmpty else { return CGRect(x: 0, y: 0, width: 400, height: 200) }
        let xs = nodes.map(\.position.x)
        let ys = nodes.map(\.position.y)
        return CGRect(
            x: xs.min()! - Self.cardSize.width / 2,
            y: ys.min()! - Self.cardSize.height / 2,
            width: xs.max()! - xs.min()! + Self.cardSize.width,
            height: ys.max()! - ys.min()! + Self.cardSize.height
        )
    }

    private var graphSize: CGSize {
        CGSize(width: boundsRect.width + 2 * Self.margin, height: boundsRect.height + 2 * Self.margin)
    }

    /// Node centers shifted so the graph sits inside the margins.
    private var positions: [UUID: CGPoint] {
        var result: [UUID: CGPoint] = [:]
        for node in nodes {
            result[node.id] = CGPoint(
                x: node.position.x - boundsRect.minX + Self.margin,
                y: node.position.y - boundsRect.minY + Self.margin
            )
        }
        return result
    }

    // MARK: Pieces

    private func chip(for node: ProofNode) -> some View {
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
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 2)

            Circle()
                .fill(node.status.tint)
                .frame(width: 9, height: 9)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(node.kind.tint)
                .frame(width: 4)
                .padding(.vertical, 12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.18), lineWidth: 1)
        }
    }

    private func edgeLabel(for edge: ProofEdge) -> some View {
        HStack(spacing: 4) {
            Image(systemName: edge.kind.glyph)
                .font(.system(size: 8, weight: .bold))
            Text(edge.label.isEmpty ? edge.kind.title : "\(edge.kind.title) · \(LaTeXRenderer.plain(edge.label))")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(edge.kind.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.white, in: Capsule())
        .overlay {
            Capsule().stroke(edge.kind.tint.opacity(0.4), lineWidth: 1)
        }
    }

    // MARK: Edge drawing (mirrors the canvas)

    private func drawEdges(in context: GraphicsContext) {
        for edge in edges {
            guard let sourceCenter = positions[edge.sourceID],
                  let targetCenter = positions[edge.targetID] else { continue }

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

    private func connectionPoint(from center: CGPoint, toward target: CGPoint) -> CGPoint {
        let vector = CGSize(width: target.x - center.x, height: target.y - center.y)
        guard vector.width != 0 || vector.height != 0 else { return center }
        let halfWidth = Self.cardSize.width / 2
        let halfHeight = Self.cardSize.height / 2
        let xScale = vector.width == 0 ? CGFloat.greatestFiniteMagnitude : halfWidth / abs(vector.width)
        let yScale = vector.height == 0 ? CGFloat.greatestFiniteMagnitude : halfHeight / abs(vector.height)
        let scale = min(xScale, yScale)
        return CGPoint(x: center.x + vector.width * scale, y: center.y + vector.height * scale)
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
}

/// A static, print-friendly rendering of one node — fixed light appearance so the
/// PDF is always black-on-white regardless of the app's theme.
struct NodePrintView: View {
    struct Relation {
        let kind: EdgeKind
        let outgoing: Bool
        let otherTitle: String
    }

    let node: ProofNode
    let projectTitle: String
    let relations: [Relation]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Text(LaTeXRenderer.render(node.title))
                .font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            if !node.statement.isEmpty {
                section("Statement") { PrintMathText(source: node.statement, fontSize: 14) }
            }
            if !node.context.isEmpty {
                section("Context") { PrintMathText(source: node.context) }
            }
            if !node.assumptions.isEmpty {
                section("Assumptions") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(node.assumptions.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                Text(LaTeXRenderer.render(node.assumptions[index]))
                                    .font(.system(size: 12))
                            }
                        }
                    }
                }
            }
            if !node.proofSketch.isEmpty {
                section("Proof sketch") { PrintMathText(source: node.proofSketch) }
            }
            if !node.formalCode.isEmpty {
                section("Formal — \(node.formalDialect.title)") {
                    Text(node.formalCode)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(6)
                }
            }
            if !node.subgoals.isEmpty {
                section("Subgoals") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(node.subgoals) { subgoal in
                            HStack(alignment: .top, spacing: 6) {
                                Text(subgoal.status == .proven ? "☑" : "☐")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(LaTeXRenderer.render(subgoal.title))
                                        .font(.system(size: 12))
                                    if !subgoal.detail.isEmpty {
                                        Text(LaTeXRenderer.render(subgoal.detail))
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(Color.black.opacity(0.6))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !node.symbols.isEmpty {
                section("Symbols") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(node.symbols) { symbol in
                            HStack(alignment: .top, spacing: 10) {
                                Text(LaTeXRenderer.render(symbol.symbol))
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(minWidth: 26, alignment: .leading)
                                Text(symbol.meaning)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.black.opacity(0.6))
                            }
                        }
                    }
                }
            }
            if !relations.isEmpty {
                section("Relations") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(relations.indices, id: \.self) { index in
                            let relation = relations[index]
                            HStack(spacing: 6) {
                                Text(relation.outgoing ? "→" : "←")
                                Text(relation.kind.title)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(LaTeXRenderer.render(relation.otherTitle))
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            Divider()
            Text("\(projectTitle) — exported from Apodexis on \(Date.now.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 9))
                .foregroundStyle(Color.black.opacity(0.45))
        }
        .padding(48)
        .frame(width: PDFExporter.pageWidth, alignment: .leading)
        .background(Color.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(node.kind.title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(node.kind.tint.opacity(0.15))
                .foregroundStyle(node.kind.tint)
                .clipShape(Capsule())
            Text(node.status.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.55))
            Spacer()
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Color.black.opacity(0.5))
            content()
        }
    }
}
