import SwiftUI
import AppKit
import SwiftMath

/// Renders a proof statement. When the source is essentially a single equation it
/// is typeset in true 2D with SwiftMath (stacked fractions, roots, big operators,
/// matrices…). Mixed prose + inline math falls back to the inline Unicode renderer
/// so ordinary sentences still wrap and select normally.
struct MathText: View {
    let source: String
    var fontSize: CGFloat = 17
    var color: Color = .primary
    var alignment: TextAlignment = .leading

    var body: some View {
        if let latex = Self.renderableEquation(in: source) {
            MathEquationView(latex: latex, fontSize: fontSize, color: color, alignment: alignment)
        } else {
            Text(LaTeXRenderer.render(source))
        }
    }

    /// Returns the LaTeX to typeset in 2D when `source` is a single equation that
    /// SwiftMath can actually parse; otherwise nil (render as inline text instead).
    static func renderableEquation(in source: String) -> String? {
        guard let candidate = displayEquation(in: source) else { return nil }
        var error: NSError?
        guard MTMathListBuilder.build(fromString: candidate, error: &error) != nil, error == nil else {
            return nil
        }
        return candidate
    }

    private static func displayEquation(in source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
            return String(trimmed.dropFirst(2).dropLast(2))
        }
        if trimmed.hasPrefix("\\["), trimmed.hasSuffix("\\]"), trimmed.count > 4 {
            return String(trimmed.dropFirst(2).dropLast(2))
        }
        if trimmed.hasPrefix("\\("), trimmed.hasSuffix("\\)"), trimmed.count > 4 {
            return String(trimmed.dropFirst(2).dropLast(2))
        }
        if trimmed.hasPrefix("$"), trimmed.hasSuffix("$"), trimmed.count > 2 {
            let inner = String(trimmed.dropFirst().dropLast())
            if !inner.contains("$") { return inner }
        }
        // A bare equation with no prose: no spaces and clearly mathematical.
        if !trimmed.contains(" "),
           trimmed.contains("\\") || trimmed.range(of: #"[=<>+\-^_/]"#, options: .regularExpression) != nil {
            return trimmed
        }
        return nil
    }
}

private struct MathEquationView: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let color: Color
    let alignment: TextAlignment

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.labelMode = .display
        label.displayErrorInline = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = NSColor(color)
        label.textAlignment = mtAlignment
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        nsView.latex = latex
        nsView.fontSize = fontSize
        if let width = proposal.width, width > 0, width.isFinite {
            nsView.preferredMaxLayoutWidth = width
        }
        let size = nsView.intrinsicContentSize
        return CGSize(width: size.width, height: max(size.height, fontSize))
    }

    private var mtAlignment: MTTextAlignment {
        switch alignment {
        case .center: .center
        case .trailing: .right
        default: .left
        }
    }
}
