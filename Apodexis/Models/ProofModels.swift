import Foundation
import SwiftUI

struct ProofProject: Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var branches: [ProofBranch]
    var nodes: [ProofNode]
    var edges: [ProofEdge]
    var updatedAt: Date = Date()
}

struct ProjectSummary: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var branchCount: Int
    var nodeCount: Int
    var updatedAt: Date
    var directoryPath: String?
    var graphFileName: String
    var storageFileName: String?
    var isManaged: Bool

    init(
        id: UUID,
        title: String,
        branchCount: Int,
        nodeCount: Int,
        updatedAt: Date,
        directoryPath: String?,
        graphFileName: String = "apodexis.json",
        storageFileName: String? = nil,
        isManaged: Bool = false
    ) {
        self.id = id
        self.title = title
        self.branchCount = branchCount
        self.nodeCount = nodeCount
        self.updatedAt = updatedAt
        self.directoryPath = directoryPath
        self.graphFileName = graphFileName
        self.storageFileName = storageFileName
        self.isManaged = isManaged
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case branchCount
        case nodeCount
        case updatedAt
        case directoryPath
        case graphFileName
        case storageFileName
        case isManaged
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        branchCount = try container.decode(Int.self, forKey: .branchCount)
        nodeCount = try container.decode(Int.self, forKey: .nodeCount)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        directoryPath = try container.decodeIfPresent(String.self, forKey: .directoryPath)
        graphFileName = try container.decodeIfPresent(String.self, forKey: .graphFileName) ?? "apodexis.json"
        storageFileName = try container.decodeIfPresent(String.self, forKey: .storageFileName)
        isManaged = try container.decodeIfPresent(Bool.self, forKey: .isManaged) ?? true
    }
}

struct ProjectFileItem: Identifiable, Hashable {
    let id: String
    let name: String
    let relativePath: String
    let url: URL
    let isDirectory: Bool
    let children: [ProjectFileItem]?
}

struct ProofBranch: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var summary: String
    var parentBranchID: UUID?
    var forkedFromNodeID: UUID?
    var status: BranchStatus
    var colorName: String
    var createdAt: Date = Date()
}

struct ProofNode: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var kind: NodeKind
    var statement: String
    var context: String
    var proofSketch: String
    var formalCode: String
    var formalDialect: FormalDialect
    var status: ProofStatus
    var verification: VerificationStatus
    var branchID: UUID
    var position: GraphPoint
    var assumptions: [String]
    var subgoals: [ProofSubgoal]
    var symbols: [SymbolEntry]
    var tags: [String]
    var sourceFile: String?
    var sourceLine: Int?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var hasOpenWork: Bool {
        status != .proven || subgoals.contains { $0.status != .proven }
    }
}

struct ProofSubgoal: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var detail: String
    var status: ProofStatus = .open
    var createdAt: Date = Date()
}

struct SymbolEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var symbol: String
    var meaning: String
    var scope: String
}

struct ProofEdge: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var sourceID: UUID
    var targetID: UUID
    var kind: EdgeKind
    var label: String
    var createdAt: Date = Date()
}

struct GraphPoint: Codable, Hashable, Equatable {
    var x: Double
    var y: Double
}

enum NodeKind: String, Codable, CaseIterable, Identifiable {
    case theorem
    case conjecture
    case definition
    case assumption
    case lemma
    case claim
    case proposal
    case strategy
    case conclusion
    case goal
    case reduction
    case caseSplit
    case inductionStep
    case construction
    case counterexample
    case failedAttempt
    case formalCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .theorem: "Theorem"
        case .conjecture: "Conjecture"
        case .definition: "Definition"
        case .assumption: "Assumption"
        case .lemma: "Lemma"
        case .claim: "Claim"
        case .proposal: "Proposal"
        case .strategy: "Strategy"
        case .conclusion: "Conclusion"
        case .goal: "Goal"
        case .reduction: "Reduction"
        case .caseSplit: "Case Split"
        case .inductionStep: "Induction Step"
        case .construction: "Construction"
        case .counterexample: "Counterexample"
        case .failedAttempt: "Failed Attempt"
        case .formalCode: "Formal Code"
        }
    }

    var systemImage: String {
        switch self {
        case .theorem: "seal"
        case .conjecture: "questionmark.diamond"
        case .definition: "text.book.closed"
        case .assumption: "exclamationmark.triangle"
        case .lemma: "function"
        case .claim: "checkmark.seal"
        case .proposal: "lightbulb"
        case .strategy: "signpost.right"
        case .conclusion: "flag.checkered"
        case .goal: "target"
        case .reduction: "arrow.down.right"
        case .caseSplit: "arrow.triangle.branch"
        case .inductionStep: "repeat"
        case .construction: "hammer"
        case .counterexample: "xmark.octagon"
        case .failedAttempt: "nosign"
        case .formalCode: "curlybraces"
        }
    }

    var tint: Color {
        switch self {
        case .theorem: .indigo
        case .conjecture: .yellow
        case .definition: .teal
        case .assumption: .orange
        case .lemma: .blue
        case .claim: .cyan
        case .proposal: .orange
        case .strategy: .purple
        case .conclusion: .green
        case .goal: .pink
        case .reduction: .mint
        case .caseSplit: .purple
        case .inductionStep: .green
        case .construction: .brown
        case .counterexample: .red
        case .failedAttempt: .gray
        case .formalCode: .black
        }
    }
}

