import Foundation

struct FormalHole: Identifiable, Equatable {
    var id: UUID = UUID()
    var line: Int
    var token: String
    var context: String
}

enum FormalAnalyzer {
    static func holes(in code: String, dialect: FormalDialect) -> [FormalHole] {
        let tokens = holeTokens(for: dialect)
        let lines = code.components(separatedBy: .newlines)

        return lines.enumerated().flatMap { index, line in
            tokens.compactMap { token in
                guard containsHole(token: token, in: line) else { return nil }
                return FormalHole(
                    line: index + 1,
                    token: token,
                    context: line.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    private static func holeTokens(for dialect: FormalDialect) -> [String] {
        switch dialect {
        case .lean:
            ["sorry", "admit", "?_", "by?"]
        case .coq:
            ["Admitted", "admit", "TODO"]
        case .isabelle:
            ["sorry", "oops", "?thesis"]
        case .latex:
            ["TODO", "???", "\\todo"]
        case .pseudocode, .swift, .python:
            ["TODO", "FIXME", "???"]
        }
    }

    private static func containsHole(token: String, in line: String) -> Bool {
        if token.allSatisfy({ $0.isLetter }) {
            return line.range(of: "\\b\(token)\\b", options: .regularExpression) != nil
        }
        return line.contains(token)
    }
}

enum LaTeXRenderer {
    static func render(_ input: String) -> String {
        var output = input
        guard !output.isEmpty else { return output }

        output = replaceFractions(in: output)
        output = replaceCommandWithOneArgument("mathbb", in: output) { content in
            blackboardSymbols[content] ?? render(content)
        }
        output = replaceCommandWithOneArgument("mathcal", in: output) { content in
            render(content)
        }
        output = replaceCommandWithOneArgument("mathrm", in: output) { content in
            render(content)
        }
        output = replaceCommandWithOneArgument("operatorname", in: output) { content in
            render(content)
        }
        output = replaceCommandWithOneArgument("bar", in: output) { content in
            "\(render(content))\u{0304}"
        }
        output = replaceCommandWithOneArgument("hat", in: output) { content in
            "\(render(content))\u{0302}"
        }

        for (command, symbol) in commandSymbols.sorted(by: { $0.command.count > $1.command.count }) {
            output = output.replacingOccurrences(of: "\\\(command)", with: symbol)
        }

        output = output.replacingOccurrences(of: "\\left", with: "")
        output = output.replacingOccurrences(of: "\\right", with: "")
        output = output.replacingOccurrences(of: "\\(", with: "")
        output = output.replacingOccurrences(of: "\\)", with: "")
        output = output.replacingOccurrences(of: "\\[", with: "")
        output = output.replacingOccurrences(of: "\\]", with: "")
        output = output.replacingOccurrences(of: "$$", with: "")
        output = output.replacingOccurrences(of: "$", with: "")
        output = output.replacingOccurrences(of: "\\,", with: " ")
        output = output.replacingOccurrences(of: "\\;", with: " ")
        output = output.replacingOccurrences(of: "\\:", with: " ")
        output = output.replacingOccurrences(of: "\\!", with: "")
        output = output.replacingOccurrences(of: "\\{", with: "{")
        output = output.replacingOccurrences(of: "\\}", with: "}")
        output = output.replacingOccurrences(of: "\\_", with: "_")
        output = output.replacingOccurrences(of: "\\%", with: "%")
        output = output.replacingOccurrences(of: "\\#", with: "#")
        output = output.replacingOccurrences(of: "\\&", with: "&")

        return renderScripts(in: output)
    }

    static func containsRenderableLaTeX(_ input: String) -> Bool {
        input.contains("\\")
            || input.contains("$")
            || input.range(of: #"[\^_]\{?[A-Za-z0-9+\-=()]"#, options: .regularExpression) != nil
    }

    private static func replaceFractions(in text: String) -> String {
        var result = text
        let marker = "\\frac"

        while let commandRange = result.range(of: marker) {
            var cursor = commandRange.upperBound
            skipWhitespace(in: result, from: &cursor)

            guard cursor < result.endIndex, result[cursor] == "{" else {
                result.replaceSubrange(commandRange, with: "")
                continue
            }

            guard let numeratorClose = matchingBrace(in: result, openingAt: cursor) else { break }
            let numeratorStart = result.index(after: cursor)
            let numerator = String(result[numeratorStart..<numeratorClose])
            cursor = result.index(after: numeratorClose)
            skipWhitespace(in: result, from: &cursor)

            guard cursor < result.endIndex, result[cursor] == "{" else { break }
            guard let denominatorClose = matchingBrace(in: result, openingAt: cursor) else { break }
            let denominatorStart = result.index(after: cursor)
            let denominator = String(result[denominatorStart..<denominatorClose])
            let replacement = "\(render(numerator))⁄\(render(denominator))"

            result.replaceSubrange(commandRange.lowerBound..<result.index(after: denominatorClose), with: replacement)
        }

        return result
    }

    private static func replaceCommandWithOneArgument(
        _ command: String,
        in text: String,
        transform: (String) -> String
    ) -> String {
        var result = text
        let marker = "\\\(command)"

        while let commandRange = result.range(of: marker) {
            var cursor = commandRange.upperBound
            skipWhitespace(in: result, from: &cursor)

            guard cursor < result.endIndex, result[cursor] == "{" else {
                result.replaceSubrange(commandRange, with: "")
                continue
            }

            guard let closingBrace = matchingBrace(in: result, openingAt: cursor) else { break }
            let contentStart = result.index(after: cursor)
            let content = String(result[contentStart..<closingBrace])
            result.replaceSubrange(commandRange.lowerBound..<result.index(after: closingBrace), with: transform(content))
        }

        return result
    }

    private static func renderScripts(in text: String) -> String {
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            guard character == "^" || character == "_" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }

            let superscript = character == "^"
            var cursor = text.index(after: index)

            guard cursor < text.endIndex else {
                result.append(character)
                index = cursor
                continue
            }

            let token: String
            if text[cursor] == "{", let closingBrace = matchingBrace(in: text, openingAt: cursor) {
                token = String(text[text.index(after: cursor)..<closingBrace])
                cursor = text.index(after: closingBrace)
            } else {
                token = String(text[cursor])
                cursor = text.index(after: cursor)
            }

            result += script(token, superscript: superscript)
            index = cursor
        }

        return result
    }

    private static func script(_ token: String, superscript: Bool) -> String {
        let rendered = render(token)
        let table = superscript ? superscriptCharacters : subscriptCharacters
        var result = ""

        for character in rendered {
            guard let mapped = table[character] else {
                return superscript ? "^{\(rendered)}" : "_{\(rendered)}"
            }
            result.append(mapped)
        }

        return result
    }

    private static func matchingBrace(in text: String, openingAt openingIndex: String.Index) -> String.Index? {
        var depth = 0
        var index = openingIndex

        while index < text.endIndex {
            if text[index] == "{" {
                depth += 1
            } else if text[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    private static func skipWhitespace(in text: String, from index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
    }

    private static let commandSymbols: [(command: String, symbol: String)] = [
        ("Rightarrow", "⇒"), ("Longrightarrow", "⟹"), ("rightarrow", "→"), ("to", "→"),
        ("Leftarrow", "⇐"), ("Longleftarrow", "⟸"), ("leftarrow", "←"),
        ("Leftrightarrow", "⇔"), ("Longleftrightarrow", "⟺"), ("leftrightarrow", "↔"),
        ("mapsto", "↦"), ("implies", "⇒"), ("iff", "⇔"),
        ("forall", "∀"), ("exists", "∃"), ("nexists", "∄"), ("neg", "¬"),
        ("land", "∧"), ("wedge", "∧"), ("lor", "∨"), ("vee", "∨"),
        ("cap", "∩"), ("cup", "∪"), ("setminus", "∖"), ("emptyset", "∅"), ("varnothing", "∅"),
        ("in", "∈"), ("notin", "∉"), ("ni", "∋"), ("subset", "⊂"), ("subseteq", "⊆"),
        ("supset", "⊃"), ("supseteq", "⊇"), ("leq", "≤"), ("le", "≤"), ("geq", "≥"), ("ge", "≥"),
        ("neq", "≠"), ("ne", "≠"), ("equiv", "≡"), ("sim", "∼"), ("simeq", "≃"), ("cong", "≅"),
        ("approx", "≈"), ("propto", "∝"), ("pm", "±"), ("mp", "∓"), ("times", "×"), ("cdot", "·"),
        ("circ", "∘"), ("oplus", "⊕"), ("otimes", "⊗"), ("sum", "∑"), ("prod", "∏"), ("int", "∫"),
        ("partial", "∂"), ("nabla", "∇"), ("infty", "∞"), ("aleph", "ℵ"), ("ell", "ℓ"),
        ("top", "⊤"), ("bot", "⊥"), ("vdash", "⊢"), ("models", "⊨"),
        ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("Gamma", "Γ"), ("delta", "δ"), ("Delta", "Δ"),
        ("epsilon", "ε"), ("varepsilon", "ε"), ("zeta", "ζ"), ("eta", "η"), ("theta", "θ"), ("Theta", "Θ"),
        ("lambda", "λ"), ("Lambda", "Λ"), ("mu", "μ"), ("nu", "ν"), ("xi", "ξ"), ("Xi", "Ξ"),
        ("pi", "π"), ("Pi", "Π"), ("rho", "ρ"), ("sigma", "σ"), ("Sigma", "Σ"), ("tau", "τ"),
        ("phi", "φ"), ("varphi", "φ"), ("Phi", "Φ"), ("chi", "χ"), ("psi", "ψ"), ("Psi", "Ψ"),
        ("omega", "ω"), ("Omega", "Ω")
    ]

    private static let blackboardSymbols: [String: String] = [
        "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽", "G": "𝔾",
        "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃", "M": "𝕄", "N": "ℕ",
        "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "S": "𝕊", "T": "𝕋", "U": "𝕌",
        "V": "𝕍", "W": "𝕎", "X": "𝕏", "Y": "𝕐", "Z": "ℤ"
    ]

    private static let superscriptCharacters: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷",
        "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ",
        "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ",
        "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ",
        "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ"
    ]

    private static let subscriptCharacters: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇",
        "8": "₈", "9": "₉", "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ",
        "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ",
        "u": "ᵤ", "v": "ᵥ", "x": "ₓ"
    ]
}
