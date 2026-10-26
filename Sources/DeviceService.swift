import Foundation
import CryptoKit

/// A single serial queue owns the port. AppKit only receives main-queue callbacks.
final class DeviceService {
    var onLog: ((String) -> Void)?
    var onLogEvent: ((LogEvent) -> Void)?
    var onState: ((String) -> Void)?
    var onConnection: ((Bool) -> Void)?
    var onBusy: ((Bool) -> Void)?
    var onRefresh: (() -> Void)?
    var onRestart: (() -> Void)?
    var onProgress: ((Double) -> Void)?
    var onProgramStarted: ((String) -> Void)?
    let backupDirectory: URL
    private(set) var connected = false
    private(set) var busy = false
    private let queue = DispatchQueue(label: "org.m5filemanager.desktop.serial")
    private let board: BoardSession
    private var timer: DispatchSourceTimer?
    private var queueConnected = false
    private var pending = 0
    private var connectionID = UUID()
    private let sessionLock = NSLock()
    private var runtimeEpoch = UUID()
    private struct LiveState {
        let token: UUID
        let directory: String
        var originals: [String: Data] = [:]
            }
    private var liveState: LiveState?

    init(board: BoardSession = BoardSession(), backupDirectory: URL? = nil) {
        self.board = board
        self.backupDirectory = backupDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/M5 File Manager/Safety Backups", isDirectory: true)
        board.onOutput = { [weak self] text in self?.log(text, kind: .device) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.queueConnected else { return }
            do { try self.board.pollOutput() }
            catch {
                self.board.disconnect()
                self.queueConnected = false
                self.invalidateSession()
                self.log(L("\nVerbindung verloren: {0}\n", String(describing: (error.localizedDescription))), kind: .error)
                self.main {
                    self.connected = false
                    self.onConnection?(false)
                    self.onState?(L("Verbindung verloren – USB prüfen"))
                }
            }
        }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }
    func ports() -> [DevicePort] { BoardSession.availablePorts() }
    private func main(_ action: @escaping () -> Void) { DispatchQueue.main.async(execute: action) }
    private func log(_ text: String, kind: LogKind = .info) {
        main { self.onLog?(text); self.onLogEvent?(LogEvent(kind: kind, text: text)) }
    }

    private func perform<T>(_ label: String, action: @escaping () throws -> T,
                            completion: @escaping (Result<T, Error>) -> Void) {
        pending += 1
        busy = true
        onBusy?(true)
        onState?(label)
        queue.async {
            let result = Result { try action() }
            self.main {
                self.pending -= 1
                self.busy = self.pending > 0
                self.onBusy?(self.busy)
                if case .failure(let error) = result {
                    self.onLog?("\n⚠ \(error.localizedDescription)\n")
                    self.onLogEvent?(LogEvent(kind: .error, text: "\n⚠ \(error.localizedDescription)\n"))
                    self.onState?(L("Aktion fehlgeschlagen"))
                } else if !self.busy {
                    self.onState?(self.connected ? L("Verbunden") : L("Getrennt"))
                }
                completion(result)
            }
        }
    }

    func connect(path: String, completion: @escaping (Result<[RemoteVolume], Error>) -> Void) {
        perform(L("Verbinde und lese Speicher …"), action: {
            self.board.disconnect()
            self.queueConnected = false
            self.invalidateSession()
            do {
                try self.board.connect(path: path)
                let volumes = try self.board.volumes()
                self.queueConnected = true
                self.log(L("\nVerbunden: {0}\nDateizugriff hat das laufende Python-Programm angehalten. «Neu starten» startet MicroPython neu.\n", String(describing: (path))))
                return volumes
            } catch {
                self.board.disconnect()
                throw error
            }
        }, completion: { result in
            if case .success = result { self.connected = true }
            else { self.connected = false }
            self.onConnection?(self.connected)
            if self.connected { self.onState?(L("Verbunden · Programm angehalten")) }
            completion(result)
        })
    }

    func disconnect() {
        perform(L("Trenne …"), action: {
            self.queueConnected = false
            self.invalidateSession()
            self.board.disconnect()
        }, completion: { _ in
            self.connected = false
            self.onConnection?(false)
            self.onState?(L("Getrennt"))
            self.onLog?(L("\nGetrennt. Ein angehaltenes Programm bleibt angehalten.\n"))
            self.onLogEvent?(LogEvent(kind: .info, text: L("\nGetrennt. Ein angehaltenes Programm bleibt angehalten.\n")))
        })
    }

    private func requireConnection() throws {
        guard queueConnected else { throw M5Error.message(L("Bitte zuerst mit einem M5 verbinden.")) }
    }

    // Runtime invalidation is written on the serial queue and sampled at UI submission.
    // The lock avoids reading worker-owned connectionID from the main queue.
    private func sessionEpoch() -> UUID {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return runtimeEpoch
    }

    private func invalidateSession() {
        liveState = nil
        connectionID = UUID()
        sessionLock.lock()
        runtimeEpoch = UUID()
        sessionLock.unlock()
    }

    private func requireSession(_ expected: UUID) throws {
        guard sessionEpoch() == expected else {
            throw M5Error.message(L("Die Gerätesitzung hat sich seit der Auswahl geändert. Bitte aktualisieren und erneut auswählen."))
        }
    }

