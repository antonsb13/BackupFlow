import Foundation

/// Wraps security-scoped bookmark creation and resolution.
/// Bookmarks persist URL access across app restarts when the app is sandboxed.
enum BookmarkManager {

    struct Resolved {
        let url: URL
        /// The bookmark still works but should be re-created (the item moved or was renamed,
        /// or the system wants a fresh one). Use `refreshedBookmark(for:)` and store the result.
        let isStale: Bool
    }

    /// Creates a security-scoped bookmark for `url`.
    static func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves previously stored bookmark data back into a URL.
    static func resolveBookmark(_ data: Data) throws -> Resolved {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return Resolved(url: url, isStale: isStale)
    }

    /// Re-creates a bookmark for a URL resolved from a stale one. Creating a security-scoped
    /// bookmark requires access to the item, so this opens (and releases) its scope itself.
    static func refreshedBookmark(for url: URL) throws -> Data {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try createBookmark(for: url)
    }

    /// True when resolution failed only because the bookmarked item isn't there right now —
    /// the normal state of a backup disk that simply isn't plugged in, not an error to report.
    static func isTargetUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code)
    }
}
