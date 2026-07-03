import Foundation
import SwiftUI

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

/// Lightweight LaTeX math renderer. It typesets a large subset of LaTeX math to
/// Unicode + `AttributedString` (real super/subscripts, roots, symbols, accents)
/// natively — no web view. It cannot do full 2D layout (stacked fractions render
/// inline as `a/b`); that would need a dedicated engine such as SwiftMath.
enum LaTeXRenderer {
    // Private-use placeholders that survive substitution: literal { } _ and $.
    private static let openBrace = "\u{E000}"
    private static let closeBrace = "\u{E001}"
    private static let literalUnderscore = "\u{E006}"

    // MARK: - Public

    /// Rich rendering for display in `Text`.
    static func render(_ input: String) -> AttributedString {
        guard !input.isEmpty else { return AttributedString(input) }
        return buildScripts(from: expand(input))
    }

    /// Plain-text rendering for string contexts (labels, exports).
    static func plain(_ input: String) -> String {
        String(render(input).characters)
    }

    static func containsRenderableLaTeX(_ input: String) -> Bool {
        input.contains("\\")
            || input.contains("$")
            || input.range(of: #"[\^_]\{?[A-Za-z0-9+\-=()]"#, options: .regularExpression) != nil
    }

    // MARK: - Phase 1: expand LaTeX into a Unicode string (keeps ^ / _ markers)

    private static func expand(_ input: String) -> String {
        var s = input

        // Protect escaped characters so they are not treated as markup.
        s = s.replacingOccurrences(of: "\\{", with: openBrace)
        s = s.replacingOccurrences(of: "\\}", with: closeBrace)
        s = s.replacingOccurrences(of: "\\_", with: literalUnderscore)
        s = s.replacingOccurrences(of: "\\%", with: "\u{E003}")
        s = s.replacingOccurrences(of: "\\#", with: "\u{E004}")
        s = s.replacingOccurrences(of: "\\&", with: "\u{E005}")
        s = s.replacingOccurrences(of: "\\$", with: "\u{E007}")

        // Commands that take braced arguments (recursive).
        s = replaceFractions(in: s)
        s = replaceRoots(in: s)
        s = replaceBinom(in: s)
        s = replaceAccent("overline", combining: "\u{0305}", in: s)
        s = replaceAccent("underline", combining: "\u{0332}", in: s)
        s = replaceAccent("overrightarrow", combining: "\u{20D7}", in: s)
        s = replaceAccent("vec", combining: "\u{20D7}", in: s)
        s = replaceAccent("bar", combining: "\u{0304}", in: s)
        s = replaceAccent("widehat", combining: "\u{0302}", in: s)
        s = replaceAccent("hat", combining: "\u{0302}", in: s)
        s = replaceAccent("widetilde", combining: "\u{0303}", in: s)
        s = replaceAccent("tilde", combining: "\u{0303}", in: s)
        s = replaceAccent("ddot", combining: "\u{0308}", in: s)
        s = replaceAccent("dot", combining: "\u{0307}", in: s)
        s = replaceArg("mathbb", in: s) { blackboard(expand($0)) }
        for command in ["mathcal", "mathscr", "mathfrak", "mathrm", "mathsf", "mathbf",
                        "boldsymbol", "operatorname", "text", "textrm", "textbf", "textit",
                        "textsf", "texttt", "mbox", "emph"] {
            s = replaceArg(command, in: s) { expand($0) }
        }
        s = replaceArg("pmod", in: s) { "(mod \(expand($0)))" }

        // Environments: drop \begin{..}/\end{..}; rows -> "; ", columns -> " ".
        s = stripEnvironments(in: s)
        s = s.replacingOccurrences(of: "\\\\", with: "; ")
        s = s.replacingOccurrences(of: "&", with: " ")

        // Symbols, operators, spacing, and leftover delimiters.
        s = scanCommands(s)

        s = s.replacingOccurrences(of: "$$", with: "")
        s = s.replacingOccurrences(of: "$", with: "")

        // Restore escapes that are safe now (braces / underscore stay for phase 2).
        s = s.replacingOccurrences(of: "\u{E003}", with: "%")
        s = s.replacingOccurrences(of: "\u{E004}", with: "#")
        s = s.replacingOccurrences(of: "\u{E005}", with: "&")
        s = s.replacingOccurrences(of: "\u{E007}", with: "$")
        return s
    }

    /// Reads `\command` names maximally so prefixes never collide (`\le` vs `\left`).
    private static func scanCommands(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "\\" else { out.append(c); i += 1; continue }

            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if next.isLetter {
                var name = ""
                var j = i + 1
                while j < chars.count, chars[j].isLetter { name.append(chars[j]); j += 1 }
                i = j
                if let symbol = symbolTable[name] {
                    out += symbol
                } else if nullCommands.contains(name) {
                    continue          // size/style modifiers render nothing
                } else if spacingNames.contains(name) {
                    out += " "
                } else if operatorNames.contains(name) {
                    out += name
                } else {
                    out += name       // unknown command: show its name
                }
            } else {
                switch next {
                case ",", ";", ":", " ": out += " "
                case "!": break
                case "(", ")", "[", "]": break
                case "|": out += "‖"
                default: out.append(next)
                }
                i += 2
            }
        }
        return out
    }

