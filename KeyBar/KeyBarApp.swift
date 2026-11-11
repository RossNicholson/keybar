import SwiftUI

@main
struct KeyBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The window and the menu bar item are managed by AppDelegate, so
        // KeyBar keeps running in the menu bar with its window closed.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Add Key…") { appDelegate.show(.keys, adding: true) }
                        .keyboardShortcut("n", modifiers: .command)
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.show(.settings) }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandMenu("Go") {
                    ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                        Button(section.title) { appDelegate.show(section) }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }
            }
    }
}
