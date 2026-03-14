import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("BackupFlow_BackupFlow.bundle").path
        let buildPath = "/Users/antonborodin/.gemini/antigravity/playground/metallic-oort/.build/arm64-apple-macosx/debug/BackupFlow_BackupFlow.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}