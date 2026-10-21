import SwiftUI
import AppKit

@main
struct MacTVApp: App {
    @State private var model = MacTVModel()

    var body: some Scene {
        Window("MacTV", id: "home") {
            ContentView(model: model)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("MacTV") {
                Button("Home") { model.handle(.home) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Movies") { model.openMovies() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Settings") { model.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Toggle Fullscreen") { model.window?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [.command, .control])
            }
        }
        MenuBarExtra("MacTV", systemImage: "tv") {
            MacTVMenu(model: model)
        }
    }
}

struct MacTVMenu: View {
    let model: MacTVModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Bring MacTV Home") {
            openWindow(id: "home")
            model.handle(.home)
        }
        Button("Settings") {
            openWindow(id: "home")
            model.handle(.home)
            model.openSettings()
        }
        Divider()
        Button("Quit MacTV") { NSApp.terminate(nil) }
    }
}
