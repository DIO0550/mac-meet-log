//
//  meet_logApp.swift
//  meet-log
//
//  Created by DIO on 2026/05/16.
//

import SwiftUI

@main
struct meet_logApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .defaultSize(width: 420, height: 680)
        .windowResizability(.contentSize)
        .commands {
            AppCommands()
        }
    }
}
