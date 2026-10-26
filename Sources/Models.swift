import Foundation

struct DevicePort: Equatable {
    let path: String
    let title: String
    let vendorID: Int?
    init(path: String, title: String, vendorID: Int? = nil) {
        self.path = path; self.title = title; self.vendorID = vendorID
    }
}

struct RemoteVolume {
    let name: String
    let path: String
}

struct RemoteEntry {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
}

struct FileTreeRefresh {
    let volumes: [RemoteVolume]
    let directories: [String: Result<[RemoteEntry], Error>]
    var storage: [String: StorageUsage] = [:]
}

struct StorageUsage {
    let path: String
    let totalBytes: Int64
    let freeBytes: Int64
}

struct RemoteDocument {
    let entry: RemoteEntry
    let original: Data
    let text: String
    let connectionID: UUID
}

struct SavedDocument {
    let document: RemoteDocument
    let backupURL: URL
}

struct BackupReport {
    let directory: URL
    let volumes: [String]
    let fileCount: Int
}

enum LogKind: String { case device, transfer, info, error }
struct LogEvent {
    let kind: LogKind
    let text: String
}

enum M5Error: LocalizedError {
    case message(String)
    case fileExists(String)
    case filesystem(path: String, code: Int)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .fileExists(let path): return L("Bereits vorhanden: {0}. Zum Ersetzen bitte ausdrücklich bestätigen.", String(describing: (path)))
        case .filesystem(let path, let code):
            if code == 19 {
                return L("Der Speicher für «{0}» ist momentan nicht verfügbar (ENODEV). Falls der Pfad auf der SD-Karte liegt: Karte und Einbindung auf dem M5 prüfen, danach erneut aktualisieren.", String(describing: (path)))
            }
            if code == 2 { return L("«{0}» ist nicht mehr vorhanden. Bitte den Dateibaum aktualisieren.", String(describing: (path))) }
            return L("Dateisystemzugriff auf «{0}» fehlgeschlagen (Fehler {1}).", String(describing: (path)), String(describing: (code)))
        }
    }
}

func remoteJoin(_ parent: String, _ child: String) -> String {
    (parent == "/" ? "" : parent) + "/" + child
}

// A hash establishes equality; the known base establishes which side changed.
enum SyncComparison: String {
    case equal = "✅ Aktuell"
    case localChanged = "🟡 Lokal geändert"
    case remoteChanged = "🔴 M5 geändert"
    case conflict = "⚠️ Beide geändert"
    static func compare(base: String, local: String, remote: String) -> SyncComparison {
        if local == remote { return .equal }
        if remote == base { return .localChanged }
        if local == base { return .remoteChanged }
        return .conflict
    }
}

struct CSVPreview {
    static func parse(_ text: String) throws -> [[String]] {
        guard text.utf8.count <= 1_048_576 else { throw M5Error.message(L("CSV-Vorschau ist auf 1 MiB begrenzt.")) }
        let chars = Array(text)
        // Choose delimiter from the first record, ignoring separators in quotes.
        var quoted = false, commas = 0, semicolons = 0
        for ch in chars {
            if ch == "\"" { quoted.toggle() }
            if !quoted {
                if ch == "\n" || ch == "\r" || ch == "\r\n" { break }
                if ch == "," { commas += 1 }; if ch == ";" { semicolons += 1 }
            }
        }
        let delimiter: Character = semicolons > commas ? ";" : ","
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inside = false, closed = false, i = 0
        func finishField() throws {
            row.append(field); field = ""; closed = false
            guard row.count <= 128 else { throw M5Error.message(L("CSV hat mehr als 128 Spalten.")) }
        }
        func finishRow() throws {
            try finishField(); rows.append(row); row = []
            guard rows.count <= 5000 else { throw M5Error.message(L("CSV hat mehr als 5000 Zeilen.")) }
        }
        while i < chars.count {
            let ch = chars[i]
            if inside {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inside = false; closed = true }
                } else { field.append(ch) }
            } else if ch == delimiter { try finishField() }
            else if ch == "\n" || ch == "\r" || ch == "\r\n" {
                try finishRow()
                if ch == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
            } else if ch == "\"" && field.isEmpty && !closed { inside = true }
            else {
                guard !closed, ch != "\"" else { throw M5Error.message(L("Ungültige CSV-Anführungszeichen.")) }
                field.append(ch)
            }
            i += 1
        }
        guard !inside else { throw M5Error.message(L("CSV-Anführungszeichen nicht geschlossen.")) }
        if !field.isEmpty || !row.isEmpty || closed { try finishRow() }
        return rows
    }
}

struct LiveSnapshot: Equatable {
    let files: [String: Data]
    static func read(root: URL) throws -> LiveSnapshot {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try root.resourceValues(forKeys: keys)
        guard values.isDirectory == true, values.isSymbolicLink != true,
              root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw M5Error.message(L("Live-Sync braucht einen vorhandenen Ordner ohne Symlink-Pfad."))
        }
        var files: [String: Data] = [:], total = 0, entries = 0
        func visit(_ directory: URL, prefix: String, depth: Int) throws {
            guard depth <= 16 else { throw M5Error.message(L("Live-Sync: mehr als 16 Ordnerebenen.")) }
            for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
                entries += 1
                guard entries <= 512 else { throw M5Error.message(L("Live-Sync: mehr als 512 Einträge.")) }
                let v = try url.resourceValues(forKeys: keys)
                guard v.isSymbolicLink != true else { throw M5Error.message(L("Live-Sync verfolgt keine Symlinks: {0}", String(describing: (url.path)))) }
                let name = prefix + url.lastPathComponent
                if v.isDirectory == true { try visit(url, prefix: name + "/", depth: depth + 1) }
                else if v.isRegularFile == true {
                    guard (v.fileSize ?? Int.max) <= 1_048_576 else { throw M5Error.message(L("Live-Sync: Datei über 1 MiB: {0}", String(describing: (name)))) }
                    let data = try Data(contentsOf: url)
                    total += data.count
                    guard data.count <= 1_048_576, total <= 8 * 1_048_576, files.count < 128 else {
                        throw M5Error.message(L("Live-Sync: maximal 128 Dateien / 8 MiB insgesamt."))
                    }
                    files[name] = data
                } else { throw M5Error.message(L("Live-Sync: Sonderdatei nicht unterstützt: {0}", String(describing: (name)))) }
            }
        }
        try visit(root, prefix: "", depth: 0)
        return LiveSnapshot(files: files)
    }
}

struct JSONPreview {
    /// Validate syntax, then format the original tokens without converting numbers.
    static func format(_ data: Data) throws -> String {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw M5Error.message(L("JSON-Vorschau unterstützt UTF-8 bis 1 MiB."))
        }
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let chars = Array(text)
        var output = "", level = 0, inside = false, escaped = false
        var previous: Character?
        func line() { output += "\n" + String(repeating: "  ", count: level) }
        for i in chars.indices {
            let ch = chars[i]
            if inside {
                output.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inside = false }
                continue
            }
            if ch.isWhitespace { continue }
            switch ch {
            case "\"": inside = true; output.append(ch)
            case "{", "[":
                output.append(ch); level += 1
                let next = chars[(i + 1)...].first { !$0.isWhitespace }
                if next != "}" && next != "]" { line() }
            case "}", "]":
                level -= 1
                if previous != "{" && previous != "[" { line() }
                output.append(ch)
            case ",": output.append(ch); line()
            case ":": output += ": "
            default: output.append(ch)
            }
            previous = ch
        }
        return output
    }
}