extension NodeKind {
    /// A named group of node kinds, used to organize the "Add Node" menu so the
    /// 17 available types read as a few clear choices rather than one long list.
    struct MenuGroup: Identifiable {
        let title: String
        let kinds: [NodeKind]
        var id: String { title }
    }

    static let menuGroups: [MenuGroup] = [
        MenuGroup(title: "Results & Statements", kinds: [.theorem, .lemma, .claim, .conjecture, .definition, .assumption]),
        MenuGroup(title: "Goals & Strategy", kinds: [.goal, .proposal, .strategy, .conclusion]),
        MenuGroup(title: "Proof Moves", kinds: [.reduction, .caseSplit, .inductionStep, .construction]),
        MenuGroup(title: "Exploration", kinds: [.counterexample, .failedAttempt]),
        MenuGroup(title: "Formal", kinds: [.formalCode])
    ]
}

enum EdgeKind: String, Codable, CaseIterable, Identifiable {
    case uses
    case implies
    case reducesTo
    case equivalentTo
    case caseOf
    case generalizes
    case contradicts
    case dependsOnAssumption
    case forksFrom
    case refines
    case supports
    case requires
    case motivates
    case blocks
    case diagnoses
    case witnesses
    case constrains
    case summarizes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uses: "uses"
        case .implies: "implies"
        case .reducesTo: "reduces to"
        case .equivalentTo: "equivalent to"
        case .caseOf: "case of"
        case .generalizes: "generalizes"
        case .contradicts: "contradicts"
        case .dependsOnAssumption: "depends on assumption"
        case .forksFrom: "forks from"
        case .refines: "refines"
        case .supports: "supports"
        case .requires: "requires"
        case .motivates: "motivates"
        case .blocks: "blocks"
        case .diagnoses: "diagnoses"
        case .witnesses: "witnesses"
        case .constrains: "constrains"
        case .summarizes: "summarizes"
        }
    }

    var tint: Color {
        switch self {
        case .uses: .blue
        case .implies: .green
        case .reducesTo: .mint
        case .equivalentTo: .teal
        case .caseOf: .purple
        case .generalizes: .indigo
        case .contradicts: .red
        case .dependsOnAssumption: .orange
        case .forksFrom: .pink
        case .refines: .cyan
        case .supports: .green
        case .requires: .orange
        case .motivates: .purple
        case .blocks: .red
        case .diagnoses: .red
        case .witnesses: .teal
        case .constrains: .indigo
        case .summarizes: .gray
        }
    }

    /// Dash pattern for the connector. Empty = solid (core logical dependencies);
    /// long dashes = branching/negative relations; short dots = soft/supportive.
    var dashPattern: [CGFloat] {
        switch self {
        case .forksFrom, .contradicts, .blocks, .diagnoses: [7, 5]
        case .supports, .motivates, .summarizes: [2, 5]
        default: []
        }
    }

    /// Symmetric relations draw an arrowhead on both ends.
    var isBidirectional: Bool { self == .equivalentTo }

    /// A glyph shown on the edge label so the relation reads at a glance.
    var glyph: String {
        switch self {
        case .uses: "link"
        case .implies: "arrow.right"
        case .reducesTo: "arrow.down.right"
        case .equivalentTo: "equal"
        case .caseOf: "square.split.2x1"
        case .generalizes: "arrow.up.backward.and.arrow.down.forward"
        case .contradicts: "bolt.trianglebadge.exclamationmark"
        case .dependsOnAssumption: "exclamationmark.triangle"
        case .forksFrom: "arrow.triangle.branch"
        case .refines: "scope"
        case .supports: "hand.thumbsup"
        case .requires: "checklist"
        case .motivates: "lightbulb"
        case .blocks: "hand.raised"
        case .diagnoses: "stethoscope"
        case .witnesses: "checkmark.seal"
        case .constrains: "lock"
        case .summarizes: "text.append"
        }
    }
}

