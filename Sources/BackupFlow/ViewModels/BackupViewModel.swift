import Foundation
import AppKit
import UserNotifications
import os

enum SyncState: Equatable {
    case idle
    case calculating
    case transferring
    /// Final whole-drive sweep. Its cost is directory traversal, not bytes — rsync emits no
    /// `--progress` output at all once the tree is already in sync, so there is nothing to
    /// drive a percentage with. Shown as an indeterminate phase instead of a frozen ring.
    case finalizing
    case completed
}

@MainActor
final class BackupViewModel: ObservableObject {

    // MARK: - Published State

    // Sync history is NOT cleared here: these also change on every eject/reconnect of the same
    // disk. It is cleared only when the user selects a different disk (`recordSelectedVolume`).
    @Published var mainDriveURL: URL? {
        didSet {
            guard !isRestoring else { return }
            resetTaskStates()
            handleDriveAvailabilityChange()
        }
    }
    @Published var secondaryDriveURL: URL? {
        didSet {
            guard !isRestoring else { return }
            resetTaskStates()
            handleDriveAvailabilityChange()
        }
    }
    @Published var syncEntireDrive: Bool = false
    @Published var tasks: [BackupTask] = []
    @Published var selectedTaskIDs: Set<UUID> = []
    @Published var logOutput: String = ""
    @Published var isLogExpanded: Bool = false
    @Published var syncState: SyncState = .idle
    var isSyncing: Bool { syncState == .calculating || syncState == .transferring || syncState == .finalizing }
    @Published var showAbortConfirm: Bool = false
    @Published var isMuted: Bool = false
    @Published var alertMessage: String? = nil
    @Published var alertTitle: String? = nil
    @Published var alertBody: String? = nil
    @Published var useChecksum: Bool = false
    @Published var isSyncCancelled: Bool = false
    
    // Deletion Guard State
    @Published var confirmDeletions: Bool = UserDefaults.standard.bool(forKey: "bf.confirmDeletions") {
        didSet { UserDefaults.standard.set(confirmDeletions, forKey: "bf.confirmDeletions") }
    }
    @Published var deletionQueue: [String] = []
    @Published var currentDeletionIndex: Int = 0
    @Published var isReviewingDeletions: Bool = false
    private var deletionContinuation: CheckedContinuation<Bool, Never>?
    private var applyToAllDeletions: Bool = false
    @Published var approvedPaths: [String] = []

    // Global Progress State
    @Published var globalProgress: Double = 0.0
    @Published var currentTaskIndex: Int = 0
    @Published var totalTasksCount: Int = 0

    // MARK: - Private

    private let engine = SyncEngine()
    private var scheduleTimer: Timer?
    private var diskWatchdogTimer: Timer?
    private var fullDiskScanTask: Task<Void, Never>?
    /// Set for the duration of a scheduled sync (see `syncAll(unattended:)`).
    private var isUnattendedRun = false
    private var isRestoring = false // Prevents `didSet` from firing during `restoreState()`

    /// Per-task 0…1 progress for the CURRENT sync session only, keyed by task id.
    /// The global ring is computed from this rather than from `BackupTask.status`, because a
    /// `.success` restored from `SyncHistoryManager` describes a *previous* sync and must not
    /// count as work completed now. Reset at the start of every sync.
    private var sessionFractions: [UUID: Double] = [:]
    /// Byte weights of the tasks taking part in the current session, keyed by task id.
    private var sessionWeights: [UUID: Int64] = [:]

    private enum SchKeys {
        static let enabled  = "bf.scheduleEnabled"
        static let interval = "bf.scheduleInterval"  // stored in hours (Int); 0 means off
    }

    private enum Keys {
        static let mainBookmark      = "bf.mainBookmark"
        static let secondaryBookmark = "bf.secondaryBookmark"
        static let mainVolumeUUID      = "bf.mainVolumeUUID"
        static let secondaryVolumeUUID = "bf.secondaryVolumeUUID"
        static let syncMode          = "bf.syncEntireDrive"
        static let tasks             = "bf.tasks"
        static let isMuted           = "bf.isMuted"
        static let useChecksum       = "bf.useChecksum"
    }

    // Pre-loaded sounds — prevents audio engine overload on rapid calls
    private static let successSound: NSSound? = NSSound(named: "Glass")
    private static let failureSound: NSSound? = NSSound(named: "Basso")

    // MARK: - Init