    // MARK: - Phase 2: super/subscripts -> AttributedString

    private static func buildScripts(from text: String) -> AttributedString {
        var result = AttributedString("")
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { result.append(AttributedString(buffer)); buffer = "" }
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "^" || c == "_" {
                let superscript = (c == "^")
                i += 1
                guard i < chars.count else { buffer.append(c); break }

                var token = ""
                if chars[i] == "{" {
                    var depth = 0
                    var j = i
                    while j < chars.count {
                        if chars[j] == "{" { depth += 1 }
                        else if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                        j += 1
                    }
                    if j < chars.count {
                        token = String(chars[(i + 1)..<j]); i = j + 1
                    } else {
                        token = String(chars[i]); i += 1
                    }
                } else {
                    token = String(chars[i]); i += 1
                }

                if let mapped = unicodeScript(token, superscript: superscript) {
                    buffer += mapped
                } else {
                    flush()
                    var part = AttributedString(token)
                    part.baselineOffset = superscript ? 4 : -3.5
                    result.append(part)
                }
            } else if c == "{" || c == "}" {
                i += 1   // drop grouping braces
            } else if c == openBrace.first! {
                buffer.append("{"); i += 1
            } else if c == closeBrace.first! {
                buffer.append("}"); i += 1
            } else if c == literalUnderscore.first! {
                buffer.append("_"); i += 1
            } else {
                buffer.append(c); i += 1
            }
        }
        flush()
        return result
    }

    private static func unicodeScript(_ token: String, superscript: Bool) -> String? {
        guard !token.isEmpty else { return nil }
        let table = superscript ? superscriptCharacters : subscriptCharacters
        var mapped = ""
        for character in token {
            guard let value = table[character] else { return nil }
            mapped.append(value)
        }
        return mapped
    }

    /// String-only resolution of ^ / _ to Unicode (for content inside roots and
    /// accents, where the 2D AttributedString path is not available).
    private static func flattenScripts(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "^" || c == "_" {
                let superscript = (c == "^")
                i += 1
                guard i < chars.count else { out.append(c); break }
                var token = ""
                if chars[i] == "{" {
                    var depth = 0
                    var j = i
                    while j < chars.count {
                        if chars[j] == "{" { depth += 1 }
                        else if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                        j += 1
                    }
                    if j < chars.count { token = String(chars[(i + 1)..<j]); i = j + 1 }
                    else { token = String(chars[i]); i += 1 }
                } else {
                    token = String(chars[i]); i += 1
                }
                out += unicodeScript(token, superscript: superscript) ?? token
            } else if c == "{" || c == "}" {
                i += 1
            } else if c == openBrace.first! {
                out.append("{"); i += 1
            } else if c == closeBrace.first! {
                out.append("}"); i += 1
            } else if c == literalUnderscore.first! {
                out.append("_"); i += 1
            } else {
                out.append(c); i += 1
            }
        }
        return out
    }

    // MARK: - Braced-argument commands

    private static func replaceFractions(in text: String) -> String {
        var result = text
        while let range = result.range(of: "\\frac") {
            var cursor = range.upperBound
            skipWhitespace(in: result, from: &cursor)
            guard cursor < result.endIndex, result[cursor] == "{",
                  let numeratorClose = matchingBrace(in: result, openingAt: cursor) else {
                result.replaceSubrange(range, with: "")
                continue
            }
            let numerator = String(result[result.index(after: cursor)..<numeratorClose])
            cursor = result.index(after: numeratorClose)
            skipWhitespace(in: result, from: &cursor)
            guard cursor < result.endIndex, result[cursor] == "{",
                  let denominatorClose = matchingBrace(in: result, openingAt: cursor) else { break }
            let denominator = String(result[result.index(after: cursor)..<denominatorClose])
            let replacement = "\(parenthesized(expand(numerator)))⁄\(parenthesized(expand(denominator)))"
            result.replaceSubrange(range.lowerBound..<result.index(after: denominatorClose), with: replacement)
        }
        return result
    }

    private static func replaceBinom(in text: String) -> String {
        var result = text
        while let range = result.range(of: "\\binom") {
            var cursor = range.upperBound
            skipWhitespace(in: result, from: &cursor)
            guard cursor < result.endIndex, result[cursor] == "{",
                  let topClose = matchingBrace(in: result, openingAt: cursor) else {
                result.replaceSubrange(range, with: ""); continue
            }
            let top = String(result[result.index(after: cursor)..<topClose])
            cursor = result.index(after: topClose)
            skipWhitespace(in: result, from: &cursor)
            guard cursor < result.endIndex, result[cursor] == "{",
                  let bottomClose = matchingBrace(in: result, openingAt: cursor) else { break }
            let bottom = String(result[result.index(after: cursor)..<bottomClose])
            let replacement = "(\(expand(top)) \(expand(bottom)))"
            result.replaceSubrange(range.lowerBound..<result.index(after: bottomClose), with: replacement)
        }
        return result
    }

    private static func replaceRoots(in text: String) -> String {
        var result = text
        while let range = result.range(of: "\\sqrt") {
            var cursor = range.upperBound
            var prefix = ""
            skipWhitespace(in: result, from: &cursor)
            if cursor < result.endIndex, result[cursor] == "[",
               let close = result[cursor...].firstIndex(of: "]") {
                let index = String(result[result.index(after: cursor)..<close])
                prefix = superscriptString(expand(index))
                cursor = result.index(after: close)
                skipWhitespace(in: result, from: &cursor)
            }
            let content: String
            let end: String.Index
            if cursor < result.endIndex, result[cursor] == "{",
               let close = matchingBrace(in: result, openingAt: cursor) {
                content = String(result[result.index(after: cursor)..<close])
                end = result.index(after: close)
            } else if cursor < result.endIndex {
                content = String(result[cursor])
                end = result.index(after: cursor)
            } else {
                content = ""
                end = cursor
            }
            let replacement = "\(prefix)√\(overline(flattenScripts(expand(content))))"
            result.replaceSubrange(range.lowerBound..<end, with: replacement)
        }
        return result
    }

    private static func replaceAccent(_ command: String, combining: String, in text: String) -> String {
        replaceArg(command, in: text) { content in
            let expanded = flattenScripts(expand(content))
            var out = ""
            for character in expanded { out.append(character); out += combining }
            return out
        }
    }

    private static func replaceArg(_ command: String, in text: String, transform: (String) -> String) -> String {
        var result = text
        let marker = "\\\(command)"
        // Track the search position as an offset: string indices are invalidated by
        // replaceSubrange, so we recompute the index from the offset each iteration.
        var offset = 0
        while true {
            guard offset <= result.count else { break }
            let start = result.index(result.startIndex, offsetBy: offset)
            guard let range = result.range(of: marker, range: start..<result.endIndex) else { break }

            // Skip if this is a prefix of a longer command (e.g. \text vs \textbf).
            if range.upperBound < result.endIndex, result[range.upperBound].isLetter {
                offset = result.distance(from: result.startIndex, to: range.upperBound)
                continue
            }

            let lowerOffset = result.distance(from: result.startIndex, to: range.lowerBound)
            var cursor = range.upperBound
            skipWhitespace(in: result, from: &cursor)
            guard cursor < result.endIndex, result[cursor] == "{",
                  let close = matchingBrace(in: result, openingAt: cursor) else {
                result.replaceSubrange(range, with: "")
                offset = lowerOffset
                continue
            }
            let content = String(result[result.index(after: cursor)..<close])
            result.replaceSubrange(range.lowerBound..<result.index(after: close), with: transform(content))
            offset = lowerOffset
        }
        return result
    }

    private static func stripEnvironments(in text: String) -> String {
        var result = text
        for command in ["begin", "end"] {
            result = replaceArg(command, in: result) { _ in "" }
        }
        return result
    }

    // MARK: - Helpers

    private static func parenthesized(_ text: String) -> String {
        let needsParens = text.contains(where: { "+-±∓ ".contains($0) })
        return needsParens ? "(\(text))" : text
    }

    private static func overline(_ text: String) -> String {
        var out = ""
        for character in text { out.append(character); out += "\u{0305}" }
        return out
    }

    private static func superscriptString(_ text: String) -> String {
        var out = ""
        for character in text { out.append(superscriptCharacters[character] ?? character) }
        return out
    }

    private static func blackboard(_ text: String) -> String {
        var out = ""
        for character in text { out += blackboardSymbols[String(character)] ?? String(character) }
        return out
    }

    private static func matchingBrace(in text: String, openingAt openingIndex: String.Index) -> String.Index? {
        var depth = 0
        var index = openingIndex
        while index < text.endIndex {
            if text[index] == "{" {
                depth += 1
            } else if text[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
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

    // MARK: - Tables

    private static let operatorNames: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "coth", "exp", "log", "ln", "lg", "lim", "limsup",
        "liminf", "max", "min", "sup", "inf", "arg", "deg", "det", "dim", "ker",
        "hom", "gcd", "lcm", "Pr"
    ]

    private static let spacingNames: Set<String> = [
        "quad", "qquad", "thinspace", "medspace", "thickspace", "enspace", "negthinspace"
    ]

    /// Delimiter-size and style modifiers that render nothing themselves.
    private static let nullCommands: Set<String> = [
        "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
        "biggl", "biggr", "Biggl", "Biggr", "displaystyle", "textstyle", "scriptstyle",
        "scriptscriptstyle", "limits", "nolimits", "mathstrut"
    ]

    private static let symbolTable: [String: String] = [
        // Arrows
        "rightarrow": "→", "to": "→", "longrightarrow": "⟶", "Rightarrow": "⇒",
        "Longrightarrow": "⟹", "implies": "⇒", "leftarrow": "←", "gets": "←",
        "longleftarrow": "⟵", "Leftarrow": "⇐", "Longleftarrow": "⟸",
        "leftrightarrow": "↔", "Leftrightarrow": "⇔", "longleftrightarrow": "⟷",
        "Longleftrightarrow": "⟺", "iff": "⇔", "mapsto": "↦", "longmapsto": "⟼",
        "hookrightarrow": "↪", "hookleftarrow": "↩", "uparrow": "↑", "downarrow": "↓",
        "updownarrow": "↕", "Uparrow": "⇑", "Downarrow": "⇓", "nearrow": "↗",
        "searrow": "↘", "swarrow": "↙", "nwarrow": "↖", "nrightarrow": "↛",
        "rightrightarrows": "⇉", "twoheadrightarrow": "↠",
        // Logic
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬",
        "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨", "top": "⊤", "bot": "⊥",
        "vdash": "⊢", "dashv": "⊣", "models": "⊨", "vDash": "⊨", "nvdash": "⊬",
        "therefore": "∴", "because": "∵",
        // Sets
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆",
        "subsetneq": "⊊", "supset": "⊃", "supseteq": "⊇", "supsetneq": "⊋",
        "cap": "∩", "cup": "∪", "bigcap": "⋂", "bigcup": "⋃", "setminus": "∖",
        "emptyset": "∅", "varnothing": "∅", "sqsubseteq": "⊑", "sqsupseteq": "⊒",
        "sqcap": "⊓", "sqcup": "⊔", "uplus": "⊎", "complement": "∁",
        // Relations
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "approx": "≈",
        "asymp": "≍", "propto": "∝", "doteq": "≐", "prec": "≺", "succ": "≻",
        "preceq": "⪯", "succeq": "⪰", "ll": "≪", "gg": "≫", "leqslant": "⩽",
        "geqslant": "⩾", "lesssim": "≲", "gtrsim": "≳", "mid": "∣", "nmid": "∤",
        "parallel": "∥", "perp": "⊥", "angle": "∠", "measuredangle": "∡",
        // Binary operators
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "·", "ast": "∗",
        "star": "⋆", "circ": "∘", "bullet": "•", "oplus": "⊕", "ominus": "⊖",
        "otimes": "⊗", "oslash": "⊘", "odot": "⊙", "boxplus": "⊞", "boxtimes": "⊠",
        "dagger": "†", "ddagger": "‡", "amalg": "⨿", "diamond": "⋄",
        "triangleleft": "◁", "triangleright": "▷", "bigtriangleup": "△",
        "bigtriangledown": "▽", "ltimes": "⋉", "rtimes": "⋊", "bowtie": "⋈",
        // Big operators
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬",
        "iiint": "∭", "oint": "∮", "bigoplus": "⨁", "bigotimes": "⨂",
        "bigodot": "⨀", "bigvee": "⋁", "bigwedge": "⋀", "bigsqcup": "⨆",
        // Misc symbols
        "partial": "∂", "nabla": "∇", "infty": "∞", "aleph": "ℵ", "beth": "ℶ",
        "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "wp": "℘", "prime": "′",
        "backslash": "∖", "surd": "√", "flat": "♭", "sharp": "♯", "natural": "♮",
        "checkmark": "✓", "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮",
        "ddots": "⋱", "colon": ":", "bmod": "mod", "mod": "mod",
        "square": "□", "Box": "□", "blacksquare": "▪", "triangle": "△",
        "lozenge": "◊", "bigstar": "★", "S": "§", "P": "¶", "copyright": "©",
        // Delimiters
        "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "langle": "⟨",
        "rangle": "⟩", "lbrace": "{", "rbrace": "}", "vert": "|", "Vert": "‖",
        "lVert": "‖", "rVert": "‖", "lvert": "|", "rvert": "|",
        // Greek (lowercase)
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "varkappa": "ϰ", "lambda": "λ", "mu": "μ",
        "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ",
        "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "digamma": "ϝ",
        // Greek (uppercase)
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω"
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
