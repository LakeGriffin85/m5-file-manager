import Foundation

private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

@main
struct DeletionBackupTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("m5-delete-preferences-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }
        let defaults = MemoryDefaults()
        let preferences = DeletionBackupPreferences(defaults: defaults)
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
            checks += 1
        }
        func refused(_ url: URL) {
            do { try preferences.select(url); fatalError("Invalid selection accepted: \(url)") }
            catch { checks += 1 }
        }
        expect(preferences.directory.path == DeletionBackupPreferences.defaultPath, "Requested initial default")
        expect(DeletionBackupPreferences.defaultPath == fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/M5 File Manager/Deletion Backups").path, "Default belongs to current user's Application Support")
        for custom in [temporary.appendingPathComponent("Custom Backups").path, "/Volumes/ExampleBackup/M5"] {
            defaults.set(custom, forKey: DeletionBackupPreferences.preferenceKey)
            expect(preferences.directory.path == custom, "Custom destination is preserved")
            expect(defaults.string(forKey: DeletionBackupPreferences.preferenceKey) == custom, "Custom override is unchanged")
        }
        try preferences.select(temporary)
        expect(preferences.directory == temporary.standardizedFileURL, "Selection used immediately")
        expect(DeletionBackupPreferences(defaults: defaults).directory == temporary.standardizedFileURL, "Choice survives a new preferences instance")
        expect(DeletionBackupPreferences(defaults: MemoryDefaults()).directory.path == DeletionBackupPreferences.defaultPath, "Another Mac has an independent default")
        let regularFile = temporary.appendingPathComponent("file.txt")
        try Data("preserved".utf8).write(to: regularFile)
        refused(regularFile)
        refused(temporary.appendingPathComponent("missing", isDirectory: true))
        refused(URL(string: "https://example.invalid/backup")!)
        expect(preferences.directory == temporary.standardizedFileURL, "Rejected choice preserves previous folder")
        defaults.set("relative/path", forKey: DeletionBackupPreferences.preferenceKey)
        expect(preferences.directory.path == DeletionBackupPreferences.defaultPath, "Invalid saved relative path cannot redirect backup")
        defaults.set("/bad\0path", forKey: DeletionBackupPreferences.preferenceKey)
        expect(preferences.directory.path == DeletionBackupPreferences.defaultPath, "Invalid saved NUL path rejected")
        let unavailable = temporary.appendingPathComponent("disconnected-volume", isDirectory: true)
        defaults.set(unavailable.path, forKey: DeletionBackupPreferences.preferenceKey)
        expect(preferences.directory == unavailable.standardizedFileURL, "Unavailable saved destination is shown without silently falling back")
        expect(!fm.fileExists(atPath: unavailable.path), "Reading preferences never creates an unavailable folder")
        print("SUCCESS: \(checks) deletion-backup preference checks; in-memory preferences, no real device access")
    }
}
