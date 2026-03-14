import SwiftUI

@main
struct BackupFlowApp: App {
    @StateObject private var viewModel = BackupViewModel()

    var body: some Scene {
        // MARK: - Main Window
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(viewModel)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 860, height: 580)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // MARK: - Menu Bar Extra
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(viewModel)
        } label: {
            Label("Backup Flow: \(viewModel.statusText)",
                  systemImage: viewModel.isSyncing
                    ? "arrow.triangle.2.circlepath"
                    : "externaldrive.fill.badge.checkmark")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - MenuBar Menu Content

struct MenuBarContent: View {
    @EnvironmentObject var vm: BackupViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status header
        VStack(alignment: .leading, spacing: 2) {
            Label("Backup Flow", systemImage: "externaldrive.fill.badge.checkmark")
                .font(.headline)
            Text(vm.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)

        Divider()

        if vm.isSyncing {
            Button(role: .destructive) {
                vm.abortSync()
            } label: {
                Label("Stop Backup", systemImage: "stop.circle.fill")
            }
        } else {
            Button {
                vm.syncAll()
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(vm.mainDriveURL == nil || vm.secondaryDriveURL == nil)
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        Divider()

        Button {
            // Find any regular (non-panel, non-HUD) visible or miniaturized window that belongs to our app.
            // WindowGroup windows are NSWindow subclass (not sheet/panel), so we filter by class.
            let appWindow = NSApp.windows.first {
                $0.isKind(of: NSWindow.self)
                && !($0 is NSPanel)
                && $0.contentViewController != nil
            }
            if let win = appWindow {
                if win.isMiniaturized { win.deminiaturize(nil) }
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        } label: {
            Label("Open Backup Flow", systemImage: "macwindow")
        }

        Divider()

        Button("Quit Backup Flow") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}
