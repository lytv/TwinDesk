// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
import SwiftUI
import WebKit

@main
struct TwinDeskApp: App {
    @StateObject private var core = Core()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(core)
        }
    }
}
