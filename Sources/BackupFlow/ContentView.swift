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

                    // Confirm Deletions Toggle
                    ToolbarIconButton(
                        icon: "shield.checkerboard",
                        tooltip: "Confirm deletions before applying",
                        isActive: vm.confirmDeletions,
                        isDisabled: vm.isSyncing
                    ) {
                        vm.confirmDeletions.toggle()
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
        .overlay {
            if vm.isReviewingDeletions {
                DeletionConfirmationModal()
                    .environmentObject(vm)
            }
        }
        .alert(
            "Sync Error",
            isPresented: Binding(
                get: { vm.alertMessage != nil },
                set: { if !$0 { vm.alertMessage = nil } }
            ),
            presenting: vm.alertMessage
        ) { _ in
            Button("OK", role: .cancel) { }
        } message: { msg in
            Text(msg)
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

// MARK: - Deletion Confirmation Modal

struct DeletionConfirmationModal: View {
    @EnvironmentObject var vm: BackupViewModel
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 24))
                Text("Confirm Deletion")
                    .font(.title2)
                    .bold()
            }

            Text("This file exists on your Backup Disk but is no longer present on your Main Disk. Delete from backup?")
                .foregroundColor(.secondary)
            
            if vm.currentDeletionIndex < vm.deletionQueue.count {
                Text(vm.deletionQueue[vm.currentDeletionIndex])
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(8)
                    .lineLimit(nil)
            }

            Toggle("Apply to all remaining deletions in this sync task", isOn: $applyToAll)
                .padding(.top, 8)

            HStack {
                Button("Cancel Sync", role: .cancel) {
                    vm.resolveDeletion(approved: false, applyToAll: false)
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button(role: .destructive) {
                    vm.resolveDeletion(approved: true, applyToAll: applyToAll)
                } label: {
                    Text("Delete")
                        .bold()
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.4).ignoresSafeArea())
    }
}
