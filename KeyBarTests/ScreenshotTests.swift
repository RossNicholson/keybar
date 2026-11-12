import XCTest
import SwiftUI
@testable import KeyBar

/// Renders the panel and the window's screens with the demo keys, for the
/// README and website and for checking the design. Skipped unless SCREENSHOTS
/// names an output folder: `make screenshots`. `make icon` draws the app icon.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var out: URL!

    private func outputFolder(_ variable: String) throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment[variable], !dir.isEmpty else {
            throw XCTSkip("Set \(variable) to render")
        }
        let url = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRenderPanel() async throws {
        out = try outputFolder("SCREENSHOTS")
        for dark in [false, true] {
            let state = Demo.state()
            try Snapshot.panel(dark: dark, to: out.appendingPathComponent("panel\(dark ? "-dark" : "-light").png")) {
                MenuBarPanel(close: {}).environment(state)
            }
        }
        let revealed = Demo.state()
        await revealed.reveal("CLOUDFLARE_API_TOKEN")
        try Snapshot.panel(to: out.appendingPathComponent("panel-revealed.png")) {
            MenuBarPanel(close: {}).environment(revealed)
        }
        let empty = AppState(store: SecretStore(vault: MemoryVault(), indexURL: nil), log: ActivityLog(url: nil),
                             claude: Demo.state().claude)
        try Snapshot.panel(to: out.appendingPathComponent("panel-empty.png")) {
            MenuBarPanel(close: {}).environment(empty)
        }
        try Snapshot.panel(to: out.appendingPathComponent("panel-add.png")) {
            AddKeyView(compact: true) {}.environment(Demo.state())
        }
        try Snapshot.panel(to: out.appendingPathComponent("panel-about.png")) {
            AboutPopover(app: .keyBar, hidingInstalledApps: false) { Mascot(size: 56) }
        }
    }

    func testRenderWindow() throws {
        out = try outputFolder("SCREENSHOTS")
        for section in AppSection.allCases {
            for dark in [false, true] {
                let state = Demo.state()
                state.section = section
                try Snapshot.png(ContentView().environment(state), size: NSSize(width: 980, height: 720), dark: dark,
                                 to: out.appendingPathComponent("window-\(section.rawValue)\(dark ? "-dark" : "").png"))
            }
        }
        let state = Demo.state()
        let record = state.store.record("STRIPE_SECRET_KEY")!
        try Snapshot.panel(to: out.appendingPathComponent("window-edit.png")) {
            KeyEditor(record: record) {}.environment(state)
        }
        try Snapshot.panel(to: out.appendingPathComponent("window-add.png")) {
            AddKeyView {}.environment(state)
        }
        // The mascot on its own, for the website
        try Snapshot.png(Mascot(size: 560, disc: nil).frame(width: 560, height: 560), size: NSSize(width: 560, height: 560),
                         to: out.appendingPathComponent("mascot.png"), transparent: true, exactPixels: true)
    }

    /// The app icon: the mascot on a periwinkle squircle, at every size
    func testAppIcon() throws {
        let dir = try outputFolder("ICON_DIR")
        let sizes: [(String, CGFloat)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, pixels) in sizes {
            try Snapshot.png(AppIcon().frame(width: pixels, height: pixels), size: NSSize(width: pixels, height: pixels),
                             to: dir.appendingPathComponent("\(name).png"), transparent: true, exactPixels: true)
        }
    }
}

/// macOS icon grid: an 824/1024 rounded square with a soft shadow
private struct AppIcon: View {
    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            let tile = side * 824 / 1024
            ZStack {
                RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xCDD0F8), AppColors.periwinkle],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: tile, height: tile)
                    .shadow(color: .black.opacity(0.22), radius: side * 0.012, y: side * 0.01)
                Mascot(size: tile * 0.94, disc: nil)
                    .offset(x: tile * 0.02, y: -tile * 0.01)
            }
            .frame(width: side, height: side)
        }
    }
}
