import Foundation

private struct ServiceFailure: Error, CustomStringConvertible { let description: String }

@main
struct ServiceTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw ServiceFailure(description: message) }
        checks += 1
    }
    static func result<T>(_ start: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        var response: Result<T, Error>?
        start { response = $0 }
        let until = Date().addingTimeInterval(35)
        while response == nil && Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let response = response else { throw ServiceFailure(description: "Main-queue callback timed out") }
        return try response.get()
    }
    static func failure(_ message: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch is ServiceFailure { throw ServiceFailure(description: message + " (test failure)") }
        catch { checks += 1; return }
        throw ServiceFailure(description: message)
    }
    static func idle(_ service: DeviceService) throws {
        let until = Date().addingTimeInterval(10)
        while service.busy && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(!service.busy, "Service became idle")
    }
    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("m5-service-" + UUID().uuidString)
        let fixture = root.appendingPathComponent("board")
        let safety = root.appendingPathComponent("safety")
        let full = root.appendingPathComponent("full")
        try fm.createDirectory(at: fixture.appendingPathComponent("flash/apps"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fixture.appendingPathComponent("sd/logs"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ name: String, _ value: String) throws { try Data(value.utf8).write(to: fixture.appendingPathComponent(name)) }
        func read(_ name: String) throws -> String { try String(contentsOf: fixture.appendingPathComponent(name), encoding: .utf8) }
        func entry(_ path: String, dir: Bool = false) -> RemoteEntry {
            RemoteEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: dir, size: 0)
        }
        try write("flash/main.py", "print('old main')\n")
        try write("flash/boot.py", "# original boot\n")
        try write("flash/apps/grüezi ' test.py", "print('hello')\n")
        try write("sd/logs/data.csv", "a,b\n1,2\n")
        let simulator = Process(), pipe = Pipe()
        simulator.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        simulator.arguments = [CommandLine.arguments[2], fixture.path]
        simulator.standardOutput = pipe
        simulator.standardError = FileHandle.standardError
        try simulator.run()
        defer { if simulator.isRunning { simulator.terminate() }; simulator.waitUntilExit() }
        let info = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.availableData) as! [String: String]
        let port = info["path"]!
        try expect(port.hasPrefix("/dev/ttys") || port.hasPrefix("/dev/pts/"), "Only a local PTY is opened")
        let service = DeviceService(board: BoardSession(timeout: 2), backupDirectory: safety)
        var logs: [LogEvent] = []
        service.onLogEvent = { logs.append($0) }
        let volumes = try result { service.connect(path: port, completion: $0) }
        try expect(volumes.count == 2, "Service connected to Flash and SD")
        let snapshot = try result { service.refresh(paths: [], completion: $0) }
        try expect(snapshot.storage.count == 2, "Both volume capacities supplied")
        let source = entry("/flash/apps/grüezi ' test.py")
        let opened = try result { service.openDocument(entry: source, completion: $0) }
        try expect(opened.text == "print('hello')\n", "Preview reads exact Unicode/quoted path")
        let saved = try result { service.saveDocument(opened, text: "print('changed')\n", completion: $0) }
        let remoteSaved = try read("flash/apps/grüezi ' test.py")
        let originalBackup = try String(contentsOf: saved.backupURL, encoding: .utf8)
        try expect(remoteSaved == "print('changed')\n", "Save updates selected file")
        try expect(originalBackup == opened.text, "Local safety copy contains exact original")
        try expect(saved.document.original == Data(remoteSaved.utf8), "Saved document advances revision")
        try write("flash/apps/grüezi ' test.py", "print('external edit')\n")
        try failure("Conflicting remote revision must refuse save") {
            _ = try result { service.saveDocument(saved.document, text: "overwrite", completion: $0) }
        }
        let conflict = try read("flash/apps/grüezi ' test.py")
        try expect(conflict == "print('external edit')\n", "External edit remains unchanged")
        let fresh = try result { service.openDocument(entry: source, completion: $0) }
        try fm.moveItem(at: safety, to: root.appendingPathComponent("saved-safety"))
        try Data("not a directory".utf8).write(to: safety)
        try failure("Backup failure must block editor overwrite") {
            _ = try result { service.saveDocument(fresh, text: "bad overwrite", completion: $0) }
        }
        try failure("Backup failure must block deletion") {
            _ = try result { service.delete(entry: source, backupFirst: true, completion: $0) }
        }
        let protected = try read("flash/apps/grüezi ' test.py")
        try expect(protected == fresh.text, "Save/delete left original after backup failure")
        try fm.removeItem(at: safety)
        try fm.moveItem(at: root.appendingPathComponent("saved-safety"), to: safety)
        try Data([0, 255, 7]).write(to: fixture.appendingPathComponent("flash/binary.dat"))
        try failure("Binary preview must be rejected") { _ = try result { service.openDocument(entry: entry("/flash/binary.dat"), completion: $0) } }
        try Data(repeating: 65, count: 1_048_577).write(to: fixture.appendingPathComponent("flash/large.txt"))
        try failure("Oversized preview must be rejected using fresh size") { _ = try result { service.openDocument(entry: entry("/flash/large.txt"), completion: $0) } }
        try fm.removeItem(at: fixture.appendingPathComponent("flash/large.txt"))
        print("PASS preview, exact-revision editor, local original, conflict and backup-failure protection")

        let backup = try result { service.backup(includeSD: true, to: full, completion: $0) }
        try expect(backup.fileCount == 5, "Complete Flash+SD backup counts actual files")
        let copied = try String(contentsOf: backup.directory.appendingPathComponent("SD/logs/data.csv"), encoding: .utf8)
        try expect(copied == "a,b\n1,2\n", "SD backup bytes match")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: backup.directory.appendingPathComponent("SICHERUNG.json"))) as! [String: Any]
        try expect(manifest["status"] as? String == "vollstaendig", "Complete backup has manifest")
        try expect(backup.volumes == ["/flash", "/sd"], "Backup lists actual included mounts")
        let fault = fixture.appendingPathComponent(".test-filesystem-faults")
        try fm.createDirectory(at: fixture.appendingPathComponent("sd/aaa"), withIntermediateDirectories: true)
        try write("sd/aaa/first.txt", "copied before fault")
        try JSONSerialization.data(withJSONObject: [["operation":"listdir", "path":"/sd/logs", "code":19]]).write(to: fault)
        try failure("Mid-backup failure must not claim complete") { _ = try result { service.backup(includeSD: true, to: full, completion: $0) } }
        let partial = try fm.contentsOfDirectory(at: full, includingPropertiesForKeys: nil).first { $0.pathExtension == "unvollstaendig" }
        try expect(partial != nil, "Partial backup is clearly named and retained")
        let partialManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: partial!.appendingPathComponent("SICHERUNG.json"))) as! [String: Any]
        try expect(partialManifest["status"] as? String == "unvollstaendig", "Partial manifest never reports complete")
        try expect(partialManifest["fileCount"] as? Int == 5, "Partial manifest includes files already copied from failing SD volume")
        // Four Flash files plus one file from the failing SD volume.
        try fm.removeItem(at: fault)
        try fm.createDirectory(at: fixture.appendingPathComponent("sd/logs/aaa"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fixture.appendingPathComponent("sd/logs/zzz"), withIntermediateDirectories: true)
        try write("sd/logs/aaa/first.txt", "safety copy before fault")
        try JSONSerialization.data(withJSONObject: [["operation":"listdir", "path":"/sd/logs/zzz", "code":19]]).write(to: fault)
        try failure("Interrupted safety backup prevents any deletion") { _ = try result { service.delete(entry: entry("/sd/logs", dir: true), backupFirst: true, completion: $0) } }
        let failedSafety = try fm.contentsOfDirectory(at: safety, includingPropertiesForKeys: nil).first { $0.pathExtension == "unvollstaendig" }!
        let safetyManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: failedSafety.appendingPathComponent("SICHERUNG.json"))) as! [String: Any]
        try expect(safetyManifest["status"] as? String == "unvollstaendig" && safetyManifest["fileCount"] as? Int == 1, "Partial safety copy retains accurate manifest")
        try expect(fm.fileExists(atPath: fixture.appendingPathComponent("sd/logs/aaa/first.txt").path), "Interrupted backup leaves remote subtree untouched")
        try fm.removeItem(at: fault)
        print("PASS complete and interrupted file backups with explicit manifests")

        try result { service.rename(entry: source, newName: "renamed.py", completion: $0) }
        try expect(!fm.fileExists(atPath: fixture.appendingPathComponent("flash/apps/grüezi ' test.py").path), "Rename removes old name")
        let renamed = entry("/flash/apps/renamed.py")
        try write("flash/apps/exists.py", "existing")
        try failure("Rename collision must refuse") { try result { service.rename(entry: renamed, newName: "exists.py", completion: $0) } }
        let existing = try read("flash/apps/exists.py")
        try expect(existing == "existing", "Rename collision preserves target")
        try failure("Volume root cannot be deleted") { _ = try result { service.delete(entry: entry("/flash", dir: true), backupFirst: false, completion: $0) } }
        let deletionCopy = try result { service.delete(entry: entry("/sd/logs", dir: true), backupFirst: true, completion: $0) }
        try expect(deletionCopy != nil && !fm.fileExists(atPath: fixture.appendingPathComponent("sd/logs").path), "Folder deleted only after backup")
        let deletedOriginal = try String(contentsOf: deletionCopy!.appendingPathComponent("Dateien/logs/data.csv"), encoding: .utf8)
        try expect(deletedOriginal == copied, "Deleted folder remains locally recoverable")
        print("PASS rename collision, protected roots, recursive delete with local recovery copy")

        let beforeAutostart = try read("flash/main.py")
        let bootMode = fixture.appendingPathComponent(".test-boot-option")
        try Data("{\"value\":1}".utf8).write(to: bootMode)
        func mode() throws -> Int {
            (try JSONSerialization.jsonObject(with: Data(contentsOf: bootMode)) as! [String: Any])["value"] as! Int
        }
        let autostartCopy = try result { service.setAutostart(entry: renamed, completion: $0) }
        let wrapper = try read("flash/main.py")
        try expect(wrapper.contains("/flash/apps/renamed.py") && wrapper.contains("os.chdir"), "Autostart wrapper references chosen program and directory")
        let preservedMain = try String(contentsOf: autostartCopy!.appendingPathComponent("Dateien/main.py"), encoding: .utf8)
        try expect(preservedMain == beforeAutostart, "Previous main.py backed up")
        let untouchedBoot = try read("flash/boot.py")
        try expect(untouchedBoot == "# original boot\n", "Autostart never edits boot.py")
        let activeMode = try mode()
        try expect(activeMode == 0, "UIFlow autostart activates direct main.py mode")
        let bootBackup = try JSONSerialization.jsonObject(with: Data(contentsOf: autostartCopy!.appendingPathComponent("AUTOSTART.json"))) as! [String: Any]
        try expect(bootBackup["previousUIFlowBootOption"] as? Int == 1, "Previous UIFlow mode saved before mutation")
        try result { service.showStartupMenu(completion: $0) }
        let menuMode = try mode(), stillWrapper = try read("flash/main.py")
        try expect(menuMode == 1 && stillWrapper == wrapper, "Startup menu restored without editing main.py")
        try write(".test-fault", "boot-option-write:remote-error")
        try failure("Failed boot mode write must roll back main.py and prior mode") {
            _ = try result { service.setAutostart(entry: renamed, completion: $0) }
        }
        let rolledBackMain = try read("flash/main.py"), rolledBackMode = try mode()
        try expect(rolledBackMain == wrapper && rolledBackMode == 1, "Autostart failure restores both prior file and mode")
        try write("flash/main.py", "print('distinct original before lost reply')\n")
        try write(".test-fault", "upload-commit:reply-lost")
        try failure("Committed upload with lost reply must still be rolled back") {
            _ = try result { service.setAutostart(entry: renamed, completion: $0) }
        }
        let afterLostReply = try read("flash/main.py"), unchangedMode = try mode()
        try expect(afterLostReply == "print('distinct original before lost reply')\n" && unchangedMode == 1, "Lost commit reply restores exact pre-operation main.py and mode")
        _ = try result { service.setAutostart(entry: renamed, completion: $0) }
        try write("flash/apps/renamed.py", "with open('ran.txt', 'w') as f:\n    f.write('executed via main')\n")
        let beforeRun = try result { service.openDocument(entry: renamed, completion: $0) }
        var started: String?
        service.onProgramStarted = { started = $0 }
        try result { service.run(entry: entry("/flash/main.py"), completion: $0) }
        try expect(started == "/flash/main.py", "Run reports submitted path")
        let ranPath = fixture.appendingPathComponent("flash/apps/ran.txt")
        let untilRan = Date().addingTimeInterval(3)
        while !fm.fileExists(atPath: ranPath.path) && Date() < untilRan { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let ran = try String(contentsOf: ranPath, encoding: .utf8)
        try expect(ran == "executed via main", "Generated main.py actually executes selected file with relative cwd")
        try failure("Document from before program start cannot overwrite") { _ = try result { service.saveDocument(beforeRun, text: "stale", completion: $0) } }
        service.interrupt()
        try idle(service)
        let preReconnect = try result { service.openDocument(entry: renamed, completion: $0) }
        service.disconnect()
        try idle(service)
        _ = try result { service.connect(path: port, completion: $0) }
        try failure("Old document cannot save onto reconnected device") { _ = try result { service.saveDocument(preReconnect, text: "stale", completion: $0) } }
        let afterReconnect = try read("flash/apps/renamed.py")
        try expect(afterReconnect == preReconnect.text, "Reconnect preserves remote contents")
        try expect(logs.contains { $0.kind == .transfer } && logs.contains { $0.kind == .error }, "Terminal receives categorized transfer and error events")
        print("PASS explicit autostart, unchanged boot.py, run notification and session-pinned editor")

        // A filesystem mounted at / can expose /sd inside its directory list.
        try fm.moveItem(at: fixture.appendingPathComponent("flash"), to: fixture.appendingPathComponent("userfiles"))
        try write("sd/only-on-sd.txt", "sd")
        let rootBackup = try result { service.backup(includeSD: false, to: full, completion: $0) }
        try expect(rootBackup.volumes == ["/"], "Root Flash backup selected")
        try expect(!fm.fileExists(atPath: rootBackup.directory.appendingPathComponent("Flash/sd").path), "Excluded SD never leaks into root Flash copy")
        let both = try result { service.backup(includeSD: true, to: full, completion: $0) }
        try expect(!fm.fileExists(atPath: both.directory.appendingPathComponent("Flash/sd").path) && fm.fileExists(atPath: both.directory.appendingPathComponent("SD/only-on-sd.txt").path), "Separate SD copied exactly once")
        service.disconnect()
        try idle(service)
        print("SUCCESS: \(checks) service checks; simulated device only")
    }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
}