    init() {
        isRestoring = true
        restoreState()
        isRestoring = false
        checkDiskAvailability()     // clear ghost paths that are no longer reachable
        handleDriveAvailabilityChange() // initial UI sync after state restoration
        setupScheduler()            // start background sync timer if schedule was configured
        setupVolumeMonitor()        // listen for disk eject/unmount events
        startDiskWatchdog()         // periodic FileManager check for physical ejections
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Computed

    var statusText: String {
        switch syncState {
        case .calculating:
            return "Preparing..."
        case .transferring:
            let pct = Int(globalProgress * 100)
            let actionText = useChecksum ? "Verifying" : "Syncing"
            if totalTasksCount > 1 {
                return "\(actionText) \(currentTaskIndex) of \(totalTasksCount) (\(pct)%)"
            } else {
                return "\(actionText) (\(pct)%)"
            }
        case .finalizing:
            return "Finalizing..."
        case .completed:
            return "Synced"
        case .idle:
            break
        }
        
        if mainDriveURL == nil || secondaryDriveURL == nil { return "Not configured" }
        let failed = tasks.filter { $0.status == .failed }.count
        if failed > 0 { return "\(failed) task(s) failed" }
        let done = tasks.filter { $0.status == .success }.count
        if done > 0 { return "Last sync OK" }
        return "Idle"
    }

    // MARK: - Drive Selection

    func selectMainDrive() {
        guard let url = pickVolume(message: "Select the Main Disk") else { return }
        if isSameVolume(url, secondaryDriveURL) {
            let msg = "This is the same disk already selected as the Backup disk. Choose a different physical disk."
            log("🛑 \(msg)\n")
            alertTitle = "Same Disk Selected"
            alertBody  = msg
            return
        }
        if let data = makeBookmark(for: url) {
            UserDefaults.standard.set(data, forKey: Keys.mainBookmark)
        }
        recordSelectedVolume(url, uuidKey: Keys.mainVolumeUUID)
        mainDriveURL = url  // triggers didSet → handleDriveAvailabilityChange
    }

    func selectSecondaryDrive() {
        guard let url = pickVolume(message: "Select the Backup Disk") else { return }
        if isSameVolume(url, mainDriveURL) {
            let msg = "This is the same disk already selected as the Main disk. Choose a different physical disk."
            log("🛑 \(msg)\n")
            alertTitle = "Same Disk Selected"
            alertBody  = msg
            return
        }
        if let data = makeBookmark(for: url) {
            UserDefaults.standard.set(data, forKey: Keys.secondaryBookmark)
        }
        recordSelectedVolume(url, uuidKey: Keys.secondaryVolumeUUID)
        secondaryDriveURL = url  // triggers didSet → handleDriveAvailabilityChange
    }

    /// Stores the selected disk's UUID. Sync history is cleared only when this is a different
    /// disk from the one selected before, so re-selecting the same disk keeps its dates.
    private func recordSelectedVolume(_ url: URL, uuidKey: String) {
        let newUUID = volumeUUID(for: url)
        if Self.shouldClearHistory(previousUUID: UserDefaults.standard.string(forKey: uuidKey), newUUID: newUUID) {
            SyncHistoryManager.shared.clear()
        }
        UserDefaults.standard.set(newUUID, forKey: uuidKey)
    }

    /// The persistent volume UUID for a mounted volume URL, used to detect when a different
    /// physical disk has been mounted at a previously-used `/Volumes/<name>` path. Reading this
    /// resource value under App Sandbox requires an active security-scope grant, so this opens
    /// (and releases) one itself rather than relying on a caller to have one open already.
    private func volumeUUID(for url: URL) -> String? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            return try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        } catch {
            // nil is a meaningful answer to the callers (identity unknown → fail closed), so this
            // is only recorded for diagnostics rather than shown in the console.
            Self.diagnostics.error("Could not read the volume UUID of \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let diagnostics = Logger(subsystem: "com.backupflow.app", category: "Volumes")

    /// True if `a` and `b` refer to the same physical volume (by UUID, falling back to a
    /// standardized path comparison if a UUID can't be read for either one).
    private func isSameVolume(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        if let uuidA = volumeUUID(for: a), let uuidB = volumeUUID(for: b) {
            return uuidA == uuidB
        }
        return a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// Confirms `url` is still the same physical volume that was originally selected for
    /// `storedUUIDKey`. If no baseline UUID was recorded yet (e.g. upgrading from an older
    /// version), this records one now and passes. A UUID that can no longer be read counts as
    /// a mismatch: this check guards a destructive `--delete` mirror, so it must fail closed.
    private func verifyVolumeIdentity(url: URL, storedUUIDKey: String) -> Bool {
        let current = volumeUUID(for: url)
        switch Self.volumeIdentity(stored: UserDefaults.standard.string(forKey: storedUUIDKey), current: current) {
        case .noBaseline:
            UserDefaults.standard.set(current, forKey: storedUUIDKey)
            return true
        case .match:
            return true
        case .mismatch:
            return false
        }
    }

    // MARK: - Path & Volume Rules (pure, testable)

    enum VolumeIdentity: Equatable {
        case match, mismatch, noBaseline
    }

    nonisolated static func volumeIdentity(stored: String?, current: String?) -> VolumeIdentity {
        guard let stored else { return .noBaseline }
        return current == stored ? .match : .mismatch
    }

    /// True unless both UUIDs are known and equal — an unreadable UUID can't prove it's the same disk.
    nonisolated static func shouldClearHistory(previousUUID: String?, newUUID: String?) -> Bool {
        guard let previousUUID, let newUUID else { return true }
        return previousUUID != newUUID
    }

    /// Path of `folder` relative to `root`, compared by path components after resolving
    /// symlinks — so `/Volumes/Data2` is not "inside" `/Volumes/Data`, and a symlink that
    /// points off the disk is rejected. Returns "" for the root itself and nil when `folder`
    /// lies outside `root`.
    nonisolated static func relativePath(of folder: URL, inside root: URL) -> String? {
        let folderParts = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard folderParts.starts(with: rootParts) else { return nil }
        return folderParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    /// True when `url` is `volume` or lies inside it, compared by path components. The root
    /// volume `/` never matches, so an odd unmount notification can't clear every drive.
    nonisolated static func isURL(_ url: URL, onVolume volume: URL) -> Bool {
        let volumeParts = volume.standardizedFileURL.pathComponents
        return volumeParts.count > 1 && url.standardizedFileURL.pathComponents.starts(with: volumeParts)
    }

    // MARK: - Task Management

    func addFolder() {
        guard let mainURL = mainDriveURL else {
            log("⚠️ Select a Main drive first.\n"); return
        }
        guard let url = pickFolder(message: "Select a folder to back up", startingAt: mainURL) else { return }

        guard let relative = Self.relativePath(of: url, inside: mainURL) else {
            let msg = "'\(url.lastPathComponent)' is not on the Main disk (\(mainURL.lastPathComponent)). Choose a folder on the Main disk."
            log("⚠️ \(msg)\n")
            alertTitle = "Folder Outside Main Disk"
            alertBody  = msg
            return
        }
        if relative.isEmpty {
            log("⚠️ Cannot add the entire disk root in Custom Folders mode. Use Full Disk Sync instead.\n")
            return
        }

        var task = BackupTask(
            folderName:   url.lastPathComponent,
            relativePath: relative,
            bookmarkData: makeBookmark(for: url)
        )
        task.status = .calculating  // Show "Calculating..." in the row immediately
        tasks.append(task)
        saveTasks()

        // v1.8.0 — Async size calculation; the walk itself runs off the main actor
        let taskID  = task.id
        let taskURL = url
        Task {
            let size = await Self.directorySize(of: taskURL)

            guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[idx].sizeBytes = size         // 0 is valid (empty folder)
            tasks[idx].status    = .idle
            saveTasks()
        }
    }

    func removeSelectedTasks() {
        tasks.removeAll { selectedTaskIDs.contains($0.id) }
        selectedTaskIDs = []
        saveTasks()
    }

    // MARK: - Volume Check

    private func isVolumeMounted(_ url: URL) -> Bool {
        // Try with security scope first, then without (for non-sandboxed / already-scoped URLs)
        let didStart = url.startAccessingSecurityScopedResource()
        let reachable = (try? url.checkResourceIsReachable()) == true
        if didStart { url.stopAccessingSecurityScopedResource() }
        return reachable
    }

    // MARK: - Sync

    /// - Parameter unattended: true for scheduled runs. Nothing in an unattended run may wait for
    ///   user input — deletions that need confirmation are deferred to a manual sync instead.
    func syncAll(unattended: Bool = false) {
        guard let mainURL = mainDriveURL, let secondaryURL = secondaryDriveURL else {
            log("⚠️ Select both drives before syncing.\n"); return
        }
        guard !isSyncing else { return }

        if !isVolumeMounted(mainURL) || !isVolumeMounted(secondaryURL) {
            let msg = "Disk Disconnected. Ensure both disks are mounted."
            log("🛑 \(msg)\n")
            alertMessage = msg
            playSound(.failure)
            return
        }

        // Re-check identity right before a destructive mirror: the watchdog and mount
        // notifications only look at paths, and another disk can appear at the same path.
        guard verifyVolumeIdentity(url: mainURL, storedUUIDKey: Keys.mainVolumeUUID),
              verifyVolumeIdentity(url: secondaryURL, storedUUIDKey: Keys.secondaryVolumeUUID) else {
            let msg = "A different disk is mounted where a selected disk used to be, or its identity can't be read. Re-select the Main and Backup disks before syncing."
            log("🛑 \(msg)\n")
            alertTitle = "Disk Changed"
            alertBody  = msg
            playSound(.failure)
            return
        }

        if isSameVolume(mainURL, secondaryURL) {
            let msg = "Main and Backup disks are the same physical volume. Select two different disks — syncing a disk into itself would mirror it with --delete."
            log("🛑 \(msg)\n")
            alertTitle = "Same Disk Selected"
            alertBody  = msg
            playSound(.failure)
            return
        }

        syncState = .calculating
        isUnattendedRun = unattended
        log("═══ Backup Flow  \(Date().formatted())\(unattended ? "  (scheduled)" : "") ═══\n")

        Task {
            await performSync(mainURL: mainURL, secondaryURL: secondaryURL)
            self.syncState = .idle
        }
    }

    /// One sync run for both modes. Full Disk mirrors each top-level folder as its own task and
    /// then sweeps the disk root; Custom Folders syncs only the selected folders.
    private func performSync(mainURL mURL: URL, secondaryURL sURL: URL) async {
        let fullDisk = syncEntireDrive
        let checksum = useChecksum
        if fullDisk { log("▶ Full drive sync: \(mURL.path) → \(sURL.path)\n") }

        let mStarted = mURL.startAccessingSecurityScopedResource()
        let sStarted = sURL.startAccessingSecurityScopedResource()
        defer {
            if sStarted { sURL.stopAccessingSecurityScopedResource() }
            if mStarted { mURL.stopAccessingSecurityScopedResource() }
        }

        isSyncCancelled = false
        applyToAllDeletions = false

        // 1. Preview every task strictly before transferring anything
        guard let plan = await previewTasks(main: mURL, secondary: sURL, checksum: checksum) else { return }

        guard hasFreeSpace(for: plan.totalBytes, on: sURL) else {
            abortSync()
            return
        }

        let totalGB = String(format: "%.2f", Double(plan.totalBytes) / 1_073_741_824.0)
        log("📦 Estimated transfer: \(totalGB) GB across \(plan.tasks.count) folder(s).\n")

        beginProgressSession(tasks: plan.tasks)
        syncState = .transferring
        totalTasksCount = plan.tasks.count + (fullDisk ? 1 : 0)

        // 2. Sync each folder
        var tally = SyncTally()
        for (i, task) in plan.tasks.enumerated() {
            if isSyncCancelled { return }
            switch await syncTask(task, number: i + 1, of: plan.tasks.count, preview: plan.previews[task.id],
                                  main: mURL, secondary: sURL, checksum: checksum, fullDisk: fullDisk) {
            case .aborted:              return
            case .skipped:              tally.anyFailure = true
            case .finished(let result): tally.record(result)
            }
        }
        if isSyncCancelled { return }

        // 3. Full Disk only: sweep what lies outside the folders synced above
        if fullDisk {
            switch await sweepRoot(main: mURL, secondary: sURL, checksum: checksum,
                                   excluding: plan.tasks.map(\.relativePath)) {
            case .aborted:              return
            case .skipped:              tally.anyFailure = true
            case .finished(let result): tally.record(result)
            }
        }

        globalProgress = 1.0
        if fullDisk {
            syncState = .completed
        } else {
            saveTasks()
        }
        reportCompletion(tally, fullDisk: fullDisk)
    }

    private struct SyncPlan {
        var tasks: [BackupTask]
        /// One dry run per task feeds the size estimate, the Deletion Guard and the mass-deletion
        /// check. A task without a preview could not be checked safely and is skipped.
        var previews: [UUID: TransferPreview]
        var totalBytes: Int64
    }

    private enum TaskRunResult {
        /// The sync was cancelled or a deletion was rejected — stop the whole run.
        case aborted
        /// Not synced because it could not be checked safely; counts as a failure.
        case skipped
        case finished(SyncOutcome)
    }

    private struct SyncTally {
        var anyFailure = false
        var anyWarnings = false

        mutating func record(_ outcome: SyncOutcome) {
            switch outcome {
            case .success:  break
            case .warnings: anyWarnings = true
            case .failure:  anyFailure = true
            }
        }
    }

    /// Dry-runs every task, marking rows as "Calculating..." while it goes. Returns nil if the
    /// sync was cancelled meanwhile.
    private func previewTasks(main mURL: URL, secondary sURL: URL, checksum: Bool) async -> SyncPlan? {
        log("Calculating transfer sizes...\n")
        var plan = SyncPlan(tasks: tasks, previews: [:], totalBytes: 0)

        for i in plan.tasks.indices {
            if isSyncCancelled { return nil }
            let task = plan.tasks[i]
            setStatus(task.id, .calculating)  // Row shows "Calculating..."
            do {
                let preview = try await engine.previewTransfer(
                    from: mURL.appendingPathComponent(task.relativePath),
                    to: sURL.appendingPathComponent(task.relativePath),
                    useChecksum: checksum
                )
                plan.previews[task.id] = preview
                plan.tasks[i].targetBytes = max(1, preview.transferBytes)
                plan.totalBytes += preview.transferBytes
            } catch {
                if isSyncCancelled { return nil }
                log("❌ Could not preview '\(task.folderName)': \(error.localizedDescription) — it will be skipped.\n")
            }
            if isSyncCancelled { return nil }

            // Revert the row so "Calculating..." doesn't stick on rows still waiting their turn
            if let main = mainDriveURL, SyncHistoryManager.shared.date(for: main.appendingPathComponent(task.relativePath).path) != nil {
                setStatus(task.id, .success)
            } else {
                setStatus(task.id, .idle)
            }
        }
        if isSyncCancelled { return nil }

        // NOTE: no whole-drive dry run here. It used to be added to the total, but it measures
        // the same bytes the per-folder runs already cover, roughly doubling the estimate and
        // skewing the ring. The final sweep is reported as an indeterminate phase instead.

        // Copy only the estimates back: a wholesale `tasks = plan.tasks` would also discard
        // folder sizes that the background size scan filled in since the snapshot was taken.
        for task in plan.tasks {
            guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { continue }
            tasks[index].targetBytes = task.targetBytes
            if plan.previews[task.id] == nil { setStatus(task.id, .failed) }
        }
        return plan
    }

    /// v1.7.6 — Pre-sync free space guard. Alerts and returns false when `requiredBytes` (plus a
    /// 500 MB margin) won't fit on `backupURL`; proceeds when free space can't be read at all.
    private func hasFreeSpace(for requiredBytes: Int64, on backupURL: URL) -> Bool {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: backupURL.path)
            guard let freeSize = (attrs[.systemFreeSize] as? NSNumber)?.int64Value else { return true }
            let required = requiredBytes + (1024 * 1024 * 500)
            guard freeSize < required else { return true }

            let diskName = backupURL.lastPathComponent
            let reqGB    = String(format: "%.2f", Double(required) / 1_073_741_824.0)
            let availGB  = String(format: "%.2f", Double(freeSize) / 1_073_741_824.0)
            let logMsg   = "❌ Error: Insufficient space on \(diskName). Required: \(reqGB) GB, Available: \(availGB) GB."
            log("\(logMsg)\n")
            alertTitle   = "Insufficient Backup Space on '\(diskName)':"
            alertBody    = "Required: \(reqGB) GB\nAvailable: \(availGB) GB\n\nPlease free up space or select a larger backup drive."
            sendNotification(title: "⚠️ BackupFlow: Space Error", message: logMsg)
            return false
        } catch {
            log("⚠️ Could not verify free space on backup disk: \(error.localizedDescription). Proceeding without the storage guard.\n")
            return true
        }
    }

    /// Runs the Deletion Guard for one task, then syncs it.
    private func syncTask(
        _ task: BackupTask,
        number: Int,
        of count: Int,
        preview: TransferPreview?,
        main mURL: URL,
        secondary sURL: URL,
        checksum: Bool,
        fullDisk: Bool
    ) async -> TaskRunResult {
        guard let preview else {
            skipTask(task)
            return .skipped
        }
        switch await runDeletionGuard(
            preview: preview,
            destination: sURL.appendingPathComponent(task.relativePath),
            label: task.folderName,
            taskID: task.id
        ) {
        case .aborted:
            return .aborted
        case .skipped:
            skipTask(task)
            return .skipped
        case .proceed:
            break
        }

        currentTaskIndex = number
        setStatus(task.id, checksum ? .verifying : .syncing)  // Row transitions to Syncing / Verifying

        // Custom Folders: also resolve the folder's own bookmark for maximum sandbox compatibility
        var folderScopeURL: URL? = nil
        if !fullDisk {
            log("\n▶ [\(number)/\(count)] '\(task.folderName)' (\(task.relativePath))\n")
            if let bookmark = task.bookmarkData {
                do {
                    let resolved = try BookmarkManager.resolveBookmark(bookmark)
                    if resolved.url.startAccessingSecurityScopedResource() { folderScopeURL = resolved.url }
                    if resolved.isStale { refreshTaskBookmark(id: task.id, url: resolved.url) }
                } catch {
                    log("⚠️ Saved access to '\(task.folderName)' could not be restored (\(error.localizedDescription)) — syncing with the disk's access only.\n")
                }
            }
        }

        let outcome = await engine.syncFolder(
            relativePath: task.relativePath,
            mainRoot:     mURL,
            secondaryRoot: sURL,
            useChecksum:  checksum
        ) { [weak self] text in
            Task { @MainActor [weak self] in self?.log(text) }
        } onProgress: { [weak self, id = task.id, targetBytes = task.targetBytes] bytesTransferred in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let fraction = Double(bytesTransferred) / Double(max(1, targetBytes))
                self.updateTaskProgressFraction(id: id, fraction: fraction)
            }
        }

        folderScopeURL?.stopAccessingSecurityScopedResource()

        if isSyncCancelled { return .aborted }

        // Record sync date by absolute path (cross-mode persistence)
        if outcome.didComplete {
            SyncHistoryManager.shared.record(absolutePath: mURL.appendingPathComponent(task.relativePath).path)
        }

        // Count the folder's full weight regardless of outcome — it is no longer pending work.
        completeTaskProgress(id: task.id)

        setStatus(task.id, outcome.didComplete ? .success : .failed, date: outcome.didComplete ? Date() : nil)
        switch outcome {
        case .success:  log("  ✅ Done: \(task.folderName)\n")
        case .warnings: log("  ⚠️ Done with warnings: \(task.folderName)\n")
        case .failure:  log("  ❌ Failed: \(task.folderName)\n")
        }
        return .finished(outcome)
    }

    /// Full Disk final sweep — picks up loose root-level files, hidden top-level folders and
    /// top-level folders that exist only on the backup. The folders synced individually are
    /// excluded: they are already in sync, and excluded folders are also protected from
    /// --delete. rsync emits little or no --progress output while it walks the root, so this
    /// is reported as an indeterminate phase rather than a frozen ring.
    private func sweepRoot(main mURL: URL, secondary sURL: URL, checksum: Bool, excluding syncedFolders: [String]) async -> TaskRunResult {
        currentTaskIndex = totalTasksCount
        syncState = .finalizing
        log("\n▶ [\(totalTasksCount)/\(totalTasksCount)] Sweeping root files...\n")

        let preview: TransferPreview
        do {
            preview = try await engine.previewTransfer(
                from: mURL,
                to: sURL,
                useChecksum: checksum,
                excludingTopLevelFolders: syncedFolders
            )
        } catch {
            if isSyncCancelled { return .aborted }
            log("❌ Could not preview the disk root: \(error.localizedDescription) — the root sweep was skipped.\n")
            return .skipped
        }
        if isSyncCancelled { return .aborted }

        switch await runDeletionGuard(preview: preview, destination: sURL, label: "the disk root", taskID: nil) {
        case .aborted: return .aborted
        case .skipped: return .skipped
        case .proceed: break
        }

        let outcome = await engine.syncEntireDrive(
            from: mURL,
            to: sURL,
            useChecksum: checksum,
            excludingTopLevelFolders: syncedFolders
        ) { [weak self] text in
            Task { @MainActor [weak self] in self?.log(text) }
        }
        if outcome.didComplete { SyncHistoryManager.shared.record(absolutePath: mURL.path) }
        return .finished(outcome)
    }

    private func reportCompletion(_ tally: SyncTally, fullDisk: Bool) {
        if tally.anyFailure {
            log("\n❌ Sync finished with errors.\n")
            playSound(.failure)
        } else if tally.anyWarnings {
            log("\n⚠️ Sync finished with warnings — some files may not have transferred correctly. Check the log above.\n")
            alertTitle = "Sync Completed with Warnings"
            alertBody  = "rsync reported partial-transfer errors for one or more files (permission denied, a file vanishing mid-sync, etc). Check the log console for details."
            playSound(.failure)
        } else {
            log(fullDisk ? "\n✅ Full drive sync complete.\n" : "\n✅ Sync complete.\n")
            playSound(.success)
        }
    }

    func abortSync() {
        Task {
            isSyncCancelled = true
            
            if let cont = deletionContinuation {
                cont.resume(returning: false)
                deletionContinuation = nil
                isReviewingDeletions = false
            }
            
            let wasCalculating = (syncState == .calculating || syncState == .idle)
            await engine.forceStopAll()
            
            if wasCalculating {
                // Return actively calculating tasks to original state
                for i in 0..<tasks.count {
                    if tasks[i].status == .calculating {
                        if let main = mainDriveURL, SyncHistoryManager.shared.date(for: main.appendingPathComponent(tasks[i].relativePath).path) != nil {
                            setStatus(tasks[i].id, .success)
                        } else {
                            setStatus(tasks[i].id, .idle)
                        }
                    }
                }
            } else {
                // Aborted mid-transfer
                for i in 0..<tasks.count {
                    if tasks[i].status == .syncing || tasks[i].status == .verifying || tasks[i].status == .reviewingDeletions {
                        setStatus(tasks[i].id, .aborted)
                    } else if tasks[i].status == .calculating {
                        setStatus(tasks[i].id, .idle)
                    } else if tasks[i].status == .success && i >= currentTaskIndex {
                        // Future tasks that were only temporarily marked .success during calculation phase
                        setStatus(tasks[i].id, .idle)
                    }
                }
            }
            
            syncState = .idle
            // Drop the session before zeroing the ring: in-flight onProgress callbacks can still
            // land after an abort and would otherwise recompute a non-zero progress value.
            sessionFractions = [:]
            sessionWeights = [:]
            globalProgress = 0.0
            log("\n🛑 Sync aborted by user.\n")
            playSound(.failure)
        }
    }

    /// Blocks safely to ensure all background `rsync` processes are killed on app exit.
    nonisolated func terminateOnExit() {
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            await self.engine.forceStopAll()
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 3.0)
    }

