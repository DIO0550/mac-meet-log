//
//  meet_logApp.swift
//  meet-log
//
//  Created by DIO on 2026/05/16.
//

import SwiftUI

@main
struct meet_logApp: App {
    @NSApplicationDelegateAdaptor(MeetLogAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("meet-log", id: "main") {
            AppRootView(recorderViewModel: appDelegate.recorderViewModel)
        }
        .defaultSize(width: 420, height: 680)
        .windowResizability(.contentSize)
        .commands {
            AppCommands()
        }
        MenuBarExtra {
            RecorderMenuBarView(viewModel: appDelegate.recorderViewModel)
        } label: {
            RecorderMenuBarLabel(viewModel: appDelegate.recorderViewModel)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView()
        }
    }
}
