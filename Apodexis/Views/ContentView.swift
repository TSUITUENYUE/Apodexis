import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: ProofStore
    @State private var showingExport = false
    @State private var showingImport = false
    @State private var showingOpenFolder = false
    @State private var importError: ImportErrorMessage?

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
                    onOpenFolder: { showingOpenFolder = true },
                    onImport: { showingImport = true }
                )
                .navigationTitle("Apodexis")
            }
        } detail: {
            if store.hasOpenProject {
                InspectorView()
            } else {
                ContentUnavailableView("No Project Open", systemImage: "folder")
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.createProject()
                } label: {
                    Label("New Project", systemImage: "folder.badge.plus")
                }

                Menu {
                    ForEach(NodeKind.allCases) { kind in
                        Button {
                            store.addNode(kind: kind)
                        } label: {
                            Label(kind.title, systemImage: kind.systemImage)
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

                Button {
                    store.toggleEdgeCreation()
                } label: {
                    Label("Add Line", systemImage: store.edgeCreationMode ? "link.badge.plus" : "link")
                }
                .disabled(!store.hasOpenProject)

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
                .disabled(!store.hasOpenProject)

                Button {
                    store.autoLayoutSelectedBranch()
                } label: {
                    Label("Auto Layout", systemImage: "rectangle.connected.to.line.below")
                }
                .disabled(!store.hasOpenProject)

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

                Button {
                    showingExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!store.hasOpenProject)
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
}

private struct WelcomeView: View {
    let onCreate: (String) -> Void
    let onOpenFolder: () -> Void
    let onImport: () -> Void
    @State private var projectTitle = "Untitled Proof Project"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Apodexis")
                    .font(.largeTitle.weight(.semibold))
                Text("Project Workspace")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TextField("Project title", text: $projectTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                Button {
                    onCreate(projectTitle)
                } label: {
                    Label("Create", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 12) {
                Button {
                    onOpenFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onImport()
                } label: {
                    Label("Import JSON", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
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
