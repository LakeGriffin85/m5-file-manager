import Foundation

private struct RefreshFailure: Error, CustomStringConvertible { let description: String }

@main
struct RefreshTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw RefreshFailure(description: message) }
        checks += 1
    }
    static func entries(_ snapshot: FileTreeRefresh, _ path: String) throws -> [RemoteEntry] {
        guard let result = snapshot.directories[path] else { throw RefreshFailure(description: "Missing listing: \(path)") }
        return try result.get()
    }
    static func expectError(_ snapshot: FileTreeRefresh, _ path: String, code: Int) throws {
        guard case .failure(let error)? = snapshot.directories[path],
              case M5Error.filesystem(_, let received) = error, received == code else {
            throw RefreshFailure(description: "Expected explicit filesystem error \(code) for \(path)")
        }
        checks += 1
    }
    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("m5-refresh-" + UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("flash/empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("sd/logs/deep"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("flash".utf8).write(to: root.appendingPathComponent("flash/main.py"))
        try Data("sd".utf8).write(to: root.appendingPathComponent("sd/logs/deep/data.txt"))
        let marker = root.appendingPathComponent(".test-filesystem-faults")
        func fault(_ path: String, code: Int = 19) throws {
            try JSONSerialization.data(withJSONObject: [["operation": "listdir", "path": path, "code": code]]) .write(to: marker)
        }
        let simulator = Process()
        let pipe = Pipe()
        simulator.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        simulator.arguments = [CommandLine.arguments[2], root.path]
        simulator.standardOutput = pipe
        simulator.standardError = FileHandle.standardError
        try simulator.run()
        defer { if simulator.isRunning { simulator.terminate() }; simulator.waitUntilExit() }
        let info = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.availableData) as! [String: String]
        let path = info["path"]!
        try expect(path.hasPrefix("/dev/ttys") || path.hasPrefix("/dev/pts/"), "Simulator must supply a PTY")
        let board = BoardSession(timeout: 1.5)
        try board.connect(path: path)
        defer { board.disconnect() }
        let initial = try board.refreshDirectories(paths: ["/sd/logs/deep", "/flash/empty"])
        try expect(initial.volumes.count == 2, "Initial Flash and SD")
        try expect(initial.directories["/sd/logs"] != nil, "Include selected path ancestors")
        let deep = try entries(initial, "/sd/logs/deep")
        try expect(deep.contains { $0.name == "data.txt" }, "Refresh selected deep folder")
        let empty = try entries(initial, "/flash/empty")
        try expect(empty.isEmpty, "Real empty directory remains successful")
        print("PASS fresh roots, expanded/selected paths and ancestors")

        try fault("/sd")
        try Data("new".utf8).write(to: root.appendingPathComponent("flash/new.py"))
        for _ in 0..<2 {
            let missingSD = try board.refreshDirectories(paths: ["/sd/logs/deep", "/flash"])
            try expect(missingSD.volumes.map(\.path) == ["/flash"], "Unavailable SD removed from fresh mount snapshot")
            try expect(!missingSD.directories.keys.contains { $0 == "/sd" || $0.hasPrefix("/sd/") }, "No stale SD actions/listings after ENODEV")
            let flash = try entries(missingSD, "/flash")
            try expect(flash.contains { $0.name == "new.py" }, "Flash refresh still discovers new entries")
        }
        print("PASS repeated refresh after SD ENODEV keeps Flash current")
        try fm.removeItem(at: marker)
        let restored = try board.refreshDirectories(paths: ["/flash", "/sd/logs/deep"])
        try expect(restored.volumes.contains { $0.path == "/sd" }, "SD reappears on next refresh")
        let restoredEntries = try entries(restored, "/sd/logs/deep")
        try expect(restoredEntries.contains { $0.name == "data.txt" }, "Recovered SD contents are freshly read")

        try fault("/sd/logs")
        let failedSubdir = try board.refreshDirectories(paths: ["/sd/logs/deep", "/flash/empty"])
        try expectError(failedSubdir, "/sd/logs", code: 19)
        try expectError(failedSubdir, "/sd/logs/deep", code: 19)
        _ = try entries(failedSubdir, "/flash")
        let stillEmpty = try entries(failedSubdir, "/flash/empty")
        try expect(stillEmpty.isEmpty, "Unavailable subdir differs from genuinely empty directory")
        try fm.removeItem(at: marker)
        try fm.removeItem(at: root.appendingPathComponent("sd/logs/deep"))
        let removed = try board.refreshDirectories(paths: ["/sd/logs/deep", "/sd-other"])
        try expectError(removed, "/sd/logs/deep", code: 2)
        try expect(removed.directories["/sd-other"] == nil, "Volume matching respects path boundary")
        print("PASS unavailable and removed folders remain explicit errors; SD recovery works")

        try Data("list:remote-error".utf8).write(to: root.appendingPathComponent(".test-fault"))
        do {
            _ = try board.refreshDirectories(paths: ["/flash"])
            throw RefreshFailure(description: "Unclassified remote/protocol failure must not become a partial successful tree")
        } catch is RefreshFailure { throw RefreshFailure(description: "Protocol fault was swallowed") }
        catch { checks += 1 }
        let recovery = try board.refreshDirectories(paths: [])
        try expect(recovery.volumes.count == 2, "Next refresh succeeds after recoverable remote error")
        print("PASS unclassified errors propagate and next refresh recovers")
        try fm.moveItem(at: root.appendingPathComponent("flash"), to: root.appendingPathComponent("flash-backup"))
        let fallback = try board.refreshDirectories(paths: ["/", "/sd/logs"])
        try expect(fallback.volumes.contains { $0.path == "/" }, "Firmware without /flash exposes root storage")
        try expect(fallback.volumes.contains { $0.path == "/sd" }, "Root storage can coexist with a separate SD volume")
        _ = try entries(fallback, "/")
        _ = try entries(fallback, "/sd/logs")
        print("PASS root storage fallback with separate SD")
        print("SUCCESS: \(checks) refresh regression checks; simulated device only")
    }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
}
