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
            RecorderView()
        }
        .defaultSize(width: 420, height: 580)
        .windowResizability(.contentSize)
        .commands {
            AppCommands()
        }
    }
}
