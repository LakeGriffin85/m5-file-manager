import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct IntegrationTests {
    static let fm = FileManager.default
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw TestFailure(description: label) }
        checks += 1
    }

    static func expectError(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch { checks += 1; return }
        throw TestFailure(description: "Expected error: \(label)")
    }

    static func expectFilesystemError(path: String, code: Int, _ label: String,
                                      _ operation: () throws -> Void) throws {
        do { try operation() }
        catch M5Error.filesystem(let actualPath, let actualCode) {
            try expect(actualPath == path && actualCode == code, "\(label): exact path and errno")
            return
        } catch {
            throw TestFailure(description: "\(label): expected structured filesystem error, got \(error)")
        }
        throw TestFailure(description: "Expected filesystem error: \(label)")
    }

    static func bytes(_ count: Int, salt: Int = 0) -> Data {
        var result = Data()
        result.reserveCapacity(count)
        for index in 0..<count {
            result.append(UInt8(truncatingIfNeeded: index * 37 + salt))
        }
        return result
    }

    static func verifyProgress(_ values: [Double], _ name: String) throws {
        try expect(!values.isEmpty, "\(name): progress callback fired")
        try expect(values.allSatisfy { $0 >= 0 && $0 <= 1 }, "\(name): progress in 0...1")
        try expect(values.last == 1, "\(name): progress reached 100%")
        var previous = 0.0
        for value in values {
            try expect(value >= previous, "\(name): progress monotonic")
            previous = value
        }
    }

    static func run() throws {
        guard CommandLine.arguments.count == 3 else {
            throw TestFailure(description: "Usage: integration-tests <python3> <mock_board.py>")
        }
        let root = fm.temporaryDirectory.appendingPathComponent("m5-file-tests-\(UUID().uuidString)", isDirectory: true)
        let boardRoot = root.appendingPathComponent("board", isDirectory: true)
        let localRoot = root.appendingPathComponent("mac", isDirectory: true)
        try fm.createDirectory(at: boardRoot.appendingPathComponent("flash"), withIntermediateDirectories: true)
        try fm.createDirectory(at: boardRoot.appendingPathComponent("sd"), withIntermediateDirectories: true)
        try fm.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let fixtureName = "Grüezi 'Zitat' \"doppelt\".bin"
        let remotePath = "/flash/\(fixtureName)"
        let boardFile = boardRoot.appendingPathComponent("flash").appendingPathComponent(fixtureName)
        let localFile = localRoot.appendingPathComponent(fixtureName)
        let payload = bytes(32_789)
        try payload.write(to: localFile)
        try Data("boot marker\n".utf8).write(to: boardRoot.appendingPathComponent("boot.py"))

        let simulator = Process()
        simulator.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        simulator.arguments = [CommandLine.arguments[2], boardRoot.path]
        let infoPipe = Pipe()
        simulator.standardOutput = infoPipe
        simulator.standardError = FileHandle.standardError
        try simulator.run()
        defer {
            if simulator.isRunning { simulator.terminate() }
            simulator.waitUntilExit()
        }
        let infoData = infoPipe.fileHandleForReading.availableData
        guard let info = try JSONSerialization.jsonObject(with: infoData) as? [String: String],
              let port = info["path"] else {
            throw TestFailure(description: "Simulator did not return a PTY path")
        }
        // PTY devices belong only to this test process. No USB port scan/connect.
        try expect(port.hasPrefix("/dev/ttys") || port.hasPrefix("/dev/pts/"), "Simulator returned a local PTY")
        let board = BoardSession(timeout: 1.5)
        defer { board.disconnect() }
        var terminalOutput = ""
        board.onOutput = { terminalOutput += $0 }
        try board.connect(path: port)

        // Representative CSV size, with binary bytes to verify encoding boundaries too.
        let previewPayload = bytes(93_497)
        let previewFixture = boardRoot.appendingPathComponent("flash/preview.bin")
        try previewPayload.write(to: previewFixture)
        var previewProgress: [Double] = []
        let previewStarted = ProcessInfo.processInfo.systemUptime
        let previewRead = try board.readFile(path: "/flash/preview.bin", progress: { previewProgress.append($0) })
        try expect(previewRead == previewPayload, "93 KB preview returns exact bytes across base64 boundaries")
        try expect(previewProgress.count == 24 && previewProgress.last == 1, "23 read chunks plus verified completion")
        try expect(zip(previewProgress, previewProgress.dropFirst()).allSatisfy { $0 <= $1 }, "Preview progress is monotonic")
        print(String(format: "Preview model: 93497 bytes, %.3f s", ProcessInfo.processInfo.systemUptime - previewStarted))
        try expectError("Preview limit rejects oversized file") { _ = try board.readFile(path: "/flash/preview.bin", maxBytes: 93_496) }
        try Data().write(to: previewFixture)
        let emptyPreview = try board.readFile(path: "/flash/preview.bin")
        try expect(emptyPreview.isEmpty, "Empty preview returns exact empty snapshot")
        try fm.removeItem(at: previewFixture)
        print("PASS connect to isolated PTY")

        let volumes = try board.volumes()
        try expect(volumes.contains { $0.path == "/sd" }, "Mounted SD exposed")
        try expect(volumes.contains { $0.path == "/" || $0.path == "/flash" }, "Flash exposed")
        try fm.removeItem(at: boardRoot.appendingPathComponent("sd"))
        let noSD = try board.volumes()
        try expect(!noSD.contains { $0.path == "/sd" }, "Absent SD not offered as mounted")
        try fm.createDirectory(at: boardRoot.appendingPathComponent("sd"), withIntermediateDirectories: false)
        let emptySD = try board.list(path: "/sd")
        try expect(emptySD.isEmpty, "An empty accessible SD is a successful empty list")

        let fsFault = boardRoot.appendingPathComponent(".test-filesystem-faults")
        func filesystemFault(path: String, code: Int, operation: String = "listdir") throws {
            let data = try JSONSerialization.data(withJSONObject: [["operation":operation, "path":path, "code":code]])
            try data.write(to: fsFault)
        }
        try fm.createDirectory(at: boardRoot.appendingPathComponent("sd/subdir"), withIntermediateDirectories: false)
        try filesystemFault(path: "/sd", code: 19)
        try expectFilesystemError(path: "/sd", code: 19, "Refresh of inaccessible SD") {
            _ = try board.list(path: "/sd")
        }
        let inaccessibleSD = try board.volumes()
        try expect(!inaccessibleSD.contains { $0.path == "/sd" }, "Root refresh omits inaccessible SD")
        try expect(inaccessibleSD.contains { $0.path == "/flash" }, "Root refresh retains readable flash")
        try expect(terminalOutput.contains("SD-Karte unter /sd nicht verfügbar (Fehler 19)"), "Unavailable SD warning names path and errno")
        let accessibleFlash = try board.list(path: "/flash")
        try expect(accessibleFlash.isEmpty, "Flash still readable in the same session after SD ENODEV")
        let rootWithFault = try board.list(path: "/")
        try expect(!rootWithFault.contains { $0.name == ".test-filesystem-faults" }, "Simulator fault marker not exposed")

        try filesystemFault(path: "/sd/subdir", code: 19)
        try expectFilesystemError(path: "/sd/subdir", code: 19, "Refresh of inaccessible SD subdirectory") {
            _ = try board.list(path: "/sd/subdir")
        }
        let readableSDRoot = try board.volumes()
        try expect(readableSDRoot.contains { $0.path == "/sd" }, "A failing subdirectory does not hide readable SD root")

        try Data("visible".utf8).write(to: boardRoot.appendingPathComponent("sd/subdir/visible.bin"))
        try Data("unavailable".utf8).write(to: boardRoot.appendingPathComponent("sd/subdir/unavailable.bin"))
        try filesystemFault(path: "/sd/subdir/unavailable.bin", code: 19, operation: "stat")
        try expectFilesystemError(path: "/sd/subdir/unavailable.bin", code: 19, "Entry stat failure rejects whole listing") {
            _ = try board.list(path: "/sd/subdir")
        }
        try filesystemFault(path: "/sd/subdir/unavailable.bin", code: 2, operation: "stat")
        try expectFilesystemError(path: "/sd/subdir/unavailable.bin", code: 2, "Entry disappeared during listing") {
            _ = try board.list(path: "/sd/subdir")
        }
        try filesystemFault(path: "/sd", code: 2, operation: "stat")
        let vanishedSD = try board.volumes()
        try expect(!vanishedSD.contains { $0.path == "/sd" }, "SD disappearing between root list and stat is optional")
        try filesystemFault(path: "/sd", code: 5)
        try expectFilesystemError(path: "/sd", code: 5, "Unexpected SD discovery error is not hidden") {
            _ = try board.volumes()
        }
        try expectFilesystemError(path: "/sd", code: 5, "Unexpected list error retains errno") {
            _ = try board.list(path: "/sd")
        }
        try filesystemFault(path: "/flash", code: 19)
        try expectFilesystemError(path: "/flash", code: 19, "Unavailable flash is a discovery error") {
            _ = try board.volumes()
        }
        try filesystemFault(path: "/", code: 19)
        try expectFilesystemError(path: "/", code: 19, "Unavailable root is a discovery error") {
            _ = try board.volumes()
        }
        try fm.removeItem(at: fsFault)
        let restoredVolumes = try board.volumes()
        try expect(restoredVolumes.contains { $0.path == "/sd" }, "Root refresh restores readable SD without reconnect")
        let restoredList = try board.list(path: "/sd/subdir")
        try expect(restoredList.count == 2, "Full directory list restored after transient stat error")
        try expectFilesystemError(path: "/missing", code: 2, "Missing directory remains a distinct error") {
            _ = try board.list(path: "/missing")
        }
        print("PASS ENODEV refresh, optional SD discovery, exact filesystem errors and recovery")

        try board.createDirectory(path: "/flash/Ordner mit ä und 'Zitat'")
        let firstList = try board.list(path: "/flash")
        try expect(firstList.contains { $0.name == "Ordner mit ä und 'Zitat'" && $0.isDirectory }, "Directory list preserves Unicode/quotes and type")
        print("PASS volumes and directory metadata")

        var uploadProgress: [Double] = []
        try board.upload(localURL: localFile, remotePath: remotePath, overwrite: false, progress: { uploadProgress.append($0) })
        let stored = try Data(contentsOf: boardFile)
        try expect(stored == payload, "Multi-chunk binary upload exact on board filesystem")
        try verifyProgress(uploadProgress, "upload")
        let listing = try board.list(path: "/flash")
        try expect(listing.contains { $0.name == fixtureName && $0.path == remotePath && !$0.isDirectory && $0.size == Int64(payload.count) }, "Uploaded file exact metadata")
        print("PASS multi-chunk binary upload with Unicode and quotes")

        try expectError("upload cannot overwrite a remote directory") {
            try board.upload(localURL: localFile, remotePath: "/flash/Ordner mit ä und 'Zitat'", overwrite: true, progress: nil)
        }
        try expectError("upload source must be a regular file") {
            try board.upload(localURL: localRoot, remotePath: "/flash/directory-as-file", overwrite: false, progress: nil)
        }
        let invalidDownload = localRoot.appendingPathComponent("directory-as-file.bin")
        try expectError("download source must be a regular file") {
            try board.download(remotePath: "/flash/Ordner mit ä und 'Zitat'", localURL: invalidDownload, overwrite: false, progress: nil)
        }
        try expect(!fm.fileExists(atPath: invalidDownload.path), "Directory download leaves no file")
        try expectError("download cannot overwrite a local directory") {
            try board.download(remotePath: remotePath, localURL: localRoot, overwrite: true, progress: nil)
        }
        try expectError("mkdir cannot replace a remote file") { try board.createDirectory(path: remotePath) }
        print("PASS file and directory type safeguards")

        let downloaded = localRoot.appendingPathComponent("downloaded.bin")
        var downloadProgress: [Double] = []
        try board.download(remotePath: remotePath, localURL: downloaded, overwrite: false, progress: { downloadProgress.append($0) })
        let received = try Data(contentsOf: downloaded)
        try expect(received == payload, "Multi-chunk binary roundtrip exact")
        try verifyProgress(downloadProgress, "download")
        print("PASS multi-chunk binary download")

        let replacement = bytes(2_051, salt: 129)
        try replacement.write(to: localFile)
        let beforeRefusal = try fm.contentsOfDirectory(atPath: boardRoot.appendingPathComponent("flash").path).sorted()
        try expectError("upload defaults to preserving existing destination") {
            try board.upload(localURL: localFile, remotePath: remotePath, overwrite: false, progress: nil)
        }
        let afterRefusalData = try Data(contentsOf: boardFile)
        try expect(afterRefusalData == payload, "Refused upload preserved existing contents")
        let afterRefusal = try fm.contentsOfDirectory(atPath: boardRoot.appendingPathComponent("flash").path).sorted()
        try expect(beforeRefusal == afterRefusal, "Refused upload left no temporary files")
        try Data("upload-write:remote-error".utf8).write(to: boardRoot.appendingPathComponent(".test-fault"))
        try expectError("remote error during upload overwrite") {
            try board.upload(localURL: localFile, remotePath: remotePath, overwrite: true, progress: nil)
        }
        let afterUploadFailure = try Data(contentsOf: boardFile)
        try expect(afterUploadFailure == payload, "Interrupted upload preserved previous destination")
        let afterUploadFiles = try fm.contentsOfDirectory(atPath: boardRoot.appendingPathComponent("flash").path).sorted()
        try expect(afterUploadFiles == beforeRefusal, "Interrupted upload cleaned temporary file")
        try Data("upload-write:corrupt-upload".utf8).write(to: boardRoot.appendingPathComponent(".test-fault"))
        try expectError("CRC rejects altered base64 bytes before commit") {
            try board.upload(localURL: localFile, remotePath: remotePath, overwrite: true, progress: nil)
        }
        let afterCorruption = try Data(contentsOf: boardRoot.appendingPathComponent(String(remotePath.dropFirst())))
        try expect(afterCorruption == payload, "CRC failure preserves old destination")
        try expect(BoardSession.crc32(Data("123456789".utf8)) == 0xcbf43926, "IEEE CRC32 reference vector")
        try board.upload(localURL: localFile, remotePath: remotePath, overwrite: true, progress: nil)
        let replaced = try Data(contentsOf: boardFile)
        try expect(replaced == replacement, "Explicit upload overwrite replaces exactly")

        try expectError("download defaults to preserving existing Mac file") {
            try board.download(remotePath: remotePath, localURL: downloaded, overwrite: false, progress: nil)
        }
        let refusedLocal = try Data(contentsOf: downloaded)
        try expect(refusedLocal == payload, "Refused download preserved existing Mac contents")
        let localFilesBefore = try fm.contentsOfDirectory(atPath: localRoot.path).sorted()
        try Data("download-read:remote-error".utf8).write(to: boardRoot.appendingPathComponent(".test-fault"))
        try expectError("remote error during download overwrite") {
            try board.download(remotePath: remotePath, localURL: downloaded, overwrite: true, progress: nil)
        }
        let afterDownloadFailure = try Data(contentsOf: downloaded)
        try expect(afterDownloadFailure == payload, "Interrupted download preserved previous Mac destination")
        let localFilesAfter = try fm.contentsOfDirectory(atPath: localRoot.path).sorted()
        try expect(localFilesBefore == localFilesAfter, "Interrupted download cleaned temporary file")
        try board.download(remotePath: remotePath, localURL: downloaded, overwrite: true, progress: nil)
        let replacedLocal = try Data(contentsOf: downloaded)
        try expect(replacedLocal == replacement, "Explicit download overwrite replaces exactly")
        print("PASS upload/download overwrite safeguards")

        let emptyLocal = localRoot.appendingPathComponent("empty.bin")
        try Data().write(to: emptyLocal)
        try board.upload(localURL: emptyLocal, remotePath: "/sd/empty.bin", overwrite: false, progress: nil)
        let emptyTarget = localRoot.appendingPathComponent("empty-downloaded.bin")
        try board.download(remotePath: "/sd/empty.bin", localURL: emptyTarget, overwrite: false, progress: nil)
        let empty = try Data(contentsOf: emptyTarget)
        try expect(empty.isEmpty, "Zero-byte file roundtrip")

        let missingTarget = localRoot.appendingPathComponent("must-not-exist.bin")
        try expectError("missing remote file") {
            try board.download(remotePath: "/flash/does-not-exist.bin", localURL: missingTarget, overwrite: false, progress: nil)
        }
        try expect(!fm.fileExists(atPath: missingTarget.path), "Failed download created no destination")
        try expectError("listing a missing remote directory") { _ = try board.list(path: "/missing") }
        try Data("remote-error".utf8).write(to: boardRoot.appendingPathComponent(".test-fault"))
        try expectError("remote traceback surfaced") { _ = try board.list(path: "/flash") }
        let recovered = try board.list(path: "/flash")
        try expect(recovered.contains { $0.name == fixtureName }, "Session usable after remote exception")
        print("PASS empty files, remote errors and recovery")

        let filesBeforeTimeout = try fm.contentsOfDirectory(atPath: boardRoot.appendingPathComponent("flash").path).sorted()
        try Data("upload-write:stall".utf8).write(to: boardRoot.appendingPathComponent(".test-fault"))
        let timeoutStart = Date()
        try expectError("missing raw REPL response times out") {
            try board.upload(localURL: localFile, remotePath: remotePath, overwrite: true, progress: nil)
        }
        try expect(Date().timeIntervalSince(timeoutStart) < 4, "Protocol timeout bounded")
        let afterTimeout = try Data(contentsOf: boardFile)
        try expect(afterTimeout == replacement, "Timed-out upload preserved original destination")
        let filesAfterTimeout = try fm.contentsOfDirectory(atPath: boardRoot.appendingPathComponent("flash").path).sorted()
        let retained = filesAfterTimeout.filter { !filesBeforeTimeout.contains($0) }
        try expect(retained.count == 1 && retained[0].hasSuffix(".part"), "Uncertain upload retains only its staging file")
        try expect(terminalOutput.contains(retained[0]), "Retained staging path reported in terminal")
        let recoveredTimeout = try board.list(path: "/flash")
        try expect(recoveredTimeout.contains { $0.name == fixtureName }, "Session usable after timeout recovery")
        print("PASS timeout preserves destination and reports retained staging file")

        try board.send(command: "print('terminal-roundtrip-marker')")
        for _ in 0..<10 {
            try board.pollOutput()
            if terminalOutput.contains("terminal-roundtrip-marker") { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try expect(terminalOutput.contains("terminal-roundtrip-marker"), "Interactive terminal delivered output")
        board.disconnect()
        try expectError("operations after disconnect") { _ = try board.list(path: "/flash") }
        try board.connect(path: port)
        let reconnected = try board.list(path: "/flash")
        try expect(reconnected.contains { $0.name == fixtureName }, "Reconnect and list work")
        print("PASS terminal, disconnect and reconnect")
        try Data("disconnect".utf8).write(to: boardRoot.appendingPathComponent(".test-fault"))
        let unplugStart = Date()
        try expectError("PTY disappears during command") { _ = try board.list(path: "/flash") }
        try expect(Date().timeIntervalSince(unplugStart) < 4, "Physical disconnect detected promptly")
        print("PASS simulated unplug during command")
        print("SUCCESS: \(checks) integration checks; simulated device only")
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
