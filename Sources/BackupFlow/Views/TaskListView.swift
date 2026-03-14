import SwiftUI

struct TaskListView: View {
    @EnvironmentObject var vm: BackupViewModel

    var body: some View {
        Group {
            if vm.tasks.isEmpty {
                if vm.syncEntireDrive {
                    if vm.mainDriveURL == nil {
                        emptyStatePlaceholder(icon: "internaldrive", title: "Select Main Disk", desc: "Choose a Root Volume to scan folders.")
                    } else {
                        emptyStatePlaceholder(icon: "magnifyingglass", title: "Scanning...", desc: "Reading top-level directories.")
                    }
                } else {
                    folderEmptyState
                }
            } else {
                taskTable
            }
        }
    }

    // MARK: - Table

    private var taskTable: some View {
        Table(vm.tasks, selection: $vm.selectedTaskIDs) {

            // Folder column
            TableColumn("Folder") { task in
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(task.isMissingOnBackup ? .orange : .blue)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.folderName)
                            .lineLimit(1)
                        if !task.relativePath.isEmpty && task.relativePath != task.folderName {
                            Text(task.relativePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if task.isMissingOnBackup {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .help("This folder is missing on the Backup Disk")
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 160, ideal: 230)

            // Size column
            TableColumn("Size") { task in
                Text(formatSize(task.sizeBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            // Last Sync column — looks up by absolute path via SyncHistoryManager for cross-mode persistence
            TableColumn("Last Sync") { task in
                let absPath = vm.mainDriveURL.map { $0.appendingPathComponent(task.relativePath).path } ?? ""
                let date = SyncHistoryManager.shared.date(for: absPath) ?? task.lastSyncDate
                Text(formatDate(date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(date == nil ? .tertiary : .secondary)
            }
            .width(min: 115, ideal: 130)

            // Status & Progress column
            TableColumn("Status") { task in
                HStack(spacing: 6) {
                    StatusBadge(status: task.status)
                    
                    // Show progress bar inline if syncing or failed mid-transfer
                    if task.status == .syncing || ((task.status == .failed || task.isMissingOnBackup) && task.progress > 0) {
                        ProgressView(value: task.progress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .tint(task.isMissingOnBackup || task.status == .failed ? .orange : .blue)
                            .frame(maxWidth: 50)
                            .frame(height: 6)
                        
                        Text("\(Int(task.progress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if !vm.syncEntireDrive {
                        Button {
                            vm.selectedTaskIDs.insert(task.id)
                            vm.removeSelectedTasks()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red.opacity(0.7))
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isSyncing)
                    }
                }
            }
            .width(min: 160, ideal: 200)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Formatters

    private func formatSize(_ bytes: Int64?) -> String {
        guard let b = bytes else { return "—" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useAll]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yy HH:mm"
        return f.string(from: date)
    }

    // MARK: - Empty States

    private func emptyStatePlaceholder(icon: String, title: String, desc: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(desc)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderEmptyState: some View {
        VStack(spacing: 30) {
            Spacer()
            Button {
                vm.addFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .foregroundStyle(.blue.gradient)
                    .padding(40)
                    .background(
                        Circle()
                            .fill(.blue.opacity(0.1))
                            .overlay(Circle().stroke(.blue.opacity(0.2), lineWidth: 1))
                    )
                    .shadow(color: .black.opacity(0.1), radius: 15, x: 0, y: 8)
            }
            .buttonStyle(.plain)
            .disabled(vm.mainDriveURL == nil)

            VStack(spacing: 12) {
                Text("Add Backup Folders")
                    .font(.title2.bold())
                Text(vm.mainDriveURL == nil
                     ? "Select a Main Disk first."
                     : "Click the + icon to choose specific folders to mirror.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: SyncStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(badgeColor)
                .frame(width: 7, height: 7)
            Text(status.rawValue)
                .font(.caption.bold())
                .foregroundStyle(badgeColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(badgeColor.opacity(0.1))
        .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch status {
        case .idle:    return .secondary
        case .syncing: return .blue
        case .success: return .green
        case .failed:  return .red
        }
    }
}
