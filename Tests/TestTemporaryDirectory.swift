import Foundation

enum TestTemporaryDirectory {
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["MOONLIGHT_TEST_TMPDIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }
}