enum ProofStatus: String, Codable, CaseIterable, Identifiable {
    case open
    case inProgress
    case blocked
    case needsReview
    case proven
    case failed
    case abandoned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Open"
        case .inProgress: "In Progress"
        case .blocked: "Blocked"
        case .needsReview: "Needs Review"
        case .proven: "Proven"
        case .failed: "Failed"
        case .abandoned: "Abandoned"
        }
    }

    var tint: Color {
        switch self {
        case .open: .orange
        case .inProgress: .blue
        case .blocked: .red
        case .needsReview: .purple
        case .proven: .green
        case .failed: .gray
        case .abandoned: .gray
        }
    }
}

enum VerificationStatus: String, Codable, CaseIterable, Identifiable {
    case unchecked
    case checked
    case partial
    case checking
    case verified
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unchecked: "Unchecked"
        case .checked: "Checked"
        case .partial: "Partial"
        case .checking: "Checking"
        case .verified: "Verified"
        case .failed: "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .unchecked: .gray
        case .checked: .green
        case .partial: .orange
        case .checking: .blue
        case .verified: .green
        case .failed: .red
        }
    }
}

enum BranchStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case blocked
    case stuck
    case abandoned
    case merged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "Active"
        case .blocked: "Blocked"
        case .stuck: "Stuck"
        case .abandoned: "Abandoned"
        case .merged: "Merged"
        }
    }
}

enum FormalDialect: String, Codable, CaseIterable, Identifiable {
    case latex
    case lean
    case coq
    case isabelle
    case pseudocode
    case swift
    case python

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latex: "LaTeX"
        case .lean: "Lean"
        case .coq: "Coq"
        case .isabelle: "Isabelle"
        case .pseudocode: "Pseudocode"
        case .swift: "Swift"
        case .python: "Python"
        }
    }
}

extension ProofProject {
    static func blank(title: String) -> ProofProject {
        let mainBranchID = UUID()
        return ProofProject(
            title: title,
            branches: [
                ProofBranch(
                    id: mainBranchID,
                    name: "Main",
                    summary: "Primary proof route.",
                    parentBranchID: nil,
                    forkedFromNodeID: nil,
                    status: .active,
                    colorName: "blue"
                )
            ],
            nodes: [],
            edges: []
        )
    }

