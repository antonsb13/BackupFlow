import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: BackupViewModel
    @State private var showSchedule = false

    @AppStorage("bf.scheduleEnabled")  private var scheduleEnabled  = false
    @AppStorage("bf.scheduleInterval") private var scheduleInterval: Double = 1.0

    private var scheduleIsActive: Bool { scheduleEnabled && scheduleInterval > 0 }

    var body: some View {
        VStack(spacing: 0) {
            DriveHeaderView()
            Divider()
            TaskListView()
            LogConsoleView()
        }
        .fontDesign(.rounded)
        .modifier(WindowMaterialModifier())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {

                    // Add / Remove — only in Custom Folders mode
                    if !vm.syncEntireDrive {
                        ToolbarIconButton(
                            icon: "folder.badge.plus",
                            tooltip: "Add folder",
                            isDisabled: vm.mainDriveURL == nil || vm.isSyncing
                        ) { vm.addFolder() }

                        ToolbarIconButton(
                            icon: "folder.badge.minus",
                            tooltip: "Remove folder",
                            isDisabled: vm.selectedTaskIDs.isEmpty || vm.isSyncing
                        ) { vm.removeSelectedTasks() }

                        Divider().frame(height: 18)
                    }

                    // Mute Toggle
                    ToolbarIconButton(
                        icon: vm.isMuted ? "speaker.slash.fill" : "speaker.fill",
                        tooltip: "Mute On/Off"
                    ) {
                        vm.isMuted.toggle()
                        vm.saveTasks()
                    }

                    // Schedule
                    ToolbarIconButton(
                        icon: "calendar.badge.clock",
                        tooltip: "Sync scheduler",
                        isActive: scheduleIsActive,
                        isDisabled: vm.isSyncing
                    ) { showSchedule = true }
                }
                .padding(.horizontal, 8)
            }
        }
        .sheet(isPresented: $showSchedule) {
            ScheduleSettingsView()
                .environmentObject(vm)
        }
        .frame(minWidth: 700, minHeight: 450)
    }
}

// MARK: - Toolbar Icon Button

/// A consistent 28×28 icon button used for all toolbar actions.
/// Active state fills the background with `accentColor`.
/// Hover state shows a subtle gray tint.
/// Size is identical in all states — there is no layout shift.
private struct ToolbarIconButton: View {
    let icon: String
    let tooltip: String
    var isActive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    private let size: CGFloat = 28

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
                .padding(.horizontal, 4)
                .background(backgroundColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.13), value: isHovered)
        .animation(.easeInOut(duration: 0.13), value: isActive)
        .help(tooltip)
    }

    private var backgroundColor: Color {
        if isActive { return .accentColor }
        if isHovered && !isDisabled { return Color.secondary.opacity(0.18) }
        return .clear
    }

    private var iconColor: Color {
        isActive ? .white : .primary
    }
}

// MARK: - Window Material Modifier

private struct WindowMaterialModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.ultraThinMaterial, for: .window)
        } else {
            content
        }
    }
}
