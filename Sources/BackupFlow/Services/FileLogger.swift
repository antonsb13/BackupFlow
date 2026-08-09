import Foundation

/// Appends sync log lines to a rotating file under ~/Library/Logs/BackupFlow so a crashed
/// or force-quit sync can still be diagnosed after the in-memory log console is gone.
enum FileLogger {
    private static let maxBytes = 2 * 1024 * 1024 // rotate at 2 MB, keep one previous file

    private static let logsDirectory: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BackupFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var currentLogURL: URL { logsDirectory.appendingPathComponent("backupflow.log") }
    private static let queue = DispatchQueue(label: "com.backupflow.filelogger")

    static func append(_ text: String) {
        queue.async {
            rotateIfNeeded()
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: currentLogURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: currentLogURL)
            }
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: currentLogURL.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        let backupURL = logsDirectory.appendingPathComponent("backupflow.previous.log")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: currentLogURL, to: backupURL)
    }
}