    // MARK: - Full Disk Task Scan

    func refreshFullDiskTasks() {
        guard syncEntireDrive, let main = mainDriveURL else { return }

        // A newer scan replaces an older one — e.g. a disk swapped while sizes were still running.
        fullDiskScanTask?.cancel()
        fullDiskScanTask = Task {
            let scopeStarted = main.startAccessingSecurityScopedResource()
            defer { if scopeStarted { main.stopAccessingSecurityScopedResource() } }

            // Listing the top level is cheap, so the rows appear immediately. Folder sizes need a
            // walk over every file and are filled in afterwards, off the main actor.
            let contents: [URL]
            do {
                contents = try FileManager.default.contentsOfDirectory(
                    at: main,
                    includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                self.log("⚠️ Failed to scan main disk: \(error.localizedDescription)\n")
                return
            }

            // Check folder presence on the backup disk ONLY if it is available. If it isn't
            // mounted we don't know whether a folder is missing, so default to false instead of
            // showing false-positive yellow icons.
            let backupRoot = self.secondaryDriveURL.flatMap { self.isVolumeMounted($0) ? $0 : nil }
            let backupStarted = backupRoot?.startAccessingSecurityScopedResource() ?? false
            defer { if backupStarted { backupRoot?.stopAccessingSecurityScopedResource() } }

            var collected: [BackupTask] = []
            for url in contents {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }

                var task = BackupTask(
                    folderName:  url.lastPathComponent,
                    relativePath: url.lastPathComponent,
                    bookmarkData: makeBookmark(for: url)
                )
                if let backupRoot {
                    task.isMissingOnBackup = !FileManager.default.fileExists(
                        atPath: backupRoot.appendingPathComponent(url.lastPathComponent).path
                    )
                }

                // 1. Default state
                task.status = .idle
                task.progress = 0.0

                // 2. Recover persistent 'Synced' status from history
                let absPath = main.appendingPathComponent(task.relativePath).path
                if SyncHistoryManager.shared.date(for: absPath) != nil {
                    task.status = .success
                    task.progress = 1.0
                }

                // 3. Presence check — final priority, always overrides history (v1.7.6)
                if task.isMissingOnBackup {
                    task.status = .idle
                    task.progress = 0.0
                }

                collected.append(task)
            }

            collected.sort { $0.folderName < $1.folderName }
            guard !Task.isCancelled else { return }
            self.tasks = collected

            for task in collected {
                let size = await Self.directorySize(of: main.appendingPathComponent(task.relativePath))
                guard !Task.isCancelled else { return }
                guard let index = self.tasks.firstIndex(where: { $0.id == task.id }) else { continue }
                self.tasks[index].sizeBytes = size
            }
        }
    }

