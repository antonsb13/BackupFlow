import Foundation

/// Wraps security-scoped bookmark creation and resolution.
/// Bookmarks persist URL access across app restarts when the app is sandboxed.
enum BookmarkManager {

    /// Creates a security-scoped bookmark for `url`.
    /// Returns `nil` if the app is not sandboxed or creation fails.
    static func createBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            return nil
        }
    }

    /// Resolves previously stored bookmark data back into a URL.
    static func resolveBookmark(_ data: Data) -> URL? {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // Return URL anyway; caller might try to re-bookmark it on next successful access
            }
            return url
        } catch {
            return nil
        }
    }
}
