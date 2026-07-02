import SwiftUI

@main
struct ApodexisApp: App {
    @StateObject private var store: ProofStore
    @StateObject private var assistant: AssistantViewModel

    init() {
        let store = ProofStore()
        _store = StateObject(wrappedValue: store)
        _assistant = StateObject(wrappedValue: AssistantViewModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(assistant)
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        #endif
        .commands {
            CommandGroup(replacing: .undoRedo) {
                UndoRedoCommands(store: store)
            }
        }
    }
}

/// Wires the app's model-level undo/redo into the standard Edit menu so ⌘Z / ⌘⇧Z
/// behave the way people expect, with the menu items enabling only when there is
/// something to undo or redo.
private struct UndoRedoCommands: View {
    @ObservedObject var store: ProofStore

    var body: some View {
        Button("Undo") { store.undo() }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!store.canUndo)

        Button("Redo") { store.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!store.canRedo)
    }
}
