import Foundation

struct FileToolsFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct FileToolsTests {
    static let fm = FileManager.default
    static var checks = 0

    static func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw FileToolsFailure(description: label) }
        checks += 1
    }

    static func expectError(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch { checks += 1; return }
        throw FileToolsFailure(description: "Expected error: \(label)")
    }

    static func expectFilesystemError(_ path: String, _ code: Int, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch M5Error.filesystem(let actualPath, let actualCode) {
            try expect(actualPath == path && actualCode == code, "Filesystem error preserves \(path), errno \(code)")
            return
        } catch { throw FileToolsFailure(description: "Expected filesystem error, got \(error)") }
        throw FileToolsFailure(description: "Expected filesystem error at \(path)")
    }

    static func run() throws {
        guard CommandLine.arguments.count == 3 else { throw FileToolsFailure(description: "Usage: file-tools-tests <python3> <mock_board.py>") }
        let root = fm.temporaryDirectory.appendingPathComponent("m5-tools-tests-\(UUID().uuidString)", isDirectory: true)
        let boardRoot = root.appendingPathComponent("board", isDirectory: true)
        try fm.createDirectory(at: boardRoot.appendingPathComponent("flash"), withIntermediateDirectories: true)
        try fm.createDirectory(at: boardRoot.appendingPathComponent("sd"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func host(_ path: String) -> URL { boardRoot.appendingPathComponent(String(path.dropFirst())) }
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: host(path)) }
        func mkdir(_ path: String) throws { try fm.createDirectory(at: host(path), withIntermediateDirectories: true) }
        func read(_ path: String) throws -> String { try String(contentsOf: host(path), encoding: .utf8) }
        let faultURL = boardRoot.appendingPathComponent(".test-filesystem-faults")
        func fault(_ operation: String, _ path: String, _ code: Int) throws {
            try JSONSerialization.data(withJSONObject: [["operation":operation,"path":path,"code":code]]).write(to: faultURL)
        }
        func clearFault() throws { try fm.removeItem(at: faultURL) }

        let simulator = Process()
        simulator.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        simulator.arguments = [CommandLine.arguments[2], boardRoot.path]
        let pipe = Pipe()
        simulator.standardOutput = pipe
        simulator.standardError = FileHandle.standardError
        try simulator.run()
        defer { if simulator.isRunning { simulator.terminate() }; simulator.waitUntilExit() }
        guard let info = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.availableData) as? [String:String],
              let port = info["path"] else { throw FileToolsFailure(description: "Simulator returned no PTY") }
        try expect(port.hasPrefix("/dev/ttys") || port.hasPrefix("/dev/pts/"), "Only isolated PTY opened")
        let board = BoardSession(timeout: 2)
        defer { board.disconnect() }
        var output = ""
        board.onOutput = { output += $0 }
        try board.connect(path: port)

        let statvfsURL = boardRoot.appendingPathComponent(".test-statvfs")
        try JSONSerialization.data(withJSONObject: [4096,1024,1000,250,200,0,0,0,0,255]).write(to: statvfsURL)
        let usage = try board.storage(path: "/flash")
        try expect(usage.path == "/flash", "Storage names selected path")
        try expect(usage.totalBytes == 1_024_000 && usage.freeBytes == 256_000, "Storage uses fragment size and free blocks")
        try JSONSerialization.data(withJSONObject: [4096,0,100,25,20,0,0,0,0,255]).write(to: statvfsURL)
        let fallbackUsage = try board.storage(path: "/sd")
        try expect(fallbackUsage.totalBytes == 409_600 && fallbackUsage.freeBytes == 102_400, "Storage falls back to block size when fragment size is zero")
        try fault("statvfs", "/sd", 19)
        try expectFilesystemError("/sd", 19) { _ = try board.storage(path: "/sd") }
        try clearFault()
        print("PASS storage capacity and unavailable media")

        let bootURL = boardRoot.appendingPathComponent(".test-boot-option")
        func bootFixture(_ values: [String:Any]) throws {
            try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]).write(to: bootURL)
        }
        let genericBoot = try board.uiFlowBootOption()
        try expect(genericBoot == nil, "Generic MicroPython has no UIFlow boot option")
        try bootFixture(["standard":true])
        let standardBoot = try board.uiFlowBootOption()
        try expect(standardBoot == nil, "Standard ESP32 NVS without u8 methods is not UIFlow")
        try expectError("Unsupported NVS setters refused") { try board.setUIFlowBootOption(0) }
        try bootFixture([:])
        let absentBefore = try Data(contentsOf: bootURL)
        let absentBoot = try board.uiFlowBootOption()
        try expect(absentBoot == 1, "Missing UIFlow key 4354 has menu default 1")
        try expect(try Data(contentsOf: bootURL) == absentBefore, "Boot probe does not persist default or modify NVS")
        for option in 0...2 {
            try board.setUIFlowBootOption(option)
            let storedOption = try board.uiFlowBootOption()
            try expect(storedOption == option, "UIFlow option \(option) committed and read back")
        }
        let validBefore = try Data(contentsOf: bootURL)
        try expectError("Invalid negative boot option") { try board.setUIFlowBootOption(-1) }
        try expectError("Invalid high boot option") { try board.setUIFlowBootOption(3) }
        try expect(try Data(contentsOf: bootURL) == validBefore, "Invalid boot options leave prior value unchanged")
        try bootFixture(["value":9])
        try expectError("Unknown stored boot option refused") { _ = try board.uiFlowBootOption() }
        try bootFixture(["readError":5])
        try expectError("Unexpected boot read failure propagated") { _ = try board.uiFlowBootOption() }
        try bootFixture(["value":1, "writeError":5])
        try expectError("Boot write failure propagated") { try board.setUIFlowBootOption(0) }
        try bootFixture(["value":1, "commitError":5])
        try expectError("Boot commit failure propagated") { try board.setUIFlowBootOption(0) }
        try bootFixture(["value":1, "dropCommit":true])
        try expectError("Boot read-back mismatch detected") { try board.setUIFlowBootOption(0) }
        let retainedBoot = try board.uiFlowBootOption()
        try expect(retainedBoot == 1, "Failed commit verification retains observed old option")
        try fm.removeItem(at: bootURL)
        print("PASS UIFlow boot-option capability, defaults, persistence and failures")

        let quotedPath = "/flash/Grüezi 'Zitat' \"doppelt\".bin"
        let bytes = Data((0..<2509).map { UInt8(truncatingIfNeeded: $0 * 31) })
        try bytes.write(to: host(quotedPath))
        let contents = try board.readFile(path: quotedPath, maxBytes: bytes.count)
        try expect(contents == bytes, "Exact bounded multi-chunk binary read with quote-safe path")
        try expectError("Over-limit read rejected") { _ = try board.readFile(path: quotedPath, maxBytes: bytes.count - 1) }
        try expect(try Data(contentsOf: host(quotedPath)) == bytes, "Refused preview preserves source")
        try write("/flash/empty", "")
        let empty = try board.readFile(path: "/flash/empty", maxBytes: 0)
        try expect(empty.isEmpty, "Empty file allowed with zero-byte limit")
        try expectError("Negative read limit") { _ = try board.readFile(path: quotedPath, maxBytes: -1) }
        try expectError("Reading directory") { _ = try board.readFile(path: "/flash") }
        try expectFilesystemError("/flash/missing", 2) { _ = try board.readFile(path: "/flash/missing") }
        try fault("open", quotedPath, 5)
        try expectFilesystemError(quotedPath, 5) { _ = try board.readFile(path: quotedPath) }
        try clearFault()
        print("PASS bounded preview, exact bytes and read errors")

        let uncertainUpload = root.appendingPathComponent("uncertain-upload.bin")
        try Data("committed despite lost reply".utf8).write(to: uncertainUpload)
        try write("/flash/uncertain.bin", "previous content")
        try write("/.test-fault", "upload-commit:reply-lost")
        try expectError("Lost commit response is reported as uncertain upload") {
            try board.upload(localURL: uncertainUpload, remotePath: "/flash/uncertain.bin", overwrite: true, progress: nil)
        }
        try expect(try read("/flash/uncertain.bin") == "committed despite lost reply", "Reply-lost fault executes commit before dropping response")
        let recoveredCommit = try board.readFile(path: "/flash/uncertain.bin")
        try expect(String(decoding: recoveredCommit, as: UTF8.self) == "committed despite lost reply", "Same PTY session recovers after uncertain commit")
        try expect(!fm.fileExists(atPath: boardRoot.appendingPathComponent(".test-fault").path), "Reply-lost fault is consumed once")
        print("PASS lost upload-commit response models an actual committed target and session recovery")

        let renamedPath = "/flash/Neu 'ä' \"Name\".bin"
        try board.rename(path: quotedPath, to: renamedPath)
        try expect(!fm.fileExists(atPath: host(quotedPath).path), "Rename removes original name")
        try expect(try Data(contentsOf: host(renamedPath)) == bytes, "Rename preserves all bytes")
        try write("/flash/existing.bin", "keep destination")
        try expectError("Rename collision") { try board.rename(path: renamedPath, to: "/flash/existing.bin") }
        try expect(try read("/flash/existing.bin") == "keep destination", "Collision preserves destination")
        try expect(try Data(contentsOf: host(renamedPath)) == bytes, "Collision preserves source")
        try expectError("Cross-directory rename") { try board.rename(path: renamedPath, to: "/sd/new.bin") }
        try expectError("Same-name rename") { try board.rename(path: renamedPath, to: renamedPath) }
        try fault("rename", renamedPath, 5)
        try expectFilesystemError(renamedPath, 5) { try board.rename(path: renamedPath, to: "/flash/faulted.bin") }
        try clearFault()
        try expect(fm.fileExists(atPath: host(renamedPath).path) && !fm.fileExists(atPath: host("/flash/faulted.bin").path), "Rename error leaves source intact")
        try mkdir("/flash/old-folder/sub")
        try write("/flash/old-folder/sub/keep", "inside")
        try board.rename(path: "/flash/old-folder", to: "/flash/new-folder")
        try expect(try read("/flash/new-folder/sub/keep") == "inside", "Directory rename preserves children")
        for protected in ["/", "/flash", "/sd", "/flash//"] {
            try expectError("Protected rename source") { try board.rename(path: protected, to: "/renamed") }
            try expectError("Protected rename destination") { try board.rename(path: renamedPath, to: protected) }
            try expectError("Protected remove") { try board.remove(path: protected, recursive: true) }
        }
        try expectError("Traversal rejected") { try board.remove(path: "/flash/../sd", recursive: true) }
        try expectFilesystemError("/flash/missing", 2) { try board.rename(path: "/flash/missing", to: "/flash/absent") }
        print("PASS rename, collisions and protected roots")

        try write("/flash/delete.txt", "delete me")
        try board.remove(path: "/flash/delete.txt", recursive: false)
        try expect(!fm.fileExists(atPath: host("/flash/delete.txt").path), "Single file removed")
        try mkdir("/flash/empty-folder")
        try board.remove(path: "/flash/empty-folder", recursive: false)
        try expect(!fm.fileExists(atPath: host("/flash/empty-folder").path), "Empty directory removed")
        try expectError("Nonrecursive nonempty delete refused") { try board.remove(path: "/flash/new-folder", recursive: false) }
        try expect(try read("/flash/new-folder/sub/keep") == "inside", "Refused tree delete preserved contents")
        try fault("listdir", "/flash/new-folder/sub", 5)
        try expectFilesystemError("/flash/new-folder/sub", 5) { try board.remove(path: "/flash/new-folder", recursive: true) }
        try clearFault()
        try expect(try read("/flash/new-folder/sub/keep") == "inside", "Preflight error causes no deletion")
        try fault("remove", "/flash/new-folder/sub/keep", 5)
        try expectFilesystemError("/flash/new-folder/sub/keep", 5) { try board.remove(path: "/flash/new-folder", recursive: true) }
        try clearFault()
        try expect(fm.fileExists(atPath: host("/flash/new-folder/sub/keep").path), "Device deletion error keeps failing file")
        try board.remove(path: "/flash/new-folder", recursive: true)
        try expect(!fm.fileExists(atPath: host("/flash/new-folder").path), "Recursive directory removal completes")
        try expectFilesystemError("/flash/missing", 2) { try board.remove(path: "/flash/missing", recursive: false) }

        let deep = "/flash/deep/" + Array(repeating: "x", count: 34).joined(separator: "/")
        try mkdir(deep)
        try write(deep + "/keep", "deep content")
        try expectError("Depth bound prevents recursive deletion") { try board.remove(path: "/flash/deep", recursive: true) }
        try expect(try read(deep + "/keep") == "deep content", "Depth bound rejected before deletion")
        try mkdir("/flash/wide")
        for index in 0..<4097 { try write("/flash/wide/\(index)", "") }
        try expectError("Entry bound prevents recursive deletion") { try board.remove(path: "/flash/wide", recursive: true) }
        try expect(try fm.contentsOfDirectory(atPath: host("/flash/wide").path).count == 4097, "Entry bound rejected before deletion")
        try fm.createSymbolicLink(at: host("/flash/link"), withDestinationURL: host("/flash/existing.bin"))
        try expectError("Symlink cannot be renamed") { try board.rename(path: "/flash/link", to: "/flash/link2") }
        try expectError("Symlink cannot be removed as a regular file") { try board.remove(path: "/flash/link", recursive: false) }
        try expect(try read("/flash/existing.bin") == "keep destination", "Type safeguards preserve link target")
        print("PASS bounded recursive deletion, preflight, fault paths and type safeguards")

        try mkdir("/flash/Programm 'ä'")
        try write("/flash/Programm 'ä'/helper.py", "value = 'relative-import-ok'\n")
        try write("/flash/Programm 'ä'/input.txt", "relative-file-ok")
        let program = "/flash/Programm 'ä'/Start \"Test\".py"
        try write(program, "import helper\nprint(helper.value)\nprint(open('input.txt').read())\nprint(__name__)\nprint(__file__)\nwhile True:\n    pass\n")
        let start = Date()
        try board.runFile(path: program)
        try expect(Date().timeIntervalSince(start) < 2, "runFile returns after submission while script keeps running")
        for _ in 0..<100 {
            try board.pollOutput()
            if output.contains("relative-file-ok") && output.contains(program) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try expect(output.contains("relative-import-ok") && output.contains("relative-file-ok"), "Running file resolves sibling imports and relative files")
        try expect(output.contains("__main__") && output.contains(program), "Script namespace has __main__ and original __file__")
        try board.interrupt()
        for _ in 0..<100 {
            try board.pollOutput()
            if output.contains("KeyboardInterrupt") { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try expect(output.contains("KeyboardInterrupt"), "Later interrupt stops running program and appears in terminal")
        try board.send(command: "import os; print('restored-cwd:' + os.getcwd())")
        for _ in 0..<100 {
            try board.pollOutput()
            if output.contains("restored-cwd:/") { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try expect(output.contains("restored-cwd:/"), "Program wrapper restores working directory after interrupt")
        try expectError("Non-Python execution refused") { try board.runFile(path: renamedPath) }
        try expectFilesystemError("/flash/missing.py", 2) { try board.runFile(path: "/flash/missing.py") }
        try mkdir("/flash/folder.py")
        try expectError("Directory with py extension refused") { try board.runFile(path: "/flash/folder.py") }
        let afterRun = try board.readFile(path: "/flash/existing.bin")
        try expect(String(decoding: afterRun, as: UTF8.self) == "keep destination", "Filesystem commands recover after running/interrupting program")
        print("PASS asynchronous Python run, quotes, relative imports/files, stdout and interrupt")
        print("SUCCESS: \(checks) file-tool checks; simulated device only")
    }

    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
