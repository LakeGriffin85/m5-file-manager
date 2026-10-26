import Foundation

struct SDTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct SDCardsTests {
    static let fm = FileManager.default
    static var checks = 0
    static let core2 = "M5STACK Core2 with ESP32(SPIRAM)"
    static let cardputer = "M5STACK Cardputer with ESP32-S3-FN8"

    static func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw SDTestFailure(description: label) }
        checks += 1
    }

    static func expectError(_ fragment: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch {
            try expect(error.localizedDescription.contains(fragment), "Error should contain \(fragment), got \(error)")
            return
        }
        throw SDTestFailure(description: "Expected error containing \(fragment)")
    }

    final class Fixture {
        let root: URL
        let board = BoardSession(timeout: 3)
        let process = Process()
        var config: [String: Any]

        init(_ values: [String: Any], setup: ((URL) throws -> Void)? = nil) throws {
            root = fm.temporaryDirectory.appendingPathComponent("m5-sd-tests-\(UUID().uuidString)", isDirectory: true)
            config = values
            if config["board"] == nil { config["board"] = core2 }
            try fm.createDirectory(at: root.appendingPathComponent("flash"), withIntermediateDirectories: true)
            try writeConfig()
            try setup?(root)
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
            process.arguments = [CommandLine.arguments[2], root.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.standardError
            try process.run()
            guard let info = try JSONSerialization.jsonObject(with: pipe.fileHandleForReading.availableData) as? [String: String],
                  let path = info["path"] else { throw SDTestFailure(description: "Simulator returned no PTY") }
            try expect(path.hasPrefix("/dev/ttys") || path.hasPrefix("/dev/pts/"), "Only isolated PTY is opened")
            try board.connect(path: path)
        }

        deinit {
            board.disconnect()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? fm.removeItem(at: root)
        }

        func writeConfig() throws {
            try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: root.appendingPathComponent(".test-sd"))
        }

        func events() throws -> [[String: Any]] {
            let path = root.appendingPathComponent(".test-sd-events")
            guard fm.fileExists(atPath: path.path) else { return [] }
            return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
        }

        func count(_ name: String) throws -> Int {
            try events().filter { $0["operation"] as? String == name }.count
        }

        func state() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".test-sd-state"))) as! [String: Any]
        }

        func expectUntouched() throws {
            try expect(try count("init") == 0, "No SD constructor before all safety checks pass")
            try expect(try count("mount") == 0, "No mount changed")
            try expect(try count("deinit") == 0, "No existing driver deinitialized")
            try expect(try count("unmount") == 0, "No filesystem unmounted")
        }
    }

    static func run() throws {
        guard CommandLine.arguments.count == 3 else { throw SDTestFailure(description: "Usage: sd-tests <python3> <mock_board.py>") }

        for (name, expected) in [
            (core2, ["slot": 2, "sck": 18, "miso": 38, "mosi": 23, "cs": 4]),
            (cardputer, ["slot": 3, "sck": 40, "miso": 39, "mosi": 14, "cs": 12])
        ] {
            let fixture = try Fixture(["board": name, "absentErrno": 19])
            _ = try fixture.board.volumes()
            try fixture.expectUntouched()
            let message = try fixture.board.mountSDCard()
            try expect(message.contains("wurde auf /sd eingebunden"), "New mount returns clear status")
            let initEvent = try fixture.events().first { $0["operation"] as? String == "init" }!
            let params = initEvent["kwargs"] as! [String: Int]
            try expect(params == expected.merging(["width": 1, "freq": 1_000_000], uniquingKeysWith: { _, new in new }), "Exact verified \(name) bus, pins and conservative clock")
            let state = try fixture.state()
            try expect(state["retained"] as? Bool == true && state["mounted"] as? Bool == true, "Mounted driver retained across isolated REPL globals")
            try expect(state["owner"] as? String == "m5-dateimanager/1", "Reserved retention key has explicit owner")
            try expect(try fixture.count("info") == 1 && fixture.count("mount") == 1, "Card info validated before one mount")
            try expect(try fixture.count("deinit") == 0 && fixture.count("unmount") == 0, "Successful mount remains live")
            let repeated = try fixture.board.mountSDCard()
            try expect(repeated.contains("bereits"), "Repeated click is idempotent")
            try expect(try fixture.count("init") == 1 && fixture.count("mount") == 1, "Repeated click never allocates another driver")
            try expect(try fixture.board.volumes().contains { $0.path == "/sd" }, "Normal refresh discovers newly mounted SD")
        }
        print("PASS exact Core2/Cardputer profiles, no auto-mount, retained drivers and idempotence")

        for unreadable in [false, true] {
            let fixture = try Fixture(["mounts": ["/system", "/flash", "/sd"], "readonlyMounts": ["/sd"], "existingUnreadable": unreadable, "board": "unknown board"])
            if unreadable {
                try expectError("bereits eingebunden, aber nicht lesbar") { _ = try fixture.board.mountSDCard() }
            } else {
                try expect(try fixture.board.mountSDCard().contains("bleibt unveraendert"), "Existing mount preserved regardless of board profile or mount mode")
            }
            try fixture.expectUntouched()
            try expect(try fixture.state()["retained"] as? Bool == false, "Existing third-party mount never acquires owned reference")
            try expect(try fixture.state()["mounts"] as? [String] == ["/system", "/flash", "/sd"], "Existing mount table unchanged")
            try expect(try fixture.state()["readonlyMounts"] as? [String] == ["/sd"], "Existing read-only SD mount remains read-only")
        }
        print("PASS existing read-only, readable and unreadable mounts are never remounted or deinitialized")

        for config in [
            ["mounts": ["/system", "/flash", "/sdcard"]] as [String: Any],
            ["mounts": ["/system", "/flash", "/mnt/sd"]],
            ["mounts": ["/system", "/flash", "/custom"], "mountTypes": ["/custom": "VfsLfs2"]],
            ["mountTypes": ["/flash": "VfsFat"]],
            ["mountTypes": ["/system": "UnknownFS"]]
        ] {
            let fixture = try Fixture(config)
            let initialPaths = fixture.config["mounts"] as? [String] ?? ["/system", "/flash"]
            try expectError("nicht als interner Flash bestaetigt") { _ = try fixture.board.mountSDCard() }
            try fixture.expectUntouched()
            try expect(try fixture.state()["mounts"] as? [String] == initialPaths, "Alternate SD/unknown mount remains untouched")
        }
        print("PASS alternate SD mount locations and unverified filesystem types prevent double initialization")

        for board in ["M5 test", "M5STACK Cardputer-ADV with ESP32-S3-FN8", "M5STACK Core2 v1.1 with ESP32(SPIRAM)"] {
            let fixture = try Fixture(["board": board])
            try expectError("Kein geprueftes SD-Profil") { _ = try fixture.board.mountSDCard() }
            try fixture.expectUntouched()
        }
        for (config, text) in [
            (["vfsMissing": true] as [String: Any], "vfs fehlt"),
            (["tableError": true], "Mount-Tabelle nicht sicher lesen"),
            (["malformedTable": "unsupported"], "keine auswertbare Mount-Tabelle"),
            (["malformedTable": [["fs", "relative"]]], "unbekannte Mount-Tabelle"),
            (["mounts": ["/system", "/flash", "/sd/nested"]], "Unter /sd besteht bereits ein Mount"),
            (["absentErrno": 5], "Pfad /sd kann nicht sicher geprueft werden"),
            (["driverMissing": true], "keinen machine.SDCard-Treiber"),
            (["preexistingReference": true], "vorheriger SD-Zustand ist noch aufbewahrt")
        ] {
            let fixture = try Fixture(config)
            try expectError(text) { _ = try fixture.board.mountSDCard() }
            try fixture.expectUntouched()
        }
        for directory in [false, true] {
            let fixture = try Fixture([:], setup: { root in
                let path = root.appendingPathComponent("sd")
                if directory { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
                else { try Data("existing content".utf8).write(to: path) }
            })
            try expectError("bereits belegt") { _ = try fixture.board.mountSDCard() }
            try fixture.expectUntouched()
            if !directory { try expect(try String(contentsOf: fixture.root.appendingPathComponent("sd"), encoding: .utf8) == "existing content", "Placeholder file content unchanged") }
        }
        print("PASS unsupported firmware/boards, malformed introspection and occupied paths fail before GPIO changes")

        let failedConstructor = try Fixture(["initError": true])
        try expectError("kein Handle geliefert") { _ = try failedConstructor.board.mountSDCard() }
        try expect(try failedConstructor.state()["retained"] as? Bool == true, "Constructor failure retains uncertainty guard without a handle")
        try expect(try failedConstructor.count("deinit") == 0 && failedConstructor.count("mount") == 0, "No object returned, so there is no safe driver to deinitialize")
        failedConstructor.config.removeValue(forKey: "initError")
        try failedConstructor.writeConfig()
        try expectError("vorheriger SD-Zustand") { _ = try failedConstructor.board.mountSDCard() }
        try expect(try failedConstructor.count("init") == 1, "Constructor failure blocks repeated hardware initialization until reset")

        for fault in ["infoError", "mountError"] {
            let fixture = try Fixture([fault: true])
            try expectError("fehlgeschlagen") { _ = try fixture.board.mountSDCard() }
            try expect(try fixture.state()["retained"] as? Bool == false, "Failed \(fault) releases ownership for retry")
            try expect(try fixture.count("deinit") == 1, "Only a newly created driver is cleaned up after \(fault)")
            try expect(try fixture.count("unmount") == 0, "Failed mount does not unmount anything")
            fixture.config.removeValue(forKey: fault)
            try fixture.writeConfig()
            try expect(try fixture.board.mountSDCard().contains("wurde auf /sd eingebunden"), "Retry succeeds after \(fault) clears")
            try expect(try fixture.count("init") == 2, "Retry creates exactly one replacement driver")
        }
        let badInfo = try Fixture(["info": [0, 512]])
        try expectError("keine gueltige Groesse") { _ = try badInfo.board.mountSDCard() }
        try expect(try badInfo.count("mount") == 0 && badInfo.count("deinit") == 1, "Invalid media info never reaches mount")
        print("PASS constructor failures block retry; failures with a safely released handle permit retry")

        for (config, text) in [
            (["postMountListError": true] as [String: Any], "Verzeichnis lesen fehlgeschlagen"),
            (["mountRaisesAfter": true], "Dateisystem einbinden fehlgeschlagen"),
            (["tableAfterAttemptError": true], "Mount pruefen fehlgeschlagen"),
            (["mountError": true, "tableAfterAttemptError": true], "Dateisystem einbinden fehlgeschlagen")
        ] {
            let fixture = try Fixture(config)
            try expectError(text) { _ = try fixture.board.mountSDCard() }
            try expect(try fixture.state()["retained"] as? Bool == true, "Potentially live driver retained after \(config)")
            try expect(try fixture.count("deinit") == 0 && fixture.count("unmount") == 0, "Post-mount or ambiguous failure cannot destroy live block device")
            if config["mountRaisesAfter"] as? Bool == true {
                let message = try fixture.board.mountSDCard()
                try expect(message.contains("bereits"), "Confirmed mount recovers after operation threw")
            } else {
                try expectError(config["tableAfterAttemptError"] as? Bool == true ? "Mount-Tabelle" : "bereits eingebunden") {
                    _ = try fixture.board.mountSDCard()
                }
            }
            try expect(try fixture.count("init") == 1, "Retry after ambiguous completion never duplicates driver")
        }
        let cleanupFailure = try Fixture(["infoError": true, "deinitError": true])
        try expectError("Karte lesen fehlgeschlagen") { _ = try cleanupFailure.board.mountSDCard() }
        try expect(try cleanupFailure.state()["retained"] as? Bool == true, "Cleanup failure retains owned driver reference")
        try expectError("vorheriger SD-Zustand") { _ = try cleanupFailure.board.mountSDCard() }
        try expect(try cleanupFailure.count("init") == 1, "Cleanup failure prevents duplicate initialization")
        print("PASS post-mount errors, ambiguous completion and cleanup failure preserve live references")
        print("PASS \(checks) SD mount assertions; PTY simulation only, no physical USB accessed")
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
}
