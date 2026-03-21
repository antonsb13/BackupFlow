import AppKit

extension NSAlert {

    /// Presents a critical-style NSAlert as a sheet on `window`, or modally if `window` is nil.
    static func showCriticalSheet(title: String, informativeText: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText     = title
        alert.informativeText = informativeText
        alert.alertStyle      = .critical
        alert.addButton(withTitle: "OK")

        if let window = window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
