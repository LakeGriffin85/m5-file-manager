import Foundation

private struct ServiceFailure: Error, CustomStringConvertible { let description: String }

@main
struct SyncTests {
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
        try expect(SyncComparison.compare(base: "a", local: "a", remote: "a") == .equal, "Equal hashes")
        try expect(SyncComparison.compare(base: "a", local: "b", remote: "a") == .localChanged, "Local-only change")
        try expect(SyncComparison.compare(base: "a", local: "a", remote: "b") == .remoteChanged, "Remote-only change")
        try expect(SyncComparison.compare(base: "a", local: "b", remote: "c") == .conflict, "Both sides changed")
        let csv = try CSVPreview.parse("a;b\r\n\"x;y\";\"line1\nline2\"\r\n")
        try expect(csv == [["a", "b"], ["x;y", "line1\nline2"]], "CSV semicolon, CRLF, quoted delimiter/newline")
        let escaped = try CSVPreview.parse("\"a\"\"b\",c\n")
        try expect(escaped == [["a\"b", "c"]], "CSV escaped quote")
        try failure("Malformed CSV rejected") { _ = try CSVPreview.parse("\"unfinished") }
        let jsonPreview = try JSONPreview.format(Data("{\"n\":21.4,\"big\":1234567890123456789,\"s\":\"a b\",\"empty\":[]}".utf8))
        try expect(jsonPreview.contains("21.4") && !jsonPreview.contains("999999") && jsonPreview.contains("1234567890123456789") && jsonPreview.contains("a b") && jsonPreview.contains("[]"), "JSON preserves original numeric/string tokens")
        let source = entry("/flash/apps/grüezi ' test.py")
        let opened = try result { service.openDocument(entry: source, completion: $0) }
        let equal = try result { service.checkDocument(opened, text: opened.text, completion: $0) }
        try expect(equal == .equal, "M5 SHA256 equals Mac SHA256")
        let changed = try result { service.checkDocument(opened, text: "local", completion: $0) }
        try expect(changed == .localChanged, "Local modified status")
        try write("flash/apps/grüezi ' test.py", "remote")
        let remote = try result { service.checkDocument(opened, text: opened.text, completion: $0) }
        try expect(remote == .remoteChanged, "Remote modified status")
        let conflict = try result { service.checkDocument(opened, text: "local", completion: $0) }
        try expect(conflict == .conflict, "Concurrent modified status")
        try write(".test-no-hashlib", "1")
        try failure("Missing firmware hash capability returns failure") {
            let _: SyncComparison = try result { service.checkDocument(opened, text: "local", completion: $0) }
        }
        try fm.removeItem(at: fixture.appendingPathComponent(".test-no-hashlib"))
        let local = root.appendingPathComponent("local")
        try fm.createDirectory(at: local.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: local.appendingPathComponent("nested/code.py"))
        try Data("hidden".utf8).write(to: local.appendingPathComponent(".hidden"))
        let initial = try LiveSnapshot.read(root: local)
        try expect(initial.files.count == 1, "Live snapshot excludes hidden files")
        var delivered: [LiveSnapshot] = []
        var watcher: LiveSyncWatcher? = LiveSyncWatcher(root: local)
        watcher?.onStable = { delivered.append($0) }
        let watchDeadline = Date().addingTimeInterval(5)
        while delivered.isEmpty && Date() < watchDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        try expect(delivered.last == initial, "Real watcher delivers stable snapshot on main queue")
        try Data("watch-change".utf8).write(to: local.appendingPathComponent("nested/code.py"))
        let changeDeadline = Date().addingTimeInterval(5)
        while delivered.last?.files["nested/code.py"] != Data("watch-change".utf8) && Date() < changeDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        try expect(delivered.last?.files["nested/code.py"] == Data("watch-change".utf8), "Watcher detects editor replacement")
        watcher = nil
        let deliveredAfterStop = delivered.count
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        try expect(delivered.count == deliveredAfterStop, "Released watcher produces no later stable callbacks")
        let token = try result { service.beginLiveSync(initial, to: "/flash/apps", completion: $0) }
        var restarts = 0
        service.onRestart = { restarts += 1 }
        let _: Void = try result { service.liveSync(initial, names: ["nested/code.py"], token: token, completion: $0) }
        let installed = try read("flash/apps/nested/code.py")
        try expect(installed == "first", "Live sync creates nested file")
        try expect(restarts == 1, "One restart after successful batch")
        let second = LiveSnapshot(files: ["nested/code.py": Data("second".utf8)])
        let _: Void = try result { service.liveSync(second, names: ["nested/code.py"], token: token, completion: $0) }
        let updated = try read("flash/apps/nested/code.py")
        try expect(updated == "second", "Live session survives its own restart")
        try expect(restarts == 2, "Second batch restarts once")
        let backups = fm.enumerator(at: safety, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        let originals = backups.filter { $0.lastPathComponent == "code.py" }
        let backupFound = try originals.contains { try Data(contentsOf: $0) == Data("first".utf8) }
        try expect(backupFound, "Live overwrite backs up original")
        try write("flash/apps/nested/code.py", "foreign")
        try failure("Live conflict stops overwrite") {
            let _: Void = try result { service.liveSync(initial, names: ["nested/code.py"], token: token, completion: $0) }
        }
        let preserved = try read("flash/apps/nested/code.py")
        try expect(preserved == "foreign" && restarts == 2, "Conflict preserves remote and does not restart")
        try fm.createSymbolicLink(at: local.appendingPathComponent("link"), withDestinationURL: fixture)
        try failure("Live local symlink rejected") { _ = try LiveSnapshot.read(root: local) }
        try fm.removeItem(at: local.appendingPathComponent("link"))
        let interrupted = LiveSnapshot(files: ["nested/code.py": Data(repeating: 65, count: 2500)])
        let freshToken = try result { service.beginLiveSync(interrupted, to: "/flash/apps", completion: $0) }
        try write(".test-fault", "upload-write@2:disconnect")
        try failure("Disconnect in second chunk fails live batch") {
            let _: Void = try result { service.liveSync(interrupted, names: ["nested/code.py"], token: freshToken, completion: $0) }
        }
        let oldAfterDisconnect = try read("flash/apps/nested/code.py")
        try expect(oldAfterDisconnect == "foreign" && restarts == 2, "Interrupted staging preserves original and no restart")
        service.disconnect(); try idle(service)
        try failure("Disconnected live session rejected") {
            let _: Void = try result { service.liveSync(initial, names: ["nested/code.py"], token: token, completion: $0) }
        }
        print("PASS \(checks) sync/preview/live checks · PTY only")
    }

    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
}