    func list(path: String, completion: @escaping (Result<[RemoteEntry], Error>) -> Void) {
        perform(L("Lese {0} …", String(describing: (path))), action: {
            try self.requireConnection()
            return try self.board.list(path: path)
        }, completion: completion)
    }

    func refresh(paths: [String], completion: @escaping (Result<FileTreeRefresh, Error>) -> Void) {
        perform(L("Prüfe Speicher und aktualisiere Dateien …"), action: {
            try self.requireConnection()
            var snapshot = try self.board.refreshDirectories(paths: paths)
            for volume in snapshot.volumes {
                do { snapshot.storage[volume.path] = try self.board.storage(path: volume.path) }
                catch { self.log(L("Speichergrösse für {0} unbekannt: {1}\n", String(describing: (volume.path)), String(describing: (error.localizedDescription))), kind: .error) }
            }
            return snapshot
        }, completion: completion)
    }

    func mountSDCard(completion: @escaping (Result<String, Error>) -> Void) {
        perform(L("Binde SD-Karte ein …"), action: {
            try self.requireConnection()
            let message = try self.board.mountSDCard()
            self.log("✓ \(message)\n")
            return message
        }, completion: completion)
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw M5Error.message(L("Ungültiger Dateiname: {0}", String(describing: (name))))
        }
    }

    private func validateLocalTree(_ url: URL, depth: Int = 0) throws {
        guard depth < 64 else { throw M5Error.message(L("Ordner ist zu tief verschachtelt.")) }
        try validateName(url.lastPathComponent)
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else {
            throw M5Error.message(L("Symbolische Links werden nicht kopiert: {0}", String(describing: (url.lastPathComponent))))
        }
        if values.isDirectory == true {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try validateLocalTree(child, depth: depth + 1)
            }
        } else if values.isRegularFile != true {
            throw M5Error.message(L("Keine reguläre Datei: {0}", String(describing: (url.lastPathComponent))))
        }
    }

    private func progress(_ value: Double) { main { self.onProgress?(value) } }

    func upload(urls: [URL], to directory: String, overwrite: Bool,
                completion: @escaping (Result<Void, Error>) -> Void) {
        perform(L("Kopiere auf den M5 …"), action: {
            try self.requireConnection()
            var names = Set<String>()
            let existing = try self.board.list(path: directory)
            for url in urls {
                try self.validateLocalTree(url)
                guard names.insert(url.lastPathComponent).inserted else {
                    throw M5Error.message(L("Mehrere Quelldateien heissen {0}. Bitte einzeln kopieren.", String(describing: (url.lastPathComponent))))
                }
                if !overwrite && existing.contains(where: { $0.name == url.lastPathComponent }) {
                    throw M5Error.fileExists(remoteJoin(directory, url.lastPathComponent))
                }
            }
            for url in urls {
                try self.uploadTree(url, remotePath: remoteJoin(directory, url.lastPathComponent), overwrite: overwrite)
            }
            self.log(L("\n✓ Upload abgeschlossen ({0} Auswahl(en)). Originale bleiben auf dem Mac.\n", String(describing: (urls.count))))
        }, completion: { result in
            self.onProgress?(0)
            if case .success = result { self.onRefresh?() }
            completion(result)
        })
    }

    private func uploadTree(_ url: URL, remotePath: String, overwrite: Bool) throws {
        let isDir = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if !isDir {
            self.log("↑ \(remotePath)\n", kind: .transfer)
            try board.upload(localURL: url, remotePath: remotePath, overwrite: overwrite, progress: progress)
            return
        }
        let parent = (remotePath as NSString).deletingLastPathComponent
        let name = (remotePath as NSString).lastPathComponent
        let existing = try board.list(path: parent.isEmpty ? "/" : parent).first { $0.name == name }
        if let existing = existing {
            guard overwrite else { throw M5Error.fileExists(remotePath) }
            guard existing.isDirectory else { throw M5Error.message(L("Ziel ist eine Datei statt ein Ordner: {0}", String(describing: (remotePath)))) }
        } else {
            try board.createDirectory(path: remotePath)
        }
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try uploadTree(child, remotePath: remoteJoin(remotePath, child.lastPathComponent), overwrite: overwrite)
        }
    }

    func download(entry: RemoteEntry, to directory: URL, overwrite: Bool,
                  completion: @escaping (Result<URL, Error>) -> Void) {
        let expectedSession = sessionEpoch()
        perform(L("Kopiere auf den Mac …"), action: {
            try self.requireConnection()
            try self.requireSession(expectedSession)
            try self.validateName(entry.name)
            let destination = directory.appendingPathComponent(entry.name)
            if FileManager.default.fileExists(atPath: destination.path) && !overwrite {
                throw M5Error.fileExists(destination.path)
            }
            if !entry.isDirectory {
                self.log("↓ \(entry.path)\n", kind: .transfer)
                try self.board.download(remotePath: entry.path, localURL: destination, overwrite: overwrite, progress: self.progress)
            } else {
                let staging = directory.appendingPathComponent(".m5download-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: staging) }
                try self.downloadTree(entry.path, to: staging)
                try self.commitDirectory(staging, destination: destination, overwrite: overwrite)
            }
            self.log(L("\n✓ Download: {0}\nOriginal bleibt auf dem M5.\n", String(describing: (destination.path))))
            return destination
        }, completion: { result in
            self.onProgress?(0)
            completion(result)
        })
    }

    @discardableResult
    private func downloadTree(_ path: String, to directory: URL, depth: Int = 0,
                              excluding: Set<String> = [], onFileCopied: (() -> Void)? = nil) throws -> Int {
        guard depth < 64 else { throw M5Error.message(L("Ordner ist zu tief verschachtelt; möglicher Verweis-Kreis.")) }
        var count = 0
        for entry in try board.list(path: path) {
            if excluding.contains(entry.path) { continue }
            try validateName(entry.name)
            let local = directory.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
                count += try downloadTree(entry.path, to: local, depth: depth + 1, excluding: excluding, onFileCopied: onFileCopied)
            } else {
                log("↓ \(entry.path)\n", kind: .transfer)
                try board.download(remotePath: entry.path, localURL: local, overwrite: false, progress: progress)
                count += 1
                onFileCopied?()
            }
        }
        return count
    }

    private func commitDirectory(_ staging: URL, destination: URL, overwrite: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            guard overwrite else { throw M5Error.fileExists(destination.path) }
            let backup = destination.deletingLastPathComponent().appendingPathComponent(".m5backup-" + UUID().uuidString)
            try fm.moveItem(at: destination, to: backup)
            do { try fm.moveItem(at: staging, to: destination) }
            catch {
                do { try fm.moveItem(at: backup, to: destination) }
                catch { throw M5Error.message(L("Wiederherstellung fehlgeschlagen. Original liegt weiterhin unter {0}.", String(describing: (backup.path)))) }
                throw error
            }
            do { try fm.removeItem(at: backup) }
            catch { log(L("Kopie fertig; Sicherung konnte nicht entfernt werden: {0}\n", String(describing: (backup.path)))) }
        } else { try fm.moveItem(at: staging, to: destination) }
    }

    func mkdir(path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        perform(L("Erstelle Ordner …"), action: {
            try self.requireConnection()
            try self.validateName((path as NSString).lastPathComponent)
            try self.board.createDirectory(path: path)
        }, completion: { result in
            if case .success = result { self.onRefresh?() }
            completion(result)
        })
    }

    // Text editing is pinned to one stopped-board session and one exact revision.
    func previewImage(entry: RemoteEntry, completion: @escaping (Result<Data, Error>) -> Void) {
        perform(L("Lese Bildvorschau …"), action: {
            try self.requireConnection()
            return try self.board.readFile(path: entry.path, maxBytes: 8 * 1_048_576, progress: self.progress)
        }, completion: completion)
    }

    func openDocument(entry: RemoteEntry, completion: @escaping (Result<RemoteDocument, Error>) -> Void) {
        perform(L("Lese Vorschau …"), action: {
            try self.requireConnection()
            guard !entry.isDirectory else { throw M5Error.message(L("Bitte eine Textdatei auswählen.")) }
            let started = ProcessInfo.processInfo.systemUptime
            let data = try self.board.readFile(path: entry.path, maxBytes: 1_048_576, progress: { value in
                self.progress(value)
                self.main { self.onState?(L("Lese Vorschau … {0} %", String(describing: (Int(value * 100))))) }
            })
            self.log(String(format: L("Vorschau gelesen: %d Bytes in %.2f s\n"), data.count, ProcessInfo.processInfo.systemUptime - started), kind: .transfer)
            guard let text = String(data: data, encoding: .utf8), !data.contains(0) else {
                throw M5Error.message(L("Diese Datei ist keine UTF-8-Textdatei. Bitte zum Öffnen auf den Mac kopieren."))
            }
            let current = RemoteEntry(name: entry.name, path: entry.path, isDirectory: false, size: Int64(data.count))
            return RemoteDocument(entry: current, original: data, text: text, connectionID: self.connectionID)
        }, completion: completion)
    }

    private func liveOriginal(_ path: String) throws -> Data? {
        do { return try board.readFile(path: path, maxBytes: 1_048_576) }
        catch M5Error.filesystem(_, let code) where code == 2 { return nil }
    }

    func beginLiveSync(_ snapshot: LiveSnapshot, to directory: String,
                       completion: @escaping (Result<UUID, Error>) -> Void) {
        let expected = sessionEpoch()
        perform(L("Lese Ausgangsstand für Live-Sync …"), action: {
            try self.requireConnection(); try self.requireSession(expected)
            _ = try self.board.list(path: directory)
            var state = LiveState(token: UUID(), directory: directory)
            var originalBytes = 0
            for name in snapshot.files.keys.sorted() {
                let path = remoteJoin(directory, name)
                if let data = try self.liveOriginal(path) {
                    originalBytes += data.count
                    guard originalBytes <= 8 * 1_048_576 else { throw M5Error.message(L("Live-Sync: M5-Ausgangsstand über 8 MiB.")) }
                    state.originals[name] = data
                }
            }
            self.liveState = state
            return state.token
        }, completion: completion)
    }

    func liveSync(_ snapshot: LiveSnapshot, names: [String], token: UUID,
                  completion: @escaping (Result<Void, Error>) -> Void) {
        perform(L("Live-Sync: übertragen und neu starten …"), action: {
            try self.requireConnection()
            guard var state = self.liveState, state.token == token else {
                throw M5Error.message(L("Live-Sync-Sitzung beendet. Bitte neu aktivieren."))
            }
            _ = try self.board.list(path: state.directory)
            // Preflight the entire batch before changing any file.
            for name in names {
                guard snapshot.files[name] != nil, !name.hasPrefix("/"),
                      !name.split(separator: "/").contains("..") else { throw M5Error.message(L("Ungültiger Live-Sync-Pfad.")) }
                let current = try self.liveOriginal(remoteJoin(state.directory, name))
                if let original = state.originals[name] {
                    guard current == original else { throw M5Error.message(L("Live-Sync-Konflikt: M5-Datei geändert: {0}", String(describing: (name)))) }
                } else {
                    // Files created locally after enabling may only create absent remote names.
                    guard current == nil else { throw M5Error.message(L("Live-Sync-Konflikt: neues Ziel existiert: {0}", String(describing: (name)))) }
                }
            }
            for name in names {
                guard let data = snapshot.files[name] else { continue }
                let path = remoteJoin(state.directory, name)
                let old = state.originals[name]
                if old == data { continue }
                if let old {
                    let entry = RemoteEntry(name: (name as NSString).lastPathComponent, path: path, isDirectory: false, size: Int64(old.count))
                    _ = try self.backupData(old, entry: entry, reason: "Vor-Live-Sync")
                }
                guard try self.liveOriginal(path) == old else { throw M5Error.message(L("Live-Sync-Konflikt während Sicherung: {0}", String(describing: (name)))) }
                var parent = state.directory
                for component in name.split(separator: "/").dropLast() {
                    parent = remoteJoin(parent, String(component))
                    try self.board.createDirectory(path: parent)
                }
                try self.uploadData(data, path: path, overwrite: old != nil)
                guard try self.board.readFile(path: path, maxBytes: 1_048_576) == data else {
                    throw M5Error.message(L("Live-Sync-Rückleseprüfung fehlgeschlagen: {0}", String(describing: (name))))
                }
                state.originals[name] = data
                self.log(L("✓ Live-Sync-Datei: {0}\n", String(describing: (path))), kind: .transfer)
            }
            self.invalidateSession()
            try self.board.restart()
            self.liveState = state
            self.log(L("✓ Live-Sync: {0} Dateien geprüft; Neustart angefordert.\n", String(describing: (names.count))), kind: .transfer)
        }, completion: { result in
            if case .success = result { self.onRestart?() }
            completion(result)
        })
    }

    func checkDocument(_ document: RemoteDocument, text: String,
                       completion: @escaping (Result<SyncComparison, Error>) -> Void) {
        perform(L("Prüfe SHA-256 auf dem M5 …"), action: {
            try self.requireConnection()
            guard document.connectionID == self.connectionID else {
                throw M5Error.message(L("Die Gerätesitzung hat gewechselt. Bitte Datei neu öffnen."))
            }
            return SyncComparison.compare(base: Self.hash(document.original),
                                          local: Self.hash(Data(text.utf8)),
                                          remote: try self.board.sha256(path: document.entry.path))
        }, completion: completion)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func saveDocument(_ document: RemoteDocument, text: String,
                      completion: @escaping (Result<SavedDocument, Error>) -> Void) {
        perform(L("Sichere Original und speichere Datei …"), action: {
            try self.requireConnection()
            guard document.connectionID == self.connectionID else {
                throw M5Error.message(L("Die Verbindung oder das laufende Programm hat gewechselt. Text lokal sichern und die Datei neu vom M5 öffnen."))
            }
            let data = Data(text.utf8)
            guard data.count <= 1_048_576, !data.contains(0) else {
                throw M5Error.message(L("Der Editor unterstützt UTF-8-Text bis 1 MiB ohne Nullzeichen."))
            }
            let current = try self.board.readFile(path: document.entry.path, maxBytes: 1_048_576)
            guard current == document.original else {
                throw M5Error.message(L("Die Datei auf dem M5 wurde inzwischen geändert. Nichts überschrieben. Text auf dem Mac sichern und die aktuelle Datei neu öffnen."))
            }
            let backup = try self.backupData(current, entry: document.entry, reason: "Vor-Bearbeiten")
            // Recheck after the local backup; a second USB/network client must
            // not silently lose an edit while we write to a slow Mac volume.
            guard try self.board.readFile(path: document.entry.path, maxBytes: 1_048_576) == current else {
                throw M5Error.message(L("Die M5-Datei hat sich während der Sicherung geändert. Nichts überschrieben. Sicherung: {0}", String(describing: (backup.path))))
            }
            try self.uploadData(data, path: document.entry.path, overwrite: true)
            let entry = RemoteEntry(name: document.entry.name, path: document.entry.path, isDirectory: false, size: Int64(data.count))
            self.log(L("✓ Gespeichert: {0} · Original: {1}\n", String(describing: (entry.path)), String(describing: (backup.path))), kind: .transfer)
            return SavedDocument(document: RemoteDocument(entry: entry, original: data, text: text,
                                                          connectionID: self.connectionID), backupURL: backup)
        }, completion: { result in
            self.onProgress?(0)
            if case .success = result { self.onRefresh?() }
            completion(result)
        })
    }

    func backup(includeSD: Bool, to parent: URL, completion: @escaping (Result<BackupReport, Error>) -> Void) {
        perform(L("Sichere M5-Dateien auf dem Mac …"), action: {
            try self.requireConnection()
            let available = try self.board.volumes()
            if includeSD && !available.contains(where: { $0.path == "/sd" }) {
                throw M5Error.message(L("Die gewünschte SD-Karte ist nicht verfügbar. Für eine reine Flash-Sicherung die SD-Auswahl ausschalten."))
            }
            let volumes = available.filter { includeSD || $0.path != "/sd" }
            let locations = try self.backupLocations(parent: parent, label: "M5-Dateien")
            var completed: [String] = []
            var count = 0
            do {
                try self.writeManifest(at: locations.staging, state: "unvollstaendig", paths: volumes.map(\.path), completed: completed, fileCount: count)
                for volume in volumes {
                    let target = locations.staging.appendingPathComponent(volume.path == "/sd" ? "SD" : "Flash", isDirectory: true)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                    // A root-mounted Flash can contain /sd. Copy that mount
                    // once, separately, and only when SD was requested.
                    try self.downloadTree(volume.path, to: target, excluding: volume.path == "/" ? ["/sd"] : [], onFileCopied: { count += 1 })
                    completed.append(volume.path)
                    try self.writeManifest(at: locations.staging, state: "unvollstaendig", paths: volumes.map(\.path), completed: completed, fileCount: count)
                }
                try self.writeManifest(at: locations.staging, state: "vollstaendig", paths: volumes.map(\.path), completed: completed, fileCount: count)
                try FileManager.default.moveItem(at: locations.staging, to: locations.final)
            } catch {
                try? self.writeManifest(at: locations.staging, state: "unvollstaendig", paths: volumes.map(\.path), completed: completed, fileCount: count, error: error.localizedDescription)
                throw M5Error.message(L("Sicherung unvollständig: {0}\nBereits kopierte Dateien: {1}", String(describing: (error.localizedDescription)), String(describing: (locations.staging.path))))
            }
            self.log(L("✓ Dateisicherung: {0} · {1} Dateien\n", String(describing: (locations.final.path)), String(describing: (count))), kind: .transfer)
            return BackupReport(directory: locations.final, volumes: volumes.map(\.path), fileCount: count)
        }, completion: { result in self.onProgress?(0); completion(result) })
    }

    func rename(entry: RemoteEntry, newName: String, completion: @escaping (Result<Void, Error>) -> Void) {
        perform(L("Benenne um …"), action: {
            try self.requireConnection()
            try self.requireMutableEntry(entry)
            try self.validateName(newName)
            let parent = (entry.path as NSString).deletingLastPathComponent
            try self.board.rename(path: entry.path, to: remoteJoin(parent.isEmpty ? "/" : parent, newName))
            self.log(L("Umbenannt: {0} → {1}\n", String(describing: (entry.path)), String(describing: (newName))))
        }, completion: { result in
            if case .success = result { self.onRefresh?() }
            completion(result)
        })
    }

    func move(entries: [RemoteEntry], toDirectory: String,
              completion: @escaping (Result<[RemoteEntry], Error>) -> Void) {
        let expectedSession = sessionEpoch()
        let alreadyBusy = busy
        perform(L("Verschiebe Auswahl …"), action: {
            try self.requireConnection()
            try self.requireSession(expectedSession)
            guard !alreadyBusy else {
                throw M5Error.message(L("Eine Geräteaktion läuft bereits. Bitte abwarten, aktualisieren und erneut verschieben."))
            }
            for entry in entries { try self.requireMutableEntry(entry) }
            let paths = try self.board.move(paths: entries.map(\.path), toDirectory: toDirectory)
            guard paths.count == entries.count else { throw M5Error.message(L("Die Geräteantwort enthält eine unvollständige Verschiebeliste. Bitte aktualisieren.")) }
            let moved = zip(entries, paths).map { entry, path in
                RemoteEntry(name: (path as NSString).lastPathComponent, path: path,
                            isDirectory: entry.isDirectory, size: entry.size)
            }
            for (entry, path) in zip(entries, paths) { self.log(L("Verschoben: {0} → {1}\n", String(describing: (entry.path)), String(describing: (path))), kind: .transfer) }
            return moved
        }, completion: { result in
            completion(result)
            // Invalidate editor/drag references in the caller before rebuilding the tree.
            // A partially completed or uncertain batch also needs exactly one refresh.
            self.onRefresh?()
        })
    }

    func delete(entry: RemoteEntry, backupFirst: Bool, backupDestination: URL? = nil,
                completion: @escaping (Result<URL?, Error>) -> Void) {
        perform(backupFirst ? L("Sichere und lösche Auswahl …") : L("Lösche Auswahl …"), action: {
            try self.requireConnection()
            try self.requireMutableEntry(entry)
            let backup = backupFirst ? try self.backupEntry(entry, reason: "Vor-Loeschen", parent: backupDestination) : nil
            if backupFirst, let selected = backupDestination, let backup = backup {
                _ = try self.validatedDeletionBackupParent(selected)
                guard try backup.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw M5Error.message(L("Die erstellte Löschsicherung ist nicht mehr verfügbar. Auf dem M5 wurde nichts gelöscht."))
                }
            }
            do { try self.board.remove(path: entry.path, recursive: entry.isDirectory) }
            catch {
                throw M5Error.message(L("Löschen fehlgeschlagen; bei Ordnern können Teile bereits entfernt sein. {0}", String(describing: (error.localizedDescription))) +
                                      (backup.map { L("\nSicherung: {0}", String(describing: ($0.path))) } ?? ""))
            }
            self.log(L("Gelöscht: {0}", String(describing: (entry.path))) + (backup.map { L(" · Sicherung: {0}", String(describing: ($0.path))) } ?? "") + "\n")
            return backup
        }, completion: { result in
            self.onProgress?(0)
            // Partial deletion must also invalidate stale file entries.
            self.onRefresh?()
            completion(result)
        })
    }

    func run(entry: RemoteEntry, completion: @escaping (Result<Void, Error>) -> Void) {
        perform(L("Sende Python-Startbefehl …"), action: {
            try self.requireConnection()
            guard !entry.isDirectory else { throw M5Error.message(L("Bitte eine Python-Datei auswählen.")) }
            self.invalidateSession()
            try self.board.runFile(path: entry.path)
            self.log(L("Startbefehl für {0} gesendet. Ausgaben und Laufzeitfehler erscheinen im Terminal.\n", String(describing: (entry.path))))
        }, completion: { result in
            if case .success = result { self.onProgramStarted?(entry.path) }
            completion(result)
        })
    }

    func setAutostart(entry: RemoteEntry, completion: @escaping (Result<URL?, Error>) -> Void) {
        perform(L("Richte Autostart ein …"), action: {
            try self.requireConnection()
            guard !entry.isDirectory, (entry.path as NSString).pathExtension.lowercased() == "py" else {
                throw M5Error.message(L("Autostart ist für Python-Dateien (.py) vorgesehen."))
            }
            let volumes = try self.board.volumes()
            guard let flash = volumes.first(where: { $0.path != "/sd" }) else { throw M5Error.message(L("Flash nicht verfügbar.")) }
            let target = remoteJoin(flash.path, "main.py")
            let oldMode = try self.board.uiFlowBootOption()
            // Validate the source without executing it or limiting the size of
            // a program to the editor's preview limit.
            let parent = (entry.path as NSString).deletingLastPathComponent
            guard try self.board.list(path: parent).contains(where: { $0.path == entry.path && !$0.isDirectory }) else {
                throw M5Error.message(L("Die ausgewählte Python-Datei ist nicht mehr vorhanden."))
            }
            let old = try self.board.list(path: flash.path).first { $0.path == target }
            if old?.isDirectory == true { throw M5Error.message(L("main.py ist ein Ordner. Autostart wurde nicht geändert.")) }
            let backup: URL
            if let old = old { backup = try self.backupEntry(old, reason: "Vor-Autostart") }
            else {
                let locations = try self.backupLocations(parent: self.backupDirectory, label: "Vor-Autostart")
                try self.writeManifest(at: locations.staging, state: "vollstaendig", paths: [], completed: [], fileCount: 0)
                try FileManager.default.moveItem(at: locations.staging, to: locations.final)
                backup = locations.final
            }
            try self.writeBootSettings(at: backup, previousMode: oldMode, mainExisted: old != nil)
            let previousMain = try old.map { _ in try Data(contentsOf: backup.appendingPathComponent("Dateien/main.py")) }
            func quoted(_ value: String) throws -> String {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                return String(decoding: try encoder.encode(value), as: UTF8.self)
            }
            let source = """
            # M5 File Manager: bewusst eingerichteter Autostart
            import os, sys
            os.chdir(\(try quoted(parent)))
            if \(try quoted(parent)) not in sys.path:
                sys.path.insert(0, \(try quoted(parent)))
            with open(\(try quoted(entry.path)), 'r') as _m5_program:
                _m5_source = _m5_program.read()
            __file__ = \(try quoted(entry.path))
            exec(compile(_m5_source, \(try quoted(entry.path)), 'exec'), globals())

            """
            let wrapperData = Data(source.utf8)
            var mainWriteAttempted = false
            var modeWriteAttempted = false
            do {
                if entry.path != target {
                    if let previousMain = previousMain {
                        guard try self.board.readFile(path: target, maxBytes: previousMain.count) == previousMain else {
                            throw M5Error.message(L("main.py wurde während der Sicherung verändert. Nichts überschrieben."))
                        }
                    }
                    mainWriteAttempted = true
                    try self.uploadData(wrapperData, path: target, overwrite: old != nil)
                }
                if let oldMode = oldMode {
                    guard try self.board.uiFlowBootOption() == oldMode else {
                        throw M5Error.message(L("Der Startmodus wurde während der Sicherung verändert."))
                    }
                    modeWriteAttempted = true
                    try self.board.setUIFlowBootOption(0)
                }
            } catch {
                let originalError = error
                var rollbackErrors: [String] = []
                if modeWriteAttempted, let oldMode = oldMode {
                    do { try self.board.setUIFlowBootOption(oldMode) }
                    catch { rollbackErrors.append(L("Startmodus: {0}", String(describing: (error.localizedDescription)))) }
                }
                if mainWriteAttempted {
                    do {
                        let currentEntry = try self.board.list(path: flash.path).first { $0.path == target }
                        if let currentEntry = currentEntry {
                            guard !currentEntry.isDirectory else { throw M5Error.message(L("main.py ist inzwischen ein Ordner; nicht verändert.")) }
                            let current = try self.board.readFile(path: target, maxBytes: max(previousMain?.count ?? 0, wrapperData.count))
                            if current == wrapperData {
                                if old != nil {
                                    try self.board.upload(localURL: backup.appendingPathComponent("Dateien/main.py"), remotePath: target, overwrite: true, progress: self.progress)
                                } else { try self.board.remove(path: target, recursive: false) }
                            } else if current != previousMain {
                                throw M5Error.message(L("main.py wurde zwischenzeitlich verändert und deshalb nicht überschrieben."))
                            }
                        } else if previousMain != nil {
                            throw M5Error.message(L("main.py fehlt. Original ist lokal gesichert; Gerätezustand bitte prüfen."))
                        }
                    } catch { rollbackErrors.append("main.py: \(error.localizedDescription)") }
                }
                throw M5Error.message(L("Autostart fehlgeschlagen: {0}\nSicherung: {1}\n", String(describing: (originalError.localizedDescription)), String(describing: (backup.path))) +
                                      (rollbackErrors.isEmpty ? L("Eigene Änderungen wurden zurückgenommen oder waren noch nicht geschrieben.") : L("Wiederherstellung nicht vollständig: ") + rollbackErrors.joined(separator: "; ")))
            }
            self.log(L("Autostart eingerichtet: {0} → {1}. ", String(describing: (target)), String(describing: (entry.path))) +
                     (oldMode != nil ? L("UIFlow startet main.py direkt. ") : L("main.py als MicroPython-Startdatei vorbereitet. ")) +
                     L("Wirksam beim nächsten Neustart. Sicherung: {0}\n", String(describing: (backup.path))))
            return Optional(backup)
        }, completion: { result in
            self.onProgress?(0)
            if case .success = result { self.onRefresh?() }
            completion(result)
        })
    }

    func showStartupMenu(completion: @escaping (Result<Void, Error>) -> Void) {
        perform(L("Aktiviere UIFlow-Startmenü …"), action: {
            try self.requireConnection()
            guard let previous = try self.board.uiFlowBootOption() else {
                throw M5Error.message(L("Diese Firmware stellt keinen unterstützten UIFlow-Startmodus bereit."))
            }
            let locations = try self.backupLocations(parent: self.backupDirectory, label: "Vor-Startmodus")
            try self.writeBootSettings(at: locations.staging, previousMode: previous, mainExisted: nil)
            try FileManager.default.moveItem(at: locations.staging, to: locations.final)
            do { try self.board.setUIFlowBootOption(1) }
            catch {
                let original = error
                do { try self.board.setUIFlowBootOption(previous) }
                catch { throw M5Error.message(L("Startmodus konnte nicht sicher wiederhergestellt werden: {0}\nVorheriger Modus: {1}", String(describing: (error.localizedDescription)), String(describing: (locations.final.path)))) }
                throw original
            }
            self.log(L("UIFlow-Startmenü für den nächsten Neustart aktiviert. main.py bleibt erhalten.\n"))
        }, completion: completion)
    }

    private func writeBootSettings(at directory: URL, previousMode: Int?, mainExisted: Bool?) throws {
        var settings: [String: Any] = ["format": 1, "previousUIFlowBootOption": previousMode.map { $0 as Any } ?? NSNull(),
                                      "mode0": L("main.py direkt"), "mode1": L("Startmenü und Netzwerk"), "mode2": L("Nur Netzwerk"),
                                      "createdAt": ISO8601DateFormatter().string(from: Date())]
        if let mainExisted = mainExisted { settings["mainExisted"] = mainExisted }
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("AUTOSTART.json"), options: .atomic)
    }

    private func requireMutableEntry(_ entry: RemoteEntry) throws {
        guard !["/", "/flash", "/sd"].contains(entry.path) else {
            throw M5Error.message(L("Speicherwurzeln dürfen nicht umbenannt oder gelöscht werden."))
        }
        try validateName(entry.name)
    }

    private func uploadData(_ data: Data, path: String, overwrite: Bool) throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("m5-edit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        try data.write(to: local, options: .atomic)
        try board.upload(localURL: local, remotePath: path, overwrite: overwrite, progress: progress)
    }

    private func backupLocations(parent: URL, label: String, createParent: Bool = true) throws -> (staging: URL, final: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = formatter.string(from: Date()) + "_" + label + "_" + UUID().uuidString.prefix(8)
        if createParent { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        let final = parent.appendingPathComponent(String(name), isDirectory: true)
        let staging = parent.appendingPathComponent(String(name) + ".unvollstaendig", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return (staging, final)
    }

    private func writeManifest(at directory: URL, state: String, paths: [String], completed: [String],
                               fileCount: Int, error: String? = nil) throws {
        var record: [String: Any] = ["format": 1, "status": state, "createdAt": ISO8601DateFormatter().string(from: Date()),
                                     "paths": paths, "completedPaths": completed, "fileCount": fileCount,
                                     "scope": L("Dateien; kein Firmware- oder vollständiges Geräteabbild")]
        if let error = error { record["error"] = error }
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("SICHERUNG.json"), options: .atomic)
    }

    private func backupData(_ data: Data, entry: RemoteEntry, reason: String) throws -> URL {
        try validateName(entry.name)
        let locations = try backupLocations(parent: backupDirectory, label: reason)
        do {
            try writeManifest(at: locations.staging, state: "unvollstaendig", paths: [entry.path], completed: [], fileCount: 0)
            let content = locations.staging.appendingPathComponent("Dateien", isDirectory: true)
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false)
            try data.write(to: content.appendingPathComponent(entry.name), options: .atomic)
            try writeManifest(at: locations.staging, state: "vollstaendig", paths: [entry.path], completed: [entry.path], fileCount: 1)
            try FileManager.default.moveItem(at: locations.staging, to: locations.final)
            return locations.final.appendingPathComponent("Dateien").appendingPathComponent(entry.name)
        } catch {
            try? writeManifest(at: locations.staging, state: "unvollstaendig", paths: [entry.path], completed: [], fileCount: 0, error: error.localizedDescription)
            throw M5Error.message(L("Lokale Sicherung fehlgeschlagen. M5-Datei bleibt unverändert. {0}\n{1}", String(describing: (error.localizedDescription)), String(describing: (locations.staging.path))))
        }
    }

    private func validatedDeletionBackupParent(_ selected: URL) throws -> URL {
        guard selected.isFileURL else { throw M5Error.message(L("Der gewählte Lösch-Sicherungsordner ist kein lokaler Dateipfad.")) }
        let parent = selected.standardizedFileURL.resolvingSymlinksInPath()
        guard parent.path != "/Volumes", parent.path != "/System/Volumes/Data/Volumes" else {
            throw M5Error.message(L("Bitte einen Sicherungsordner auf einem eingebundenen Volume wählen."))
        }
        let fm = FileManager.default
        guard try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw M5Error.message(L("Der gewählte Lösch-Sicherungsordner ist nicht verfügbar oder kein Ordner: {0}", String(describing: (selected.path))))
        }
        // Do not accept a leftover local directory where a network/removable volume
        // used to be mounted, and never create a missing chosen parent recursively.
        for base in ["/Volumes/", "/System/Volumes/Data/Volumes/"] where parent.path.hasPrefix(base) {
            let suffix = String(parent.path.dropFirst(base.count))
            guard let volumeName = suffix.split(separator: "/").first else {
                throw M5Error.message(L("Bitte einen Sicherungsordner auf einem eingebundenen Volume wählen."))
            }
            let expected = URL(fileURLWithPath: "/Volumes/" + String(volumeName), isDirectory: true).resolvingSymlinksInPath()
            guard let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []),
                  mounted.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == expected.path }) else {
                throw M5Error.message(L("Das Volume für den gewählten Lösch-Sicherungsordner ist nicht eingebunden: {0}", String(describing: (selected.path))))
            }
        }
        guard fm.isWritableFile(atPath: parent.path) else {
            throw M5Error.message(L("Der gewählte Lösch-Sicherungsordner ist nicht beschreibbar: {0}", String(describing: (selected.path))))
        }
        return parent
    }

    private func backupEntry(_ entry: RemoteEntry, reason: String, parent: URL? = nil) throws -> URL {
        try validateName(entry.name)
        let destinationParent = try parent.map { try validatedDeletionBackupParent($0) } ?? backupDirectory
        let locations = try backupLocations(parent: destinationParent, label: reason, createParent: parent == nil)
        var count = 0
        do {
            try writeManifest(at: locations.staging, state: "unvollstaendig", paths: [entry.path], completed: [], fileCount: 0)
            let content = locations.staging.appendingPathComponent("Dateien", isDirectory: true)
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false)
            let destination = content.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                try downloadTree(entry.path, to: destination, onFileCopied: { count += 1 })
            } else {
                try board.download(remotePath: entry.path, localURL: destination, overwrite: false, progress: progress)
                count = 1
            }
            try writeManifest(at: locations.staging, state: "vollstaendig", paths: [entry.path], completed: [entry.path], fileCount: count)
            try FileManager.default.moveItem(at: locations.staging, to: locations.final)
            return locations.final
        } catch {
            try? writeManifest(at: locations.staging, state: "unvollstaendig", paths: [entry.path], completed: [], fileCount: count, error: error.localizedDescription)
            throw M5Error.message(L("Sicherung unvollständig; M5-Dateien bleiben unverändert. {0}\n{1}", String(describing: (error.localizedDescription)), String(describing: (locations.staging.path))))
        }
    }

    func send(command: String) {
        guard !command.isEmpty else { return }
        perform(L("Sende Terminalbefehl …"), action: {
            try self.requireConnection()
            self.invalidateSession()
            self.log("> \(command)\n")
            try self.board.send(command: command)
        }, completion: { _ in })
    }

    func interrupt() {
        perform(L("Halte Python an …"), action: {
            try self.requireConnection()
            try self.board.interrupt()
        }, completion: { _ in })
    }

    func restart() {
        perform(L("Starte M5-Programm neu …"), action: {
            try self.requireConnection()
            self.invalidateSession()
            try self.board.restart()
            self.log(L("\nNeustart angefordert. Neuer Dateizugriff hält das Programm wieder an.\n"))
        }, completion: { result in
            if case .success = result { self.onRestart?() }
        })
    }
}