    /// Total size of the visible files under `url`. On a large folder this walks every file, so
    /// it always runs off the main actor (`@concurrent`), and it holds its own security scope
    /// for the duration of the walk. Stops early — returning a partial total the caller must
    /// discard — once its task is cancelled.
    @concurrent
    nonisolated static func directorySize(of url: URL) async -> Int64 {
        let scopeStarted = url.startAccessingSecurityScopedResource()
        defer { if scopeStarted { url.stopAccessingSecurityScopedResource() } }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        while let itemURL = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            if let size = (try? itemURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Notifications (v1.7.6)

    private func sendNotification(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - State Reset (v1.7.6)

    private func resetTaskStates() {
        for i in 0..<tasks.count {
            tasks[i].status       = .idle
            tasks[i].progress     = 0.0
            tasks[i].lastSyncDate = nil
        }
    }

    // MARK: - Sound

    private enum SoundType { case success, failure }

    private func playSound(_ type: SoundType) {
        guard !isMuted else { return }
        switch type {
        case .success: Self.successSound?.play()
        case .failure: Self.failureSound?.play()
        }
    }

    // MARK: - Log

    private static let logFlushInterval: Duration = .milliseconds(150)
    private static let logMaxBytes  = 200_000
    private static let logKeepBytes = 160_000

    /// Lines waiting for the next console refresh, plus whether one is already scheduled.
    private var pendingLog = ""
    private var isLogFlushScheduled = false

    /// Appends to the log file immediately, and to the on-screen console in batches. rsync can
    /// emit thousands of lines a second; publishing each one re-rendered the whole console text
    /// on the main thread every time.
    func log(_ text: String) {
        FileLogger.append(text)
        pendingLog += text
        guard !isLogFlushScheduled else { return }
        isLogFlushScheduled = true
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.logFlushInterval)
            } catch {
                // Cancelled: nothing to wait for, show the pending lines right away.
            }
            self?.flushLog()
        }
    }

