// CobainVisionMacApp.swift
// MovementPrompt PoC — Milestone H-A Stage A1 macOS Target
//
// Mac App @main entry point.

import SwiftUI

@main
struct CobainVisionMacApp: App {
    var body: some Scene {
        WindowGroup {
            MacDashboardView()
                .frame(minWidth: 900, minHeight: 650)
        }
    }
}
