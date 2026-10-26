import Foundation

private struct MoveTestFailure: Error, CustomStringConvertible { let description: String }

@main
struct MoveTests {
    static let fm = FileManager.default
    static var checks = 0

    static func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw MoveTestFailure(description: label) }
        checks += 1
    }

    @discardableResult
    static func failure(_ label: String, _ operation: () throws -> Void) throws -> Error {
        do { try operation() }
        catch let error as MoveTestFailure { throw error }
        catch { checks += 1; return error }
        throw MoveTestFailure(description: "Expected failure: \(label)")
    }

    static func result<T>(_ start: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        var response: Result<T, Error>?
        start { response = $0 }
        let until = Date().addingTimeInterval(20)
        while response == nil && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard let response else { throw MoveTestFailure(description: "Service callback timed out") }
        return try response.get()
    }

    static func idle(_ service: DeviceService) throws {
        let until = Date().addingTimeInterval(15)
        while service.busy && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(!service.busy, "Service becomes idle")
    }

    static func entry(_ path: String, directory: Bool = false) -> RemoteEntry {
        RemoteEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: directory, size: 0)
    }

    final class Fixture {
        let root = fm.temporaryDirectory.appendingPathComponent("m5-move-tests-" + UUID().uuidString, isDirectory: true)
        let simulator = Process()
        var port = ""
        var remote: URL { root.appendingPathComponent("board", isDirectory: true) }

        init() throws {
            try mkdir("/flash/apps")
            try mkdir("/flash/apps_archiv")
            try mkdir("/sd")
            try moveConfig(["mounts": ["/flash", "/sd"]])
            let pipe = Pipe()
            simulator.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
            simulator.arguments = [CommandLine.arguments[2], remote.path]
            simulator.standardOutput = pipe
            simulator.standardError = FileHandle.standardError
            try simulator.run()
            guard let info = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.availableData) as? [String: String],
                  let path = info["path"] else { throw MoveTestFailure(description: "Simulator returned no PTY") }
            try expect(path.hasPrefix("/dev/ttys") || path.hasPrefix("/dev/pts/"), "Only isolated PTY is opened")
            port = path
        }

        deinit {
            if simulator.isRunning { simulator.terminate() }
            simulator.waitUntilExit()
            try? fm.removeItem(at: root)
        }

        func host(_ path: String) -> URL { remote.appendingPathComponent(String(path.dropFirst())) }
        func mkdir(_ path: String) throws { try fm.createDirectory(at: host(path), withIntermediateDirectories: true) }
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: host(path)) }
        func read(_ path: String) throws -> Data { try Data(contentsOf: host(path)) }
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: host(path).path) }
        func moveConfig(_ value: [String: Any]) throws { try JSONSerialization.data(withJSONObject: value).write(to: host("/.test-move")) }
        func fault(_ operation: String, _ path: String, code: Int = 5) throws {
            try JSONSerialization.data(withJSONObject: [["operation": operation, "path": path, "code": code]]).write(to: host("/.test-filesystem-faults"))
        }
        func clearFault() throws { try fm.removeItem(at: host("/.test-filesystem-faults")) }
        func snapshot() throws -> [String: Data] {
            guard let paths = fm.enumerator(at: remote, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
                throw MoveTestFailure(description: "Cannot enumerate fixture")
            }
            var snapshot: [String: Data] = [:]
            for case let path as URL in paths {
                if path.lastPathComponent.hasPrefix(".test-") { continue }
                let relative = String(path.path.dropFirst(remote.path.count))
                let directory = try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                snapshot[relative + (directory ? "/" : "")] = directory ? Data() : try Data(contentsOf: path)
            }
            return snapshot
        }
    }

    static func boardTests() throws {
        let fixture = try Fixture()
        let board = BoardSession(timeout: 2)
        try board.connect(path: fixture.port)
        defer { board.disconnect() }
        let unusual = "Grüezi 'Zitat' \"doppelt\".bin"
        let binary = Data((0..<3107).map { UInt8(truncatingIfNeeded: $0 * 31) })
        try binary.write(to: fixture.host("/flash/apps/" + unusual))
        try fixture.write("/flash/apps/empty", "")
        let paths = ["/flash/apps/" + unusual, "/flash/apps/empty"]
        let moved = try board.move(paths: paths, toDirectory: "/flash/apps_archiv")
        try expect(moved == ["/flash/apps_archiv/" + unusual, "/flash/apps_archiv/empty"], "Batch reports exact destinations in order")
        try expect(paths.allSatisfy { !fixture.exists($0) }, "Successful move removes all original names")
        try expect(try fixture.read(moved[0]) == binary && fixture.read(moved[1]).isEmpty, "Binary and empty files preserve exact bytes")
        try fixture.mkdir("/flash/apps/old/sub")
        try fixture.write("/flash/apps/old/sub/settings.json", "{\"value\":42}\n")
        _ = try board.move(paths: ["/flash/apps/old"], toDirectory: "/flash/apps_archiv")
        try expect(!fixture.exists("/flash/apps/old") && fixture.exists("/flash/apps_archiv/old/sub/settings.json"), "Directory move preserves nested contents")
        try expect(try fixture.read("/flash/apps_archiv/old/sub/settings.json") == Data("{\"value\":42}\n".utf8), "Directory data unchanged")
        print("PASS file/folder batch moves, exact bytes, Unicode and quote-safe paths")

        try fixture.write("/flash/apps/a.py", "first source")
        try fixture.write("/flash/apps/b.py", "second source")
        try fixture.write("/flash/apps_archiv/b.py", "existing destination")
        func unchanged(_ label: String, _ sources: [String], _ destination: String) throws {
            let before = try fixture.snapshot()
            try failure(label) { _ = try board.move(paths: sources, toDirectory: destination) }
            try expect(try fixture.snapshot() == before, "\(label) refuses before any filesystem mutation")
        }
        try unchanged("Late target collision", ["/flash/apps/a.py", "/flash/apps/b.py"], "/flash/apps_archiv")
        try fixture.mkdir("/flash/apps/folder")
        try fixture.write("/flash/apps/folder/child", "nested source")
        try fixture.mkdir("/flash/apps_archiv/folder")
        try unchanged("Directory target collision", ["/flash/apps/a.py", "/flash/apps/folder"], "/flash/apps_archiv")
        try fixture.mkdir("/flash/other")
        try fixture.write("/flash/other/a.py", "same basename")
        try unchanged("Duplicate target names", ["/flash/apps/a.py", "/flash/other/a.py"], "/flash/apps_archiv")
        try unchanged("Late missing source", ["/flash/apps/a.py", "/flash/apps/missing"], "/flash/apps_archiv")
        try unchanged("Duplicate source", ["/flash/apps/a.py", "/flash/apps/a.py"], "/flash/apps_archiv")
        try unchanged("Parent-child overlap", ["/flash/apps/folder", "/flash/apps/folder/child"], "/flash/apps_archiv")
        try unchanged("No selection", [], "/flash/apps_archiv")
        try unchanged("Same parent no-op", ["/flash/apps/a.py"], "/flash/apps")
        try unchanged("Directory into itself", ["/flash/apps/folder"], "/flash/apps/folder")
        try fixture.mkdir("/flash/apps/folder/sub")
        try unchanged("Directory into descendant", ["/flash/apps/folder"], "/flash/apps/folder/sub")
        try unchanged("Missing target directory", ["/flash/apps/a.py"], "/flash/absent")
        try unchanged("Target is a file", ["/flash/apps/a.py"], "/flash/apps/b.py")
        for protected in ["/", "/flash", "/sd", "/flash//"] {
            try unchanged("Protected volume \(protected)", [protected], "/flash/apps_archiv")
        }
        try unchanged("Traversal", ["/flash/apps/../apps/a.py"], "/flash/apps_archiv")
        try unchanged("Cross-filesystem", ["/flash/apps/a.py"], "/sd")
        print("PASS whole-batch collision preflight, invalid selections and protected paths")

        try fixture.mkdir("/flash/external/sub")
        try fixture.write("/flash/external/source", "mounted subtree")
        try fixture.moveConfig(["mounts": ["/flash", "/sd", "/flash/external"]])
        try unchanged("Nested mount root", ["/flash/external"], "/flash/apps_archiv")
        try unchanged("Out of nested filesystem", ["/flash/external/source"], "/flash/apps_archiv")
        try unchanged("Into nested filesystem", ["/flash/apps/a.py"], "/flash/external/sub")
        try fixture.mkdir("/flash/apps/folder/mounted")
        try fixture.moveConfig(["mounts": ["/flash", "/sd", "/flash/apps/folder/mounted"]])
        try unchanged("Directory contains a mount", ["/flash/apps/folder"], "/flash/apps_archiv/old")
        try fixture.mkdir("/flash/apps/over-mount")
        try fixture.write("/flash/apps/over-mount/keep", "do not cover target mount")
        for mounted in ["/flash/apps_archiv/over-mount", "/flash/apps_archiv/over-mount/card"] {
            try fixture.moveConfig(["mounts": ["/flash", "/sd", mounted]])
            try unchanged("Absent target covers existing mount \(mounted)", ["/flash/apps/over-mount"], "/flash/apps_archiv")
        }
        try fixture.moveConfig(["mounts": ["/flash", "/sd"], "tableError": true])
        try unchanged("Unreadable mount table", ["/flash/apps/a.py"], "/flash/apps_archiv")
        try fixture.moveConfig(["mounts": ["/flash", "/sd"]])
        print("PASS nested mount boundaries and unavailable mount introspection")

        try fm.removeItem(at: fixture.host("/flash/apps_archiv/b.py"))
        try fixture.write("/flash/apps/c.py", "third source")
        try fixture.fault("rename", "/flash/apps/b.py")
        let partial = try failure("Second rename fails") {
            _ = try board.move(paths: ["/flash/apps/a.py", "/flash/apps/b.py", "/flash/apps/c.py"], toDirectory: "/flash/apps_archiv")
        }
        try expect(!fixture.exists("/flash/apps/a.py") && fixture.exists("/flash/apps_archiv/a.py"), "First confirmed move remains committed")
        try expect(fixture.exists("/flash/apps/b.py") && fixture.exists("/flash/apps/c.py"), "Failed and unattempted sources remain")
        try expect(!fixture.exists("/flash/apps_archiv/b.py") && !fixture.exists("/flash/apps_archiv/c.py"), "No later destination created after partial failure")
        try expect(partial.localizedDescription.contains("/flash/apps_archiv/a.py"), "Partial error reports confirmed destination")
        try expect(!partial.localizedDescription.contains("/flash/apps_archiv/c.py"), "Unattempted destination is not presented as completed")
        try fixture.clearFault()
        try fixture.write("/.test-fault", "move-commit:reply-lost")
        let uncertain = try failure("Move response lost after mutation") {
            _ = try board.move(paths: ["/flash/apps/b.py", "/flash/apps/c.py"], toDirectory: "/flash/apps_archiv")
        }
        try expect(!fixture.exists("/flash/apps/b.py") && fixture.exists("/flash/apps_archiv/b.py"), "Reply-loss scenario really executes remote move")
        try expect(fixture.exists("/flash/apps/c.py") && !fixture.exists("/flash/apps_archiv/c.py"), "Lost reply stops batch before next file")
        try expect(uncertain.localizedDescription.lowercased().contains("unbestätigt"), "Lost reply is explicitly described as unconfirmed")
        try expect(try board.list(path: "/flash/apps_archiv").contains { $0.name == "b.py" }, "Same PTY recovers for readback after uncertainty")
        print("PASS partial rename error and lost response preserve real completion state")
    }

    static func serviceTests() throws {
        let fixture = try Fixture()
        let safety = fixture.root.appendingPathComponent("unchanged-safety", isDirectory: true)
        let selected = fixture.root.appendingPathComponent("chosen-delete-backups", isDirectory: true)
        try fm.createDirectory(at: selected, withIntermediateDirectories: false)
        let service = DeviceService(board: BoardSession(timeout: 2), backupDirectory: safety)
        _ = try result { service.connect(path: fixture.port, completion: $0) }
        defer { service.disconnect(); try? idle(service) }
        var callbacks: [String] = []
        service.onRefresh = { callbacks.append("refresh") }
        try fixture.write("/flash/apps/one.py", "one")
        let moved: [RemoteEntry] = try result { done in
            service.move(entries: [entry("/flash/apps/one.py")], toDirectory: "/flash/apps_archiv") { value in
                callbacks.append("completion"); done(value)
            }
        }
        try expect(moved.map(\.path) == ["/flash/apps_archiv/one.py"], "Service returns new file locations")
        try expect(callbacks == ["completion", "refresh"], "Move completion precedes exactly one refresh")
        try fixture.write("/flash/apps/one.py", "new original")
        callbacks.removeAll()
        try failure("Service collision") {
            _ = try result { done in
                service.move(entries: [entry("/flash/apps/one.py")], toDirectory: "/flash/apps_archiv") { value in
                    callbacks.append("completion"); done(value)
                }
            } as [RemoteEntry]
        }
        try expect(callbacks == ["completion", "refresh"], "Failure callback also precedes exactly one refresh")
        try fixture.write("/flash/apps/partial-first.py", "moved before failure")
        try fixture.write("/flash/apps/partial-second.py", "stays after failure")
        try fixture.fault("rename", "/flash/apps/partial-second.py")
        callbacks.removeAll()
        try failure("Service partial move") {
            _ = try result { done in
                service.move(entries: [entry("/flash/apps/partial-first.py"), entry("/flash/apps/partial-second.py")], toDirectory: "/flash/apps_archiv") { value in
                    callbacks.append("completion"); done(value)
                }
            } as [RemoteEntry]
        }
        try fixture.clearFault()
        try expect(callbacks == ["completion", "refresh"], "Partial mutation is delivered before exactly one refresh")
        try expect(!fixture.exists("/flash/apps/partial-first.py") && fixture.exists("/flash/apps/partial-second.py"), "Service partial failure preserves the actual per-file outcome")
        print("PASS service result/refresh ordering on success and failure")

        // Stall a prior read so both following actions are definitely queued
        // against the old device session before the terminal action executes.
        try fixture.write("/flash/apps/stale.py", "do not move")
        try fixture.write("/.test-fault", "list:stall")
        service.list(path: "/flash/apps") { _ in }
        service.send(command: "queued_terminal_marker = 1")
        try failure("Queued move after terminal invalidates its captured session") {
            _ = try result { service.move(entries: [entry("/flash/apps/stale.py")], toDirectory: "/flash/apps_archiv", completion: $0) } as [RemoteEntry]
        }
        try expect(fixture.exists("/flash/apps/stale.py") && !fixture.exists("/flash/apps_archiv/stale.py"), "Stale queued move preserves source")
        try idle(service)
        let exports = fixture.root.appendingPathComponent("exports", isDirectory: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: false)
        try fixture.write("/.test-fault", "list:stall")
        service.list(path: "/flash/apps") { _ in }
        service.send(command: "queued_terminal_marker = 2")
        try failure("Queued Finder export after terminal invalidates its captured session") {
            _ = try result { service.download(entry: entry("/flash/apps/stale.py"), to: exports, overwrite: false, completion: $0) } as URL
        }
        try expect(!fm.fileExists(atPath: exports.appendingPathComponent("stale.py").path), "Stale queued export never publishes old-session contents")
        try idle(service)
        let beforeRestart = fixture.root.appendingPathComponent("restart-exports", isDirectory: true)
        try fm.createDirectory(at: beforeRestart, withIntermediateDirectories: false)
        try fixture.write("/.test-fault", "list:stall")
        service.list(path: "/flash/apps") { _ in }
        service.restart()
        try failure("Queued export cannot outlive a preceding restart") {
            _ = try result { service.download(entry: entry("/flash/apps/stale.py"), to: beforeRestart, overwrite: false, completion: $0) } as URL
        }
        try expect(!fm.fileExists(atPath: beforeRestart.appendingPathComponent("stale.py").path), "Restart-invalidated export creates no file")
        try idle(service)
        var firstExport: Result<URL, Error>?
        service.download(entry: entry("/flash/apps/stale.py"), to: exports, overwrite: false) { firstExport = $0 }
        let secondExport = try result { service.download(entry: entry("/flash/apps/one.py"), to: exports, overwrite: false, completion: $0) }
        guard let firstExport else { throw MoveTestFailure(description: "First queued export callback missing") }
        let firstURL = try firstExport.get()
        try expect(try Data(contentsOf: firstURL) == Data("do not move".utf8) && Data(contentsOf: secondExport) == Data("new original".utf8), "Same-session Finder exports queue safely and preserve both files")
        print("PASS busy move rejection, queued export session guards and multiple valid Finder exports")

        try fixture.write("/flash/apps/delete.py", "recover exactly")
        let deletion = try result { service.delete(entry: entry("/flash/apps/delete.py"), backupFirst: true, backupDestination: selected, completion: $0) }
        guard let deletion else { throw MoveTestFailure(description: "Deletion returned no backup") }
        try expect(deletion.deletingLastPathComponent() == selected, "Deletion backup uses explicitly chosen directory")
        try expect(try Data(contentsOf: deletion.appendingPathComponent("Dateien/delete.py")) == Data("recover exactly".utf8), "Chosen backup contains original bytes")
        try expect(!fixture.exists("/flash/apps/delete.py"), "Source deleted only after completed chosen backup")
        try expect(!fm.fileExists(atPath: safety.path), "Deletion destination does not leak into default safety storage")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: deletion.appendingPathComponent("SICHERUNG.json"))) as! [String: Any]
        try expect(manifest["status"] as? String == "vollstaendig", "Backup is finalized before deletion")

        try fixture.write("/flash/apps/guarded.py", "keep on board")
        let plainFile = fixture.root.appendingPathComponent("not-a-folder")
        try Data("keep local file".utf8).write(to: plainFile)
        let missing = fixture.root.appendingPathComponent("missing/backup")
        let missingVolume = URL(fileURLWithPath: "/Volumes/M5-Tests-Absent-" + UUID().uuidString + "/Backups", isDirectory: true)
        for destination in [plainFile, missing, missingVolume] {
            try failure("Invalid chosen backup destination") {
                _ = try result { service.delete(entry: entry("/flash/apps/guarded.py"), backupFirst: true, backupDestination: destination, completion: $0) } as URL?
            }
            try expect(try fixture.read("/flash/apps/guarded.py") == Data("keep on board".utf8), "Invalid backup destination prevents deletion")
        }
        try expect(!fm.fileExists(atPath: missing.path) && !fm.fileExists(atPath: missingVolume.path), "Unavailable chosen paths are not silently created")
        try expect(try Data(contentsOf: plainFile) == Data("keep local file".utf8), "Existing non-directory destination remains intact")
        try fixture.fault("open", "/flash/apps/guarded.py")
        try failure("Failed backup copy blocks deletion") {
            _ = try result { service.delete(entry: entry("/flash/apps/guarded.py"), backupFirst: true, backupDestination: selected, completion: $0) } as URL?
        }
        try fixture.clearFault()
        try expect(fixture.exists("/flash/apps/guarded.py"), "Read failure during backup preserves remote source")

        let document = try result { service.openDocument(entry: entry("/flash/apps/guarded.py"), completion: $0) }
        let saved = try result { service.saveDocument(document, text: "edited", completion: $0) }
        try expect(saved.backupURL.path.hasPrefix(safety.path + "/"), "Editor safety backups still use original safety directory")
        try expect(try Data(contentsOf: saved.backupURL) == Data("keep on board".utf8), "Editor backup remains recoverable after choosing deletion folder")
        try fixture.write("/flash/apps/default-backup.py", "legacy default")
        let defaultBackup = try result { service.delete(entry: entry("/flash/apps/default-backup.py"), backupFirst: true, completion: $0) }
        try expect(defaultBackup?.deletingLastPathComponent() == safety, "Omitted destination retains service's existing backup default")
        try fixture.write("/flash/apps/no-backup.py", "explicitly no backup")
        let none = try result { service.delete(entry: entry("/flash/apps/no-backup.py"), backupFirst: false, backupDestination: missing, completion: $0) }
        try expect(none == nil && !fixture.exists("/flash/apps/no-backup.py"), "Explicit deletion without backup does not require a backup directory")
        print("PASS chosen deletion destination, missing volume guards, backup-first safety and unchanged editor backups")
    }

    static func disconnectedBatchTest() throws {
        let fixture = try Fixture()
        let board = BoardSession(timeout: 2)
        try board.connect(path: fixture.port)
        defer { board.disconnect() }
        for name in ["first", "second", "third"] { try fixture.write("/flash/apps/" + name, name) }
        try fixture.write("/.test-fault", "move-commit@2:disconnect")
        let error = try failure("Transport disappears before second commit") {
            _ = try board.move(paths: ["/flash/apps/first", "/flash/apps/second", "/flash/apps/third"], toDirectory: "/flash/apps_archiv")
        }
        try expect(!fixture.exists("/flash/apps/first") && fixture.exists("/flash/apps_archiv/first"), "Acknowledged first move survives connection loss")
        try expect(fixture.exists("/flash/apps/second") && fixture.exists("/flash/apps/third"), "Unsent later files are preserved by simulator")
        try expect(error.localizedDescription.contains("Bestätigt verschoben:\n/flash/apps_archiv/first"), "Disconnected batch reports only acknowledged first destination as confirmed")
        try expect(error.localizedDescription.contains("Letzter Schritt unbestätigt: /flash/apps/second → /flash/apps_archiv/second"), "Interrupted commit names exact uncertain source and destination")
        try expect(!error.localizedDescription.contains("/flash/apps_archiv/third"), "Never-attempted third destination is not claimed")
        print("PASS real PTY disconnect keeps acknowledged and uncertain batch results separate")
    }

    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else { throw MoveTestFailure(description: "Usage: move-tests <python3> <mock_board.py>") }
            try boardTests()
            try disconnectedBatchTest()
            try serviceTests()
            print("PASS \(checks) move/deletion assertions; PTY simulation only, no physical USB accessed")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
}
