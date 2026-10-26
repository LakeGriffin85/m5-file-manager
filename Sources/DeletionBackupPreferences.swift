import Foundation

/// A machine-local choice for copies made before deleting files from the M5.
final class DeletionBackupPreferences {
    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/M5 File Manager/Deletion Backups", isDirectory: true).path
    }
    static let preferenceKey = "deletionBackupDirectoryPath"
    private let preferences: UserDefaults

    init(defaults: UserDefaults = .standard) {
        preferences = defaults
    }

    var directory: URL {
        let saved = preferences.string(forKey: Self.preferenceKey)
        let path = saved.flatMap { $0.hasPrefix("/") && !$0.contains("\0") ? $0 : nil } ?? Self.defaultPath
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        return directory
    }

    func select(_ url: URL) throws {
        guard url.isFileURL else {
            throw M5Error.message(L("Bitte einen Ordner auf diesem Mac oder einem eingebundenen Laufwerk auswählen."))
        }
        let directory = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw M5Error.message(L("Der Sicherungsordner ist nicht erreichbar. Bitte einen vorhandenen Ordner auswählen."))
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw M5Error.message(L("Der Sicherungsordner ist nicht beschreibbar. Bitte einen anderen Ordner auswählen."))
        }
        preferences.set(directory.path, forKey: Self.preferenceKey)
    }
}