    private func flushLog() {
        isLogFlushScheduled = false
        guard !pendingLog.isEmpty else { return }
        logOutput = Self.trimmedLog(logOutput + pendingLog, maxBytes: Self.logMaxBytes, keepBytes: Self.logKeepBytes)
        pendingLog = ""
    }

    /// Keeps the console bounded: once `log` exceeds `maxBytes` of UTF-8, returns its last
    /// `keepBytes` starting at a whole line. Measured in bytes because `String.count` walks the
    /// whole string. A single line longer than the budget falls back to its raw tail, starting
    /// on a character boundary. Pure/testable.
    nonisolated static func trimmedLog(_ log: String, maxBytes: Int, keepBytes: Int) -> String {
        let bytes = log.utf8
        guard bytes.count > maxBytes else { return log }
        let tail = bytes.suffix(keepBytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            let start = bytes.index(after: newline)
            if start < bytes.endIndex { return String(log[start...]) }
        }
        let fromCharacterBoundary = tail.drop { $0 & 0xC0 == 0x80 }  // skip UTF-8 continuation bytes
        return String(decoding: fromCharacterBoundary, as: UTF8.self)
    }

    // MARK: - Task Status & Progress

    /// Begins a new progress session: only the given tasks count toward the global ring,
    /// each weighted by its estimated transfer size. Clears any leftovers from a prior sync.
    private func beginProgressSession(tasks activeTasks: [BackupTask]) {
        sessionFractions = [:]
        sessionWeights = Dictionary(uniqueKeysWithValues: activeTasks.map { ($0.id, max(1, $0.targetBytes)) })
        globalProgress = 0.0
    }

