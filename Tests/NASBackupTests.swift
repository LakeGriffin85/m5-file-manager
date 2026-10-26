import Foundation
import Darwin

private struct NASFailure: Error, CustomStringConvertible { let description: String }

@main
struct NASBackupTests {
    static let fm = FileManager.default
    static var checks = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NASFailure(description: label) }
        checks += 1
    }
    static func failure(_ label: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch let error as NASFailure { throw error }
        catch { checks += 1; return }
        throw NASFailure(description: "Expected refusal: " + label)
    }
    static func result<T>(_ start: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        var answer: Result<T, Error>?
        start { answer = $0 }
        let deadline = Date().addingTimeInterval(35)
        while answer == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard let answer else { throw NASFailure(description: "Service callback timed out") }
        return try answer.get()
    }
    static func forcedUnsupported(_ source: URL, _ target: URL) -> Int32 { errno = ENOTSUP; return -1 }
    static func entry(_ path: String, directory: Bool = false) -> RemoteEntry {
        RemoteEntry(name: (path as NSString).lastPathComponent, path: path, isDirectory: directory, size: 0)
    }
    static func run() throws {
        let local = fm.temporaryDirectory.appendingPathComponent("m5-nas-test-" + UUID().uuidString)
        try fm.createDirectory(at: local, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: local) }
        let bytes = Data((0..<131_083).map { UInt8(truncatingIfNeeded: $0 * 37) })
        let source = local.appendingPathComponent("source"), destination = local.appendingPathComponent("destination")
        try bytes.write(to: source)
        try LocalFileMove.exclusive(source, to: destination, rename: forcedUnsupported)
        try expect(try Data(contentsOf: destination) == bytes, "Fallback preserves multichunk binary bytes")
        try expect(!fm.fileExists(atPath: source.path), "Verified fallback removes staging source")
        try Data("existing source".utf8).write(to: source)
        try failure("Existing destination") { try LocalFileMove.exclusive(source, to: destination, rename: forcedUnsupported) }
        try expect(try Data(contentsOf: source) == Data("existing source".utf8), "Collision keeps source")
        try expect(try Data(contentsOf: destination) == bytes, "Collision keeps destination")
        let absent = local.appendingPathComponent("absent/target")
        try failure("Missing parent") { try LocalFileMove.exclusive(source, to: absent, rename: forcedUnsupported) }
        try expect(fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: absent.path), "Failed creation preserves source")
        let link = local.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        try failure("Source symlink") { try LocalFileMove.exclusive(link, to: local.appendingPathComponent("link-copy"), rename: forcedUnsupported) }
        let broken = local.appendingPathComponent("broken-target")
        try fm.createSymbolicLink(at: broken, withDestinationURL: absent)
        try failure("Broken destination symlink") { try LocalFileMove.exclusive(source, to: broken, rename: forcedUnsupported) }
        try expect(try fm.destinationOfSymbolicLink(atPath: broken.path) == absent.path, "Broken symlink remains untouched")
        let folder = local.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try failure("Directories cannot enter file fallback") { try LocalFileMove.exclusive(folder, to: local.appendingPathComponent("folder-copy"), rename: forcedUnsupported) }
        try failure("Permission errors are not treated as missing capability") {
            try LocalFileMove.exclusive(source, to: local.appendingPathComponent("permission-copy"), rename: { _, _ in errno = EACCES; return -1 })
        }
        try expect(fm.fileExists(atPath: source.path), "Unrelated rename failure preserves source")
        let empty = local.appendingPathComponent("empty"), emptyCopy = local.appendingPathComponent("empty-copy")
        try Data().write(to: empty)
        try LocalFileMove.exclusive(empty, to: emptyCopy, rename: forcedUnsupported)
        try expect(try Data(contentsOf: emptyCopy).isEmpty, "Empty file fallback works")
        print("PASS forced unsupported rename, binary/empty files, collision and symlink protection")

        let parent = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        guard try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw NASFailure(description: "Backup test parent must already exist") }
        let nas = parent.appendingPathComponent(".m5-owned-test-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: nas, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        defer { try? fm.removeItem(at: nas) }
        let boardRoot = local.appendingPathComponent("board")
        try fm.createDirectory(at: boardRoot.appendingPathComponent("flash"), withIntermediateDirectories: true)
        try fm.createDirectory(at: boardRoot.appendingPathComponent("sd/run/nested"), withIntermediateDirectories: true)
        try bytes.write(to: boardRoot.appendingPathComponent("sd/run/nested/binary.bin"))
        try Data("timestamp,value\n2026-10-07,42\n".utf8).write(to: boardRoot.appendingPathComponent("sd/run/data.csv"))
        try Data().write(to: boardRoot.appendingPathComponent("sd/run/empty"))
        try Data("download with quotes".utf8).write(to: boardRoot.appendingPathComponent("flash/Grüezi ' test.txt"))
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        process.arguments = [CommandLine.arguments[2], boardRoot.path]
        process.standardOutput = pipe; process.standardError = FileHandle.standardError
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let info = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.availableData) as! [String:String]
        let port = info["path"]!
        try expect(port.hasPrefix("/dev/ttys") || port.hasPrefix("/dev/pts/"), "Only local simulated board is opened")
        let service = DeviceService(board: BoardSession(timeout: 3), backupDirectory: local.appendingPathComponent("safety"))
        _ = try result { service.connect(path: port, completion: $0) }
        let downloaded = try result { service.download(entry: entry("/flash/Grüezi ' test.txt"), to: nas, overwrite: false, completion: $0) }
        try expect(try Data(contentsOf: downloaded) == Data("download with quotes".utf8), "Actual volume receives quoted UTF-8 download")
        try failure("NAS download cannot overwrite without confirmation") {
            _ = try result { service.download(entry: entry("/flash/Grüezi ' test.txt"), to: nas, overwrite: false, completion: $0) }
        }
        try Data("changed source".utf8).write(to: boardRoot.appendingPathComponent("flash/Grüezi ' test.txt"))
        _ = try result { service.download(entry: entry("/flash/Grüezi ' test.txt"), to: nas, overwrite: true, completion: $0) }
        try expect(try Data(contentsOf: downloaded) == Data("changed source".utf8), "Confirmed NAS overwrite completes")
        let backup = try result { service.delete(entry: entry("/sd/run", directory: true), backupFirst: true, backupDestination: nas, completion: $0) }
        guard let backup else { throw NASFailure(description: "No recovery backup returned") }
        try expect(!fm.fileExists(atPath: boardRoot.appendingPathComponent("sd/run").path), "Simulated folder removed only after backup")
        try expect(try Data(contentsOf: backup.appendingPathComponent("Dateien/run/nested/binary.bin")) == bytes, "NAS recovery copy contains exact binary bytes")
        try expect(try Data(contentsOf: backup.appendingPathComponent("Dateien/run/data.csv")) == Data("timestamp,value\n2026-10-07,42\n".utf8), "NAS recovery CSV matches")
        try expect(try Data(contentsOf: backup.appendingPathComponent("Dateien/run/empty")).isEmpty, "NAS recovery includes empty file")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: backup.appendingPathComponent("SICHERUNG.json"))) as! [String:Any]
        try expect(manifest["status"] as? String == "vollstaendig" && manifest["fileCount"] as? Int == 3, "NAS backup is marked complete with correct count")
        try expect(backup.pathExtension != "unvollstaendig", "Completed NAS directory is finalized")
        try expect(try fm.contentsOfDirectory(atPath: nas.path).allSatisfy { !$0.hasPrefix(".m5fm-") }, "No download staging residue on volume")
        print("PASS real chosen filesystem: download, overwrite, nested deletion backup and manifest; board is only PTY")
        print("SUCCESS: \(checks) NAS compatibility checks")
    }
    static func main() {
        do {
            guard CommandLine.arguments.count == 4 else { throw NASFailure(description: "Usage: nas-tests python mock_board existing-backup-parent") }
            try run()
        } catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
}