    static func sample() -> ProofProject {
        let mainBranchID = UUID()
        let alternativeBranchID = UUID()
        let definitionID = UUID()
        let theoremID = UUID()
        let lemmaID = UUID()
        let caseSplitID = UUID()
        let formalID = UUID()
        let forkID = UUID()

        let mainBranch = ProofBranch(
            id: mainBranchID,
            name: "Main proof",
            summary: "Primary route for the current theorem.",
            parentBranchID: nil,
            forkedFromNodeID: nil,
            status: .active,
            colorName: "blue"
        )

        let alternativeBranch = ProofBranch(
            id: alternativeBranchID,
            name: "Compactness fork",
            summary: "Alternative route that tries to reduce the theorem to compactness.",
            parentBranchID: mainBranchID,
            forkedFromNodeID: theoremID,
            status: .stuck,
            colorName: "pink"
        )

        let definition = ProofNode(
            id: definitionID,
            title: "Finite satisfiability",
            kind: .definition,
            statement: "A set Γ of formulas is finitely satisfiable if every finite Δ ⊆ Γ has a model.",
            context: "Language L is fixed. Γ is a set of first-order formulas.",
            proofSketch: "",
            formalCode: "",
            formalDialect: .latex,
            status: .proven,
            verification: .unchecked,
            branchID: mainBranchID,
            position: GraphPoint(x: 210, y: 180),
            assumptions: ["L is first-order", "Γ is a set of L-formulas"],
            subgoals: [],
            symbols: [
                SymbolEntry(symbol: "Γ", meaning: "Set of formulas", scope: "Global"),
                SymbolEntry(symbol: "Δ", meaning: "Finite subset of Γ", scope: "Definition")
            ],
            tags: ["logic", "definition"]
        )

        let theorem = ProofNode(
            id: theoremID,
            title: "Compactness transfer theorem",
            kind: .theorem,
            statement: "If Γ is finitely satisfiable, then Γ is satisfiable.",
            context: "We work in a first-order language L. The proof may use ultraproducts or a syntactic completeness argument.",
            proofSketch: "Use finite satisfiability to build compatible finite models, then pass to a global model.",
            formalCode: """
            theorem compactness_transfer
              (Γ : Set Formula)
              (h : finitely_satisfiable Γ) :
              satisfiable Γ := by
              sorry
            """,
            formalDialect: .lean,
            status: .inProgress,
            verification: .partial,
            branchID: mainBranchID,
            position: GraphPoint(x: 690, y: 170),
            assumptions: ["Finite satisfiability of Γ"],
            subgoals: [
                ProofSubgoal(title: "Construct the index family", detail: "Choose finite subsets of Γ as the index set.", status: .proven),
                ProofSubgoal(title: "Build the limiting model", detail: "Use an ultraproduct or syntactic Henkin construction.", status: .open),
                ProofSubgoal(title: "Show every φ ∈ Γ holds", detail: "Track the finite condition through the construction.", status: .open)
            ],
            symbols: [
                SymbolEntry(symbol: "Γ", meaning: "Set of formulas", scope: "Theorem"),
                SymbolEntry(symbol: "h", meaning: "Proof that Γ is finitely satisfiable", scope: "Lean block")
            ],
            tags: ["model-theory", "compactness"]
        )

        let lemma = ProofNode(
            id: lemmaID,
            title: "Finite model compatibility",
            kind: .lemma,
            statement: "For any finite Δ ⊆ Γ, there exists a model MΔ satisfying every formula in Δ.",
            context: "Direct unpacking of finite satisfiability.",
            proofSketch: "Apply the definition of finite satisfiability to Δ.",
            formalCode: "",
            formalDialect: .latex,
            status: .needsReview,
            verification: .unchecked,
            branchID: mainBranchID,
            position: GraphPoint(x: 450, y: 420),
            assumptions: ["Δ ⊆ Γ", "Δ is finite"],
            subgoals: [
                ProofSubgoal(title: "Check notation scope", detail: "Make sure MΔ is not used outside the finite context.", status: .needsReview)
            ],
            symbols: [
                SymbolEntry(symbol: "MΔ", meaning: "A model satisfying Δ", scope: "Lemma")
            ],
            tags: ["lemma"]
        )

        let caseSplit = ProofNode(
            id: caseSplitID,
            title: "Choose construction route",
            kind: .caseSplit,
            statement: "Split into either an ultraproduct construction or a Henkin-completeness construction.",
            context: "Both routes should prove the same theorem, but they expose different dependencies.",
            proofSketch: "Route A uses ultrafilters. Route B uses consistency and completeness.",
            formalCode: "",
            formalDialect: .pseudocode,
            status: .open,
            verification: .unchecked,
            branchID: mainBranchID,
            position: GraphPoint(x: 920, y: 420),
            assumptions: [],
            subgoals: [
                ProofSubgoal(title: "Decide external theorem budget", detail: "Can the proof use the ultrafilter lemma?", status: .open)
            ],
            symbols: [],
            tags: ["strategy"]
        )

        let formal = ProofNode(
            id: formalID,
            title: "Lean formalization hole",
            kind: .formalCode,
            statement: "Track the current formal proof obligation created by the Lean sorry.",
            context: "This node mirrors the formal gap in the theorem block.",
            proofSketch: "",
            formalCode: """
            have h_model : satisfiable Γ := by
              admit
            exact h_model
            """,
            formalDialect: .lean,
            status: .open,
            verification: .partial,
            branchID: mainBranchID,
            position: GraphPoint(x: 1180, y: 210),
            assumptions: ["Lean environment contains Formula and satisfiable"],
            subgoals: [
                ProofSubgoal(title: "Replace admit with construction", detail: "Connect the formal code with the chosen proof route.", status: .open)
            ],
            symbols: [],
            tags: ["formal", "lean"]
        )

        let fork = ProofNode(
            id: forkID,
            title: "Reduce to compactness theorem",
            kind: .reduction,
            statement: "Try proving the target theorem by reducing it to the standard compactness theorem.",
            context: "This may be circular depending on how compactness is stated in the surrounding development.",
            proofSketch: "If the library compactness theorem has the exact statement, specialize it to Γ.",
            formalCode: "",
            formalDialect: .lean,
            status: .blocked,
            verification: .unchecked,
            branchID: alternativeBranchID,
            position: GraphPoint(x: 690, y: 680),
            assumptions: ["A library compactness theorem is available"],
            subgoals: [
                ProofSubgoal(title: "Check circularity", detail: "Verify whether the imported theorem is stronger than the target.", status: .blocked)
            ],
            symbols: [],
            tags: ["fork", "reduction"]
        )

        return ProofProject(
            title: "Apodexis Workspace",
            branches: [mainBranch, alternativeBranch],
            nodes: [definition, theorem, lemma, caseSplit, formal, fork],
            edges: [
                ProofEdge(sourceID: definitionID, targetID: lemmaID, kind: .uses, label: ""),
                ProofEdge(sourceID: lemmaID, targetID: theoremID, kind: .implies, label: ""),
                ProofEdge(sourceID: theoremID, targetID: caseSplitID, kind: .reducesTo, label: ""),
                ProofEdge(sourceID: caseSplitID, targetID: formalID, kind: .refines, label: ""),
                ProofEdge(sourceID: theoremID, targetID: forkID, kind: .forksFrom, label: "alternative")
            ]
        )
    }
}