    /// Records a task's progress for this session and recomputes the global ring.
    /// - Parameters:
    ///   - id: The task whose row progress bar to update.
    ///   - fraction: Fraction of this task's estimated bytes transferred so far.
    private func updateTaskProgressFraction(id: UUID, fraction: Double) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            // Per-folder row bar: clamp strictly to 0.99 while running
            tasks[index].progress = min(0.99, max(0.01, fraction))
        }
        sessionFractions[id] = fraction
        recomputeGlobalProgress()
    }

    /// Marks a task as fully finished for this session (counts as 100% of its weight).
    private func completeTaskProgress(id: UUID) {
        sessionFractions[id] = 1.0
        recomputeGlobalProgress()
    }

    private func recomputeGlobalProgress() {
        let value = SyncEngine.weightedProgress(fractions: sessionFractions, weights: sessionWeights)
        // Hold just below 1.0 while work is still running; the caller sets 1.0 on completion.
        globalProgress = min(0.99, value)
    }

    private func setStatus(_ id: UUID, _ status: SyncStatus, date: Date? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = status
        if let d = date { tasks[index].lastSyncDate = d }
        if status == .success { 
            tasks[index].progress = 1.0 
            tasks[index].isMissingOnBackup = false
        }
        if status == .idle { tasks[index].progress = 0.0 }
    }
    
    // MARK: - Deletion Guard

    enum DeletionDecision: Equatable {
        case proceed
        /// Guard off, but the deletions look like a wrong or empty source.
        case blockMassDeletion
        /// Show the per-file confirmation.
        case askUser
        /// Scheduled run with the guard on: nobody may be there to answer, and waiting would
        /// hang the sync forever — skip the folder and ask for a manual run instead.
        case deferUntilManualSync
    }

    /// How the Deletion Guard treats a preview. Pure/testable.
    nonisolated static func deletionDecision(
        for preview: TransferPreview,
        confirmDeletions: Bool,
        unattended: Bool,
        applyToAll: Bool
    ) -> DeletionDecision {
        guard !preview.deletions.isEmpty else { return .proceed }
        guard confirmDeletions else { return preview.isMassDeletion ? .blockMassDeletion : .proceed }
        if applyToAll { return .proceed }
        return unattended ? .deferUntilManualSync : .askUser
    }

    private enum DeletionGuardResult {
        /// Nothing to delete, deletions approved, or routine deletions with the guard off — run the real sync.
        case proceed
        /// The user rejected a deletion or cancelled; the whole sync has been aborted.
        case aborted
        /// The real sync must not run for this source: with the guard off, the preview showed
        /// a mass deletion that looks like a wrong or empty source.
        case skipped
    }

    /// Decides whether the deletions in `preview` may go ahead. With the guard on, the user
    /// confirms each path; a rejection deletes only the paths approved so far, then aborts.
    /// With the guard off, routine deletions proceed but a mass deletion is always blocked.
    private func runDeletionGuard(
        preview: TransferPreview,
        destination: URL,
        label: String,
        taskID: UUID?
    ) async -> DeletionGuardResult {
        switch Self.deletionDecision(for: preview, confirmDeletions: confirmDeletions,
                                     unattended: isUnattendedRun, applyToAll: applyToAllDeletions) {
        case .proceed:
            return .proceed
        case .blockMassDeletion:
            let msg = "\(preview.deletions.count) item(s) would be deleted from \(destination.path) (\(label)) — that looks like a wrong or empty source, so it was skipped. Check that the correct Main disk is connected, or turn on Deletion Guard to review the deletions."
            log("🛑 \(msg)\n")
            alertTitle = "Mass Deletion Blocked"
            alertBody  = msg
            if isUnattendedRun { sendNotification(title: "🛑 BackupFlow: Mass Deletion Blocked", message: msg) }
            return .skipped
        case .deferUntilManualSync:
            let msg = "Scheduled sync skipped \(label): \(preview.deletions.count) deletion(s) need your review. Run Sync manually to confirm them."
            log("⏸ \(msg)\n")
            sendNotification(title: "BackupFlow: Deletions Need Review", message: msg)
            return .skipped
        case .askUser:
            break
        }
        if let taskID { setStatus(taskID, .reviewingDeletions) }

        let deletions = preview.deletions

        deletionQueue = deletions
        approvedPaths.removeAll()
        for (idx, path) in deletions.enumerated() {
            if isSyncCancelled { break }
            currentDeletionIndex = idx
            let approved = await showDeletionConfirmation(for: path)

            if !approved {
                if let taskID { setStatus(taskID, .aborted) }
                for p in approvedPaths { log("🗑️ \(p)\n") }
                let deletionFailures = await engine.deleteExactFiles(absolutePaths: approvedPaths)
                for f in deletionFailures { log("⚠️ Failed to delete: \(f)\n") }
                abortSync()
                return .aborted
            } else if !applyToAllDeletions {
                let dstURL = destination.appendingPathComponent(path)
                approvedPaths.append(dstURL.path)
                log("🗑️ \(dstURL.path)\n")
            } else {
                log("✅ Remaining \(deletions.count - idx) deletion(s) approved — rsync will remove them during the sync.\n")
                break
            }
        }
        isReviewingDeletions = false
        return isSyncCancelled ? .aborted : .proceed
    }

    /// Marks a task that could not be prepared safely as failed; its weight counts as done.
    private func skipTask(_ task: BackupTask) {
        completeTaskProgress(id: task.id)
        setStatus(task.id, .failed)
        log("  ❌ Skipped: \(task.folderName)\n")
    }

    // MARK: - Deletion Confirmation

    func resolveDeletion(approved: Bool, applyToAll: Bool) {
        if applyToAll { applyToAllDeletions = true }
        deletionContinuation?.resume(returning: approved)
        deletionContinuation = nil
        if applyToAllDeletions || !approved {
            isReviewingDeletions = false
        }
    }

    private func showDeletionConfirmation(for path: String) async -> Bool {
        if applyToAllDeletions { return true }
        
        isReviewingDeletions = true
        let approved: Bool = await withCheckedContinuation { continuation in
            self.deletionContinuation = continuation
        }
        return approved
    }

    // MARK: - Helpers

    private func pickFolder(message: String, startingAt dir: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.message               = message
        panel.canChooseDirectories  = true
        panel.canChooseFiles        = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories  = true
        if let dir { panel.directoryURL = dir }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func pickVolume(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message               = message
        panel.canChooseDirectories  = true
        panel.canChooseFiles        = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories  = false
        panel.directoryURL          = URL(fileURLWithPath: "/Volumes")
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let isVol = (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
        if isVol { return url }
        if url.pathComponents.count == 3 && url.path.hasPrefix("/Volumes/") { return url }
        return nil
    }

    // MARK: - Bookmarks

    /// Creates a security-scoped bookmark, logging (instead of silently dropping) a failure.
    private func makeBookmark(for url: URL) -> Data? {
        do {
            return try BookmarkManager.createBookmark(for: url)
        } catch {
            log("⚠️ Could not save access to \(url.path): \(error.localizedDescription). It may need to be re-selected after a relaunch.\n")
            return nil
        }
    }

    /// Resolves a stored drive bookmark, re-creating it when the system reports it stale. A disk
    /// that simply isn't connected is not an error; any other failure is logged.
    private func resolveDriveBookmark(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        let resolved: BookmarkManager.Resolved
        do {
            resolved = try BookmarkManager.resolveBookmark(data)
        } catch {
            if !BookmarkManager.isTargetUnavailable(error) {
                log("⚠️ Saved access to a disk could not be restored: \(error.localizedDescription). Please re-select it.\n")
            }
            return nil
        }
        if resolved.isStale {
            do {
                UserDefaults.standard.set(try BookmarkManager.refreshedBookmark(for: resolved.url), forKey: key)
            } catch {
                log("⚠️ Could not refresh saved access to \(resolved.url.path): \(error.localizedDescription)\n")
            }
        }
        return resolved.url
    }

    /// Replaces a task's stale folder bookmark with a fresh one and persists it.
    private func refreshTaskBookmark(id: UUID, url: URL) {
        do {
            let data = try BookmarkManager.refreshedBookmark(for: url)
            guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[index].bookmarkData = data
            saveTasks()
        } catch {
            log("⚠️ Could not refresh saved access to \(url.path): \(error.localizedDescription)\n")
        }
    }

    // MARK: - Persistence

    private func restoreState() {
        syncEntireDrive = UserDefaults.standard.bool(forKey: Keys.syncMode)

        if let url = resolveDriveBookmark(forKey: Keys.mainBookmark) {
            if verifyVolumeIdentity(url: url, storedUUIDKey: Keys.mainVolumeUUID) {
                mainDriveURL = url
            } else {
                log("🛑 A different disk is now mounted where the Main disk used to be. Please re-select it.\n")
            }
        }

        if let url = resolveDriveBookmark(forKey: Keys.secondaryBookmark) {
            if verifyVolumeIdentity(url: url, storedUUIDKey: Keys.secondaryVolumeUUID) {
                secondaryDriveURL = url
            } else {
                log("🛑 A different disk is now mounted where the Backup disk used to be. Please re-select it.\n")
            }
        }

        if let data    = UserDefaults.standard.data(forKey: Keys.tasks) {
            loadTasksFromDefaults(data: data)
        }

        isMuted = UserDefaults.standard.bool(forKey: Keys.isMuted)
        useChecksum = UserDefaults.standard.bool(forKey: Keys.useChecksum)
    }
    
    // Safely loads the persistent task configuration into the active UI state
    private func loadTasksFromDefaults(data: Data) {
        do {
            let decoded = try JSONDecoder().decode([BackupTask].self, from: data)
            tasks = decoded.map {
                var t = $0
                // Reset UI state that shouldn't persist across launches
                t.isMissingOnBackup = false
                t.progress = 0.0

                // Recover persistent 'Synced' status from history
                if let main = mainDriveURL {
                    let absPath = main.appendingPathComponent(t.relativePath).path
                    if SyncHistoryManager.shared.date(for: absPath) != nil {
                        t.status = .success
                        t.progress = 1.0
                    } else {
                        t.status = .idle
                    }
                } else {
                    t.status = .idle
                }
                return t
            }
        } catch {
            log("⚠️ Failed to load saved tasks: \(error.localizedDescription)\n")
        }
    }
    func saveTasks() {
        do {
            let encoded = try JSONEncoder().encode(tasks)
            UserDefaults.standard.set(encoded, forKey: Keys.tasks)
        } catch {
            log("⚠️ Failed to save tasks: \(error.localizedDescription)\n")
        }
        UserDefaults.standard.set(syncEntireDrive, forKey: Keys.syncMode)
        UserDefaults.standard.set(isMuted, forKey: Keys.isMuted)
        UserDefaults.standard.set(useChecksum, forKey: Keys.useChecksum)
    }

    // MARK: - Schedule Timer

    /// Call this whenever schedule settings might have changed.
    /// Tears down the old timer and starts a new one if configured.
    func setupScheduler() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil

        let enabled  = UserDefaults.standard.bool(forKey: SchKeys.enabled)
        let hours    = UserDefaults.standard.double(forKey: SchKeys.interval)  // stored as Double (hours)
        guard enabled, hours > 0 else { return }

        let interval = hours * 3600
        // Timer fires on the main run loop — safe to call syncAll() which is @MainActor
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSyncing else { return }
                self.syncAll(unattended: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    // MARK: - Disk Availability

    private func handleDriveAvailabilityChange() {
        if mainDriveURL == nil || secondaryDriveURL == nil {
            // UI Cleanup: Wipe the active memory array so the UI renders the Empty State
            // Do NOT call saveTasks() here, we want to retain the UserDefaults configuration.
            fullDiskScanTask?.cancel()  // its rows would belong to a disk that is gone
            tasks = []
        } else {
            // Both disks are valid, reload appropriate context
            if syncEntireDrive {
                refreshFullDiskTasks()
            } else {
                if let data = UserDefaults.standard.data(forKey: Keys.tasks) {
                    loadTasksFromDefaults(data: data)
                }
            }
        }
    }

    /// Checks on launch whether the persisted disk paths still exist.
    /// Clears URLs and task list if paths are unreachable to prevent ghost syncs.
    private func checkDiskAvailability() {
        if let url = mainDriveURL, !FileManager.default.fileExists(atPath: url.path) {
            mainDriveURL = nil
            tasks = []
            log("⚠️ Main disk not available — cleared.\n")
        }
        if let url = secondaryDriveURL, !FileManager.default.fileExists(atPath: url.path) {
            secondaryDriveURL = nil
            log("⚠️ Backup disk not available — cleared.\n")
        }
    }

    // MARK: - Volume Monitor

    private func setupVolumeMonitor() {
        let nc = NSWorkspace.shared.notificationCenter
        
        // Unmount: clear the matching drive URL
        nc.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Without a volume URL there is no way to tell which disk went away — the watchdog
            // still catches a selected disk that really disappeared.
            guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let main = self.mainDriveURL, Self.isURL(main, onVolume: volume) {
                    self.mainDriveURL = nil
                    self.log("⚠️ Main disk unmounted. Task list cleared.\n")
                }
                if let sec = self.secondaryDriveURL, Self.isURL(sec, onVolume: volume) {
                    self.secondaryDriveURL = nil
                    self.log("⚠️ Backup disk unmounted.\n")
                }
            }
        }
        
        // Mount: attempt to restore bookmarks if a newly-mounted volume matches our saved ones
        nc.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tryRestoreBookmarksAfterMount()
            }
        }
    }
    
    // MARK: - Disk Watchdog
    
    private func startDiskWatchdog() {
        diskWatchdogTimer?.invalidate()
        let wt = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.validateDiskConnection()
            }
        }
        RunLoop.main.add(wt, forMode: .common)
        diskWatchdogTimer = wt
    }
    
    /// Uses FileManager to detect physically ejected drives that may not have triggered a notification.
    /// Runs during an active sync too — a disk vanishing mid-transfer is exactly when this matters
    /// most, so instead of clearing state (which would be unsafe mid-sync) it aborts the sync cleanly.
    private func validateDiskConnection() {
        let mainGone = mainDriveURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        let secondaryGone = secondaryDriveURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard mainGone || secondaryGone else { return }

        if isSyncing {
            log("🛑 Watchdog: disk disconnected mid-sync. Aborting.\n")
            abortSync()
            return
        }

        if mainGone {
            log("⚠️ Watchdog: Main disk gone. Clearing.\n")
            mainDriveURL = nil   // triggers didSet → handleDriveAvailabilityChange
        }
        if secondaryGone {
            log("⚠️ Watchdog: Backup disk gone. Clearing.\n")
            secondaryDriveURL = nil
        }
        alertMessage = "A disk was disconnected. Please reconnect to continue."
    }
    
    private func tryRestoreBookmarksAfterMount() {
        var didRestore = false
        if mainDriveURL == nil,
           let url = resolveDriveBookmark(forKey: Keys.mainBookmark),
           FileManager.default.fileExists(atPath: url.path) {
            if verifyVolumeIdentity(url: url, storedUUIDKey: Keys.mainVolumeUUID) {
                mainDriveURL = url
                didRestore = true
            } else {
                log("🛑 A different disk is now mounted where the Main disk used to be. Please re-select it.\n")
            }
        }
        if secondaryDriveURL == nil,
           let url = resolveDriveBookmark(forKey: Keys.secondaryBookmark),
           FileManager.default.fileExists(atPath: url.path) {
            if verifyVolumeIdentity(url: url, storedUUIDKey: Keys.secondaryVolumeUUID) {
                secondaryDriveURL = url
                didRestore = true
            } else {
                log("🛑 A different disk is now mounted where the Backup disk used to be. Please re-select it.\n")
            }
        }
        if didRestore {
            log("✅ Disk reconnected. Sessions restored.\n")
        }
    }
}
