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

