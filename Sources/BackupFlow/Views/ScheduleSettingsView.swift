import SwiftUI

struct ScheduleSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: BackupViewModel

    // Uses Double so sub-hour intervals (0.25 = 15min, 0.5 = 30min) work correctly.
    // Key matches BackupViewModel.SchKeys.interval ("bf.scheduleInterval")
    @AppStorage("bf.scheduleEnabled")  private var scheduleEnabled = false
    @AppStorage("bf.scheduleInterval") private var intervalHours: Double = 1.0

    private struct Interval: Identifiable {
        let id: Double
        let label: String
    }

    private let intervals: [Interval] = [
        .init(id: 0.25,  label: "Every 15 minutes"),
        .init(id: 0.5,   label: "Every 30 minutes"),
        .init(id: 1,     label: "Every hour"),
        .init(id: 2,     label: "Every 2 hours"),
        .init(id: 4,     label: "Every 4 hours"),
        .init(id: 6,     label: "Every 6 hours"),
        .init(id: 12,    label: "Every 12 hours"),
        .init(id: 24,    label: "Daily"),
        .init(id: 48,    label: "Every 2 days"),
        .init(id: 168,   label: "Weekly"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            Label("Schedule Settings", systemImage: "calendar.badge.clock")
                .font(.title2.bold())

            Divider()

            // Enable toggle
            Toggle(isOn: $scheduleEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable automatic sync")
                        .font(.body)
                    Text("Runs in the background while the app is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Interval picker (only when enabled)
            if scheduleEnabled {
                Picker("Interval", selection: $intervalHours) {
                    ForEach(intervals) { item in
                        Text(item.label).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240)

                // Status hint
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Next sync will trigger after \(intervalLabel(for: intervalHours)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    // Re-arm the scheduler with the freshly saved settings
                    vm.setupScheduler()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380, height: scheduleEnabled ? 300 : 210)
        .animation(.easeInOut(duration: 0.15), value: scheduleEnabled)
    }

    private func intervalLabel(for hours: Double) -> String {
        intervals.first { $0.id == hours }?.label.lowercased().replacingOccurrences(of: "every ", with: "") ?? "\(hours)h"
    }
}
