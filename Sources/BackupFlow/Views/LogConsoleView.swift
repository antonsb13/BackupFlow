import SwiftUI

struct LogConsoleView: View {
    @EnvironmentObject var vm: BackupViewModel

    // Console body height — starts at 150 but console is hidden by default
    @State private var consoleHeight: CGFloat = 150
    // Used to track height at drag start to avoid cumulative drift
    @State private var heightAtDragStart: CGFloat = 150

    private let minHeight: CGFloat = 60
    private let maxHeight: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            headerBar

            if vm.isLogExpanded {
                resizeHandle
                logBody
                    .frame(height: consoleHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: vm.isLogExpanded)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.secondary)
            Text("Log Console")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Spacer()

            ProgressView()
                .scaleEffect(0.6)
                .frame(height: 14)
                .opacity(vm.isSyncing ? 1 : 0)

            if !vm.logOutput.isEmpty {
                Button("Clear") { vm.logOutput = "" }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    vm.isLogExpanded.toggle()
                }
            } label: {
                Image(systemName: vm.isLogExpanded ? "chevron.down" : "chevron.up")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        ZStack {
            Color(nsColor: .separatorColor).frame(height: 1)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 32, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 10)
        .background(Color(nsColor: .windowBackgroundColor))
        // Native macOS resize cursor on hover
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        // Drag with global coordinate space for smooth, non-drifting resize
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    // Dragging upward (negative y) = increasing console height
                    let delta = -value.translation.height
                    consoleHeight = (heightAtDragStart + delta)
                        .clamped(to: minHeight...maxHeight)
                }
                .onEnded { _ in
                    heightAtDragStart = consoleHeight
                }
        )
    }

    // MARK: - Log Body

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                Text(vm.logOutput.isEmpty ? "No output yet." : vm.logOutput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(vm.logOutput.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("logEnd")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: vm.logOutput) {
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Comparable Clamp helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        max(range.lowerBound, min(range.upperBound, self))
    }
}
