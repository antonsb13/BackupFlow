import Foundation

/// Executes rsync operations via `Process()` and streams stdout/stderr output.
actor SyncEngine {

    // MARK: - State

    private var currentProcess: Process?

    // MARK: - Flags

    /// Core rsync flags used for all sync operations:
    /// -a  = archive (recursive, preserve symlinks, times)
    /// -v  = verbose output
    /// --delete          = delete files on destination not in source (true mirror)
    /// --delete-excluded = also delete destination files excluded by --exclude rules
    ///                     (prevents stale macOS metadata accumulating)
    /// --exclude='.DS_Store'  = skip macOS directory metadata files
    /// --exclude='._*'        = skip AppleDouble resource-fork files
    ///                          These cannot be unlinked via rsync inside the app sandbox.
    /// --no-perms = don't attempt to sync Unix permissions (avoids EPERM on FAT/exFAT)
    /// --no-owner, --no-group = skip owner/group sync (requires elevated privileges)
    /// --progress = stream per-file transfer progress (we parse to-chk=X/Y for global progress)
    private static let baseFlags: [String] = [
        "-av",
        "--delete",
        "--exclude=.DS_Store",
        "--exclude=._*",
        "--exclude=.Spotlight-V100",
        "--exclude=.Trashes",
        "--exclude=.fseventsd",
        "--exclude=.DocumentRevisions-V100",
        "--exclude=.TemporaryItems",
        "--exclude=$RECYCLE.BIN",
        "--no-perms",
        "--no-owner",
        "--no-group",
        "--progress"
    ]

    // MARK: - Public API

    /// Mirrors the entire `mainURL` directory to `secondaryURL` using rsync --delete.
    func syncEntireDrive(
        from mainURL: URL,
        to secondaryURL: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> Bool {
        let src = ensureTrailingSlash(mainURL.path)
        let dst = ensureTrailingSlash(secondaryURL.path)
        let args = Self.baseFlags + [src, dst]
        
        let _keepAlive = [mainURL, secondaryURL]
        let result = await runRsync(arguments: args, onOutput: onOutput, onProgress: onProgress)
        _ = _keepAlive
        return result
    }

    /// Syncs a single folder (identified by its relative path) from the main root to the secondary root.
    func syncFolder(
        relativePath: String,
        mainRoot: URL,
        secondaryRoot: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> Bool {
        let srcURL = mainRoot.appendingPathComponent(relativePath)
        let dstURL = secondaryRoot.appendingPathComponent(relativePath)

        try? FileManager.default.createDirectory(
            at: dstURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let src = ensureTrailingSlash(srcURL.path)
        let dst = ensureTrailingSlash(dstURL.path)
        let args = Self.baseFlags + [src, dst]

        let _keepAlive = [mainRoot, secondaryRoot, srcURL]
        let result = await runRsync(arguments: args, onOutput: onOutput, onProgress: onProgress)
        _ = _keepAlive
        return result
    }

    /// Immediately terminates the running rsync process (if any).
    func abort() {
        currentProcess?.terminate()
        currentProcess = nil
    }

    // MARK: - Private

    private nonisolated func ensureTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    /// Filters raw rsync progress lines (byte counts, transfer rate, ETA) from stdout.
    /// These lines match the pattern:   "      1,234,567  98%    4.56MB/s    0:00:01"
    /// Only file names, folder boundaries, and completion summaries are forwarded.
    private nonisolated func shouldShow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        // Skip blank lines
        if t.isEmpty { return false }
        // Skip progress lines: start with digits, commas, spaces (byte count pattern)
        // e.g. "    1,234,567 100%    4.52MB/s    0:00:00 (xfr#12, to-chk=3/16)"
        if t.first?.isNumber == true && (t.contains("%") || t.contains("xfr#")) { return false }
        // Skip the rsync summary stats block ("sent X bytes  received Y bytes...")
        if t.hasPrefix("sent ") && t.contains("bytes") { return false }
        if t.hasPrefix("total size") { return false }
        return true
    }

    /// Parses global progress from an rsync progress line (e.g. " (xfer#1, to-check=123/456)"). Returns nil if not found.
    private nonisolated func parseProgress(from line: String) -> Double? {
        guard let range = line.range(of: "to-ch") else { return nil }
        let sub = line[range.lowerBound...]
        guard let eq = sub.firstIndex(of: "=") else { return nil }
        let afterEq = sub[sub.index(after: eq)...]
        guard let paren = afterEq.firstIndex(of: ")") else { return nil }
        
        let slashSplit = afterEq[..<paren].split(separator: "/")
        guard slashSplit.count == 2,
              let left = Double(slashSplit[0]),
              let right = Double(slashSplit[1]),
              right > 0 else { return nil }
              
        // left is "files remaining", right is "total files"
        return max(0.0, min(1.0, (right - left) / right))
    }

    private func runRsync(
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()

            process.executableURL  = URL(fileURLWithPath: "/usr/bin/rsync")
            process.arguments      = arguments
            process.standardOutput = outPipe
            process.standardError  = errPipe

            self.currentProcess = process

            // Stream stdout — parse progress, filter noisy lines
            outPipe.fileHandleForReading.readabilityHandler = { @Sendable [self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                
                let lines = text.components(separatedBy: "\n")
                
                // Track highest progress in this chunk
                var maxProgress: Double? = nil
                
                let filtered = lines.filter { line in
                    // If it's a progress line, try parsing the percentage
                    if !self.shouldShow(line) {
                        if let px = self.parseProgress(from: line) {
                            maxProgress = max(maxProgress ?? 0, px)
                        }
                        return false // Filter it out of the text log
                    }
                    return true
                }
                .joined(separator: "\n")
                
                if let progress = maxProgress {
                    onProgress(progress)
                }

                if !filtered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onOutput(filtered + "\n")
                }
            }

            // Stream stderr — always show (errors are important)
            errPipe.fileHandleForReading.readabilityHandler = { @Sendable handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    onOutput("⚠ " + text)
                }
            }

            process.terminationHandler = { @Sendable p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                Task { await self.clearProcess() }
                // Exit 0 = success; exit 23/24 = partial (some files could not be sent)
                // We treat exit 23 as a non-fatal partial success
                let status = p.terminationStatus
                continuation.resume(returning: status == 0 || status == 23)
            }

            do {
                try process.run()
            } catch {
                onOutput("❌ rsync launch failed: \(error.localizedDescription)\n")
                self.currentProcess = nil
                continuation.resume(returning: false)
            }
        }
    }

    private func clearProcess() {
        currentProcess = nil
    }
}
