import SwiftUI

// MARK: - Drive Header

struct DriveHeaderView: View {
    @EnvironmentObject var vm: BackupViewModel

    var body: some View {
        ZStack {
            // Background / Side elements
            HStack {
                DriveCard(
                    label:       "MAIN DISK",
                    url:         vm.mainDriveURL,
                    accent:      .blue,
                    systemImage: "internaldrive.fill"
                ) { vm.selectMainDrive() }

                Spacer()

                DriveCard(
                    label:       "BACKUP DISK",
                    url:         vm.secondaryDriveURL,
                    accent:      .green,
                    systemImage: "externaldrive.fill"
                ) { vm.selectSecondaryDrive() }
            }

            // Absolutely centered middle section
            VStack(spacing: 8) {
                // Mode Switcher
                ModeSwitcher(
                    syncEntireDrive: $vm.syncEntireDrive,
                    onChange: {
                        vm.saveTasks()
                        vm.refreshFullDiskTasks()
                    }
                )

                Spacer().frame(height: 5)

                // Circular Sync/Abort Button
                SyncButton()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .fontDesign(.rounded)
    }
}

// MARK: - Mode Switcher

private struct ModeSwitcher: View {
    @Binding var syncEntireDrive: Bool
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ModeButton(title: "Folders",   isSelected: !syncEntireDrive) {
                guard syncEntireDrive else { return }
                syncEntireDrive = false
                onChange()
            }
            ModeButton(title: "Full Disk", isSelected:  syncEntireDrive) {
                guard !syncEntireDrive else { return }
                syncEntireDrive = true
                onChange()
            }
        }
        .padding(3)
        .background(
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
        )
        .frame(width: 218)
    }
}

private struct ModeButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? .white : (isHovered ? .primary : .secondary))
            .frame(width: 103, height: 28)
            .background(
                Capsule()
                    .fill(isSelected
                          ? Color.accentColor
                          : isHovered ? Color.secondary.opacity(0.12) : Color.clear)
                    .shadow(color: isSelected ? .accentColor.opacity(0.35) : .clear,
                            radius: 4, y: 2)
            )
            .animation(.easeInOut(duration: 0.15), value: isSelected)
            .animation(.easeInOut(duration: 0.1), value: isHovered)
            .onHover { isHovered = $0 }
            .onTapGesture { action() }
            .contentShape(Capsule())
    }
}

// MARK: - Sync Button

private struct SyncButton: View {
    @EnvironmentObject var vm: BackupViewModel
    @State private var isHovered = false

    var body: some View {
        let canSync = !vm.isSyncing && vm.mainDriveURL != nil && vm.secondaryDriveURL != nil
        let icon    = vm.isSyncing ? "xmark" : "arrow.triangle.2.circlepath"

        Button {
            if vm.isSyncing { vm.abortSync() } else { vm.syncAll() }
        } label: {
            ZStack {
                Circle()
                    .fill(vm.isSyncing
                          ? Color.red
                          : isHovered && canSync
                            ? Color.accentColor
                            : Color.secondary.opacity(0.1))
                    .frame(width: 60, height: 60)
                    .animation(.easeInOut(duration: 0.18), value: isHovered)
                    .animation(.easeInOut(duration: 0.18), value: vm.isSyncing)

                // Global Progress Ring
                if vm.isSyncing {
                    Circle()
                        .trim(from: 0, to: vm.globalProgress)
                        .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .frame(width: 53, height: 53)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.15), value: vm.globalProgress)
                }

                Group {
                    if #available(macOS 15.0, *) {
                        Image(systemName: icon)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(vm.isSyncing ? .white : .primary)
                            .symbolEffect(.rotate, options: .repeating,
                                          isActive: vm.isSyncing && vm.mainDriveURL != nil)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(vm.isSyncing ? .white : .primary)
                            .symbolEffect(.pulse, options: .repeating,
                                          isActive: vm.isSyncing && vm.mainDriveURL != nil)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!vm.isSyncing && (vm.mainDriveURL == nil || vm.secondaryDriveURL == nil))
        .contentShape(Circle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Drive Card

struct DriveCard: View {
    let label: String
    let url: URL?
    let accent: Color
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(url != nil ? accent : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.caption.bold())
                        .foregroundStyle(accent)

                    if let url {
                        Text(url.path)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } else {
                        Text("Click to select…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                }
            }
            .padding(12)
            .frame(width: 270, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered
                          ? Color(nsColor: .windowBackgroundColor)
                          : Color(nsColor: .underPageBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isHovered ? accent.opacity(0.4) : Color.secondary.opacity(0.18),
                        lineWidth: 1.5
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        // Suppress default focus ring — we draw our own hover border above
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
    }
}
