import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: ProofStore
    @State private var showingExport = false
    @State private var showingImport = false
    @State private var showingOpenFolder = false
    @State private var showAssistant = false
    @State private var importError: ImportErrorMessage?
    @AppStorage("apodexis.workspaceMode") private var mode: WorkspaceMode = .ai

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationTitle("Apodexis")
        } content: {
            if store.hasOpenProject {
                GraphWorkspaceView()
                    .navigationTitle(store.selectedBranch?.name ?? store.project.title)
            } else {
                WelcomeView(
                    onCreate: { store.createProject(title: $0) },
                    onTrySample: { store.createSampleProject() },
                    onOpenFolder: { showingOpenFolder = true },
                    onImport: { showingImport = true }
                )
                .navigationTitle("Apodexis")
            }
        } detail: {
            if store.hasOpenProject {
                switch mode {
                case .ai:
                    AssistantView()
                case .pro:
                    InspectorView()
                }
            } else {
                ContentUnavailableView {
                    Label("No Project Open", systemImage: "folder")
                } description: {
                    Text("Create or open a project to start mapping a proof.")
                }
            }
        }
        .inspector(isPresented: assistantInspectorPresented) {
            AssistantView()
                .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Mode", selection: $mode) {
                    ForEach(WorkspaceMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("AI mode keeps just the assistant. Pro mode reveals the full inspector and editing tools.")

                Button {
                    store.createProject()
                } label: {
                    Label("New Project", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("n", modifiers: .command)

                if mode == .pro {
                    Menu {
                        ForEach(NodeKind.menuGroups) { group in
                            Section(group.title) {
                                ForEach(group.kinds) { kind in
                                    Button {
                                        store.addNode(kind: kind)
                                    } label: {
                                        Label(kind.title, systemImage: kind.systemImage)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Add Node", systemImage: "plus")
                    }
                    .disabled(!store.hasOpenProject)

                    Button {
                        store.createBranchFromSelected()
                    } label: {
                        Label("Fork", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(store.selectedNode == nil || !store.hasOpenProject)

                    Menu {
                        ForEach(EdgeKind.allCases) { kind in
                            Button {
                                store.edgeDraftKind = kind
                            } label: {
                                Label(kind.title, systemImage: kind == store.edgeDraftKind ? "checkmark" : "arrow.right")
                            }
                        }
                    } label: {
                        Label(store.edgeDraftKind.title, systemImage: "line.diagonal")
                    }
                    .help("Relation used when you drag from a node's connector handle")
                    .disabled(!store.hasOpenProject)

                    Button {
                        store.autoLayoutSelectedBranch()
                    } label: {
                        Label("Auto Layout", systemImage: "rectangle.connected.to.line.below")
                    }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(!store.hasOpenProject)
                }

                Button {
                    showingOpenFolder = true
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }

                Button {
                    showingImport = true
                } label: {
                    Label("Import JSON", systemImage: "square.and.arrow.down")
                }

                if mode == .pro {
                    Button {
                        showingExport = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!store.hasOpenProject)

                    Button {
                        showAssistant.toggle()
                    } label: {
                        Label("Assistant", systemImage: "sparkles")
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .help("Ask the AI assistant to build or edit this graph")
                }
            }
        }
        .fileImporter(
            isPresented: $showingImport,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                try store.importProject(from: url)
            } catch {
                importError = ImportErrorMessage(message: error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $showingOpenFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                try store.openProjectDirectory(from: url)
            } catch {
                importError = ImportErrorMessage(message: error.localizedDescription)
            }
        }
        .alert("Import Failed", isPresented: importErrorPresented) {
            Button("OK", role: .cancel) {
                importError = nil
            }
        } message: {
            Text(importError?.message ?? "Unknown import error.")
        }
        .sheet(isPresented: $showingExport) {
            ExportView(markdown: store.markdownExport())
        }
    }

    private var importErrorPresented: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )
    }

    /// The assistant is a toggleable side panel only in Pro mode; in AI mode it is
    /// already the main detail column, so the extra inspector stays hidden.
    private var assistantInspectorPresented: Binding<Bool> {
        Binding(
            get: { showAssistant && mode == .pro },
            set: { showAssistant = $0 }
        )
    }
}

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case ai
    case pro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai: "AI"
        case .pro: "Pro"
        }
    }
}

private struct WelcomeView: View {
    let onCreate: (String) -> Void
    let onTrySample: () -> Void
    let onOpenFolder: () -> Void
    let onImport: () -> Void
    @State private var projectTitle = "Untitled Proof Project"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Welcome to Apodexis")
                    .font(.largeTitle.weight(.semibold))
                Text("A calm place to think through long proofs — lay out theorems, lemmas, and cases as a graph, and keep track of what's proven and what's still open.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name your project")
                    .font(.headline)
                HStack(spacing: 10) {
                    TextField("Project title", text: $projectTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onSubmit { onCreate(projectTitle) }

                    Button {
                        onCreate(projectTitle)
                    } label: {
                        Label("Create Project", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(projectTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Just exploring?")
                    .font(.headline)
                Button {
                    onTrySample()
                } label: {
                    Label("Try a sample proof", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                Text("Opens a worked example — a compactness-transfer theorem with a fork, subgoals, and a Lean hole — so you can see the workflow before starting your own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Already have work?")
                    .font(.headline)
                HStack(spacing: 12) {
                    Button {
                        onOpenFolder()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onImport()
                    } label: {
                        Label("Import JSON", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(42)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ImportErrorMessage: Identifiable {
    let id = UUID()
    let message: String
}

#Preview {
    ContentView()
        .environmentObject(ProofStore())
}
