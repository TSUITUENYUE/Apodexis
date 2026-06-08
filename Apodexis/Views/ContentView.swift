import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: ProofStore
    @State private var showingExport = false
    @State private var showingImport = false
    @State private var importError: ImportErrorMessage?

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationTitle("Apodexis")
        } content: {
            GraphWorkspaceView()
                .navigationTitle(store.selectedBranch?.name ?? store.project.title)
        } detail: {
            InspectorView()
        }
        .toolbar {
            ToolbarItemGroup {
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

                Button {
                    store.createBranchFromSelected()
                } label: {
                    Label("Fork", systemImage: "arrow.triangle.branch")
                }
                .disabled(store.selectedNode == nil)

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

private struct ImportErrorMessage: Identifiable {
    let id = UUID()
    let message: String
}

#Preview {
    ContentView()
        .environmentObject(ProofStore())
}
