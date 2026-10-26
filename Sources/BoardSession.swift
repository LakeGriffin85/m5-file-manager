import Foundation
import Darwin
import IOKit
import IOKit.serial

/// Some SMB volumes reject RENAME_EXCL. Keep no-replace semantics by creating
/// the destination exclusively and checking the copied bytes before unlinking.
enum LocalFileMove {
    static func exclusive(_ source: URL, to target: URL,
                          rename: (URL, URL) -> Int32 = { renamex_np($0.path, $1.path, UInt32(RENAME_EXCL)) }) throws {
        guard source.isFileURL, target.isFileURL else { throw M5Error.message(L("Ungültiger lokaler Dateipfad.")) }
        if rename(source, target) == 0 { return }
        let code = errno
        if code == EEXIST { throw M5Error.fileExists(target.path) }
        guard code == ENOTSUP || code == ENOSYS else { throw posixError(code, L("Datei kann nicht umbenannt werden")) }
        try copyAndRemove(source, target)
    }

    private static func posixError(_ code: Int32, _ context: String) -> Error {
        M5Error.message(context + ": " + String(cString: strerror(code)))
    }

    private static func copyAndRemove(_ source: URL, _ target: URL) throws {
        let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw posixError(errno, L("Quelldatei nicht lesbar")) }
        defer { Darwin.close(input) }
        var before = Darwin.stat()
        guard fstat(input, &before) == 0 else { throw posixError(errno, L("Quelldatei nicht prüfbar")) }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw M5Error.message(L("Nur reguläre Dateien können auf diesem Volume sicher übertragen werden."))
        }
        let output = Darwin.open(target.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard output >= 0 else {
            if errno == EEXIST { throw M5Error.fileExists(target.path) }
            throw posixError(errno, L("Zieldatei kann nicht exklusiv erstellt werden"))
        }
        var created = Darwin.stat()
        guard fstat(output, &created) == 0 else {
            let code = errno
            Darwin.close(output)
            throw posixError(code, L("Neue Zieldatei nicht prüfbar; Quelle bleibt erhalten"))
        }
        var committed = false
        defer {
            if !committed {
                var current = Darwin.stat()
                if lstat(target.path, &current) == 0, current.st_dev == created.st_dev, current.st_ino == created.st_ino {
                    _ = Darwin.unlink(target.path)
                }
            }
            Darwin.close(output)
        }
        // fcopyfile operates on the already exclusively opened descriptors.
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            throw posixError(errno, L("Sicherungskopie fehlgeschlagen; Quelle bleibt erhalten"))
        }
        guard fsync(output) == 0 else { throw posixError(errno, L("Sicherungskopie konnte nicht synchronisiert werden")) }
        guard lseek(input, 0, SEEK_SET) == 0, lseek(output, 0, SEEK_SET) == 0 else {
            throw posixError(errno, L("Sicherungskopie nicht prüfbar"))
        }
        let original = FileHandle(fileDescriptor: input, closeOnDealloc: false)
        let copied = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        var verified: Int64 = 0
        while true {
            let expected = try original.read(upToCount: 65_536) ?? Data()
            var actual = Data()
            while actual.count < expected.count {
                let chunk = try copied.read(upToCount: expected.count - actual.count) ?? Data()
                guard !chunk.isEmpty else { throw M5Error.message(L("Sicherungskopie ist unvollständig; Quelle bleibt erhalten.")) }
                actual.append(chunk)
            }
            guard actual == expected else { throw M5Error.message(L("Sicherungskopie stimmt nicht mit der Quelle überein; Quelle bleibt erhalten.")) }
            if expected.isEmpty { break }
            verified += Int64(expected.count)
        }
        guard (try copied.read(upToCount: 1) ?? Data()).isEmpty else {
            throw M5Error.message(L("Sicherungskopie enthält unerwartete Daten; Quelle bleibt erhalten."))
        }
        var after = Darwin.stat(), named = Darwin.stat(), destination = Darwin.stat()
        guard fstat(input, &after) == 0, lstat(source.path, &named) == 0,
              lstat(target.path, &destination) == 0 else { throw posixError(errno, L("Dateien vor Abschluss nicht prüfbar")) }
        guard verified == Int64(before.st_size), after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino,
              destination.st_dev == created.st_dev, destination.st_ino == created.st_ino else {
            throw M5Error.message(L("Dateien wurden während der Sicherung verändert; Quelle bleibt erhalten."))
        }
        guard Darwin.unlink(source.path) == 0 else { throw posixError(errno, L("Quelle konnte nach der geprüften Kopie nicht entfernt werden")) }
        committed = true
    }
}

/// A serial connection has exactly one owner. Call every method on the same worker queue.
/// File operations interrupt the interpreter, but never implicitly soft-reset it.
final class BoardSession {
    var onOutput: ((String) -> Void)?

    private var descriptor: Int32 = -1
    private var originalSettings: termios?
    private var incoming = Data()
    private var inRawREPL = false
    private var rawPromptReady = false
    private let commandTimeout: TimeInterval
    private let chunkSize = 1024
    private let resultMarker = "__M5FM__:"

    init(timeout: TimeInterval = 12) {
        commandTimeout = max(0.25, timeout)
    }

    deinit { disconnect() }

    static func availablePorts() -> [DevicePort] {
        var iterator: io_iterator_t = 0
        var vendorIDs: [String: Int] = [:]
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                if let property = IORegistryEntryCreateCFProperty(entry, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                   let path = property as? String,
                   let value = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "idVendor" as CFString, kCFAllocatorDefault,
                                                              IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? NSNumber {
                    vendorIDs[path] = value.intValue
                }
                IOObjectRelease(entry); entry = IOIteratorNext(iterator)
            }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter {
            $0.hasPrefix("cu.usb") || $0.hasPrefix("cu.SLAB") ||
            $0.hasPrefix("cu.wch") || $0.hasPrefix("cu.CP210")
        }.sorted().map {
            let path = "/dev/" + $0, vendor = vendorIDs["/dev/" + $0]
            return DevicePort(path: path, title: $0 + (vendor == 0x303a ? " · Espressif" : ""), vendorID: vendor)
        }
    }

    func connect(path: String) throws {
        disconnect()
        guard !path.contains("\0") else { throw failure(L("Ungültiger USB-Port.")) }
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw systemFailure(L("USB-Port kann nicht geöffnet werden")) }
        descriptor = fd
        do {
            guard ioctl(fd, UInt(TIOCEXCL)) == 0 else {
                throw systemFailure(L("USB-Port ist bereits belegt"))
            }
            var settings = termios()
            guard tcgetattr(fd, &settings) == 0 else { throw systemFailure(L("USB-Konfiguration nicht lesbar")) }
            originalSettings = settings
            cfmakeraw(&settings)
            settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
            settings.c_cflag &= ~tcflag_t(CRTSCTS | HUPCL)
            cfsetispeed(&settings, speed_t(B115200))
            cfsetospeed(&settings, speed_t(B115200))
            withUnsafeMutablePointer(to: &settings.c_cc) {
                $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { chars in
                    chars[Int(VMIN)] = 1
                    chars[Int(VTIME)] = 0
                }
            }
            guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
                throw systemFailure(L("USB-Port lässt sich nicht konfigurieren"))
            }
            // No DTR/RTS manipulation, no bootloader entry and no soft reset.
            try enterRawREPL()
            try leaveRawREPL()
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        guard descriptor >= 0 else { return }
        if inRawREPL {
            try? writeAll(Data([3, 2]), timeout: 0.2)
        }
        if var settings = originalSettings {
            // Restoring HUPCL would ask the driver to lower modem-control lines on close.
            settings.c_cflag &= ~tcflag_t(HUPCL)
            _ = tcsetattr(descriptor, TCSANOW, &settings)
        }
        _ = ioctl(descriptor, UInt(TIOCNXCL))
        Darwin.close(descriptor)
        descriptor = -1
        originalSettings = nil
        inRawREPL = false
        rawPromptReady = false
        incoming.removeAll(keepingCapacity: false)
    }

    func volumes() throws -> [RemoteVolume] {
        try withRawREPL {
            let result = try execute("volumes", """
            import os
            path = '/'
            try:
                roots = os.listdir(path)
                volumes = []
                warnings = []
                if 'flash' in roots:
                    path = '/flash'
                    if os.stat(path)[0] & 0x4000:
                        os.listdir(path)
                        volumes.append({'name':'Flash', 'path':path})
                if not volumes:
                    volumes.append({'name':'Flash', 'path':'/'})
                if 'sd' in roots:
                    path = '/sd'
                    try:
                        if os.stat(path)[0] & 0x4000:
                            os.listdir(path)
                            volumes.append({'name':'SD-Karte', 'path':path})
                    except OSError as e:
                        if not e.args or e.args[0] not in (2, 19):
                            raise
                        warnings.append(\(quoted(L("SD-Karte unter /sd nicht verfügbar (Fehler "))) + str(e.args[0]) + \(quoted(L("). Flash bleibt zugänglich."))))
                result = {'volumes':volumes, 'warnings':warnings}
            except OSError as e:
                if not e.args or not isinstance(e.args[0], int):
                    raise
                result = {'error':{'path':path, 'code':e.args[0]}}
            """)
            try checkFilesystemError(result)
            for warning in result["warnings"] as? [String] ?? [] { onOutput?(warning + "\r\n") }
            guard let values = result["volumes"] as? [[String: Any]] else { throw protocolFailure() }
            return try values.map {
                guard let name = $0["name"] as? String, let path = $0["path"] as? String else {
                    throw protocolFailure()
                }
                return RemoteVolume(name: name, path: try checkedRemotePath(path))
            }
        }
    }

    /// Explicit session-only SD initialization; ordinary discovery never changes mounts.
    func mountSDCard() throws -> String {
        try withRawREPL {
            let result = try execute("sd-mount", """
            import os, sys

            def sd_mount_table(vfs):
                try:
                    mounts = vfs.mount()
                except Exception as e:
                    raise RuntimeError(\(quoted(L("Die Firmware kann ihre Mount-Tabelle nicht sicher lesen: "))) + str(e))
                if not isinstance(mounts, (list, tuple)):
                    raise RuntimeError(\(quoted(L("Die Firmware liefert keine auswertbare Mount-Tabelle."))))
                for entry in mounts:
                    if not isinstance(entry, (list, tuple)) or len(entry) != 2 or not isinstance(entry[1], str) or not entry[1].startswith('/'):
                        raise RuntimeError(\(quoted(L("Die Firmware liefert eine unbekannte Mount-Tabelle."))))
                return mounts

            def mount_sd():
                try:
                    import vfs
                except ImportError:
                    raise RuntimeError(\(quoted(L("SD einbinden wird von dieser Firmware nicht sicher unterstuetzt: vfs fehlt."))))
                if not callable(getattr(vfs, 'mount', None)):
                    raise RuntimeError(\(quoted(L("SD einbinden erfordert eine lesbare vfs.mount()-Tabelle."))))
                mounts = sd_mount_table(vfs)
                if any(entry[1] == '/sd' for entry in mounts):
                    try:
                        os.listdir('/sd')
                    except Exception as e:
                        raise RuntimeError(\(quoted(L("/sd ist bereits eingebunden, aber nicht lesbar. Der bestehende Mount bleibt unveraendert: "))) + str(e))
                    return \(quoted(L("SD-Karte ist bereits auf /sd eingebunden. Der vorhandene Mount bleibt unveraendert.")))
                if any(entry[1].startswith('/sd/') for entry in mounts):
                    raise RuntimeError(\(quoted(L("Unter /sd besteht bereits ein Mount. Dieser wird nicht ueberdeckt."))))
                for entry in mounts:
                    if entry[1] not in ('/system', '/flash') or type(entry[0]).__name__ not in ('VfsLfs1', 'VfsLfs2'):
                        raise RuntimeError(\(quoted(L("Ein vorhandener Mount kann nicht als interner Flash bestaetigt werden: "))) + entry[1] + \(quoted(L(". Keine zweite SD-Initialisierung; vorhandene Mounts bleiben unveraendert."))))
                if 'sd' in os.listdir('/'):
                    raise RuntimeError(\(quoted(L("Der Pfad /sd ist bereits belegt, aber kein bestaetigter SD-Mount. Er wird nicht ueberdeckt."))))
                try:
                    os.stat('/sd')
                except OSError as e:
                    if not e.args or e.args[0] not in (2, 19):
                        raise RuntimeError(\(quoted(L("Der Pfad /sd kann nicht sicher geprueft werden: "))) + str(e))
                else:
                    raise RuntimeError(\(quoted(L("Der vorhandene Pfad /sd wird nicht ueberdeckt."))))

                board = os.uname().machine
                # UIFlow2 SD slot mapping: 2 = SPI3/VSPI, 3 = SPI2/HSPI.
                # Core2 shares SPI3 with its display; Cardputer SD uses separate SPI2.
                if board == 'M5STACK Core2 with ESP32(SPIRAM)':
                    profile = {'slot':2, 'sck':18, 'miso':38, 'mosi':23, 'cs':4}
                    name = 'Core2'
                elif board == 'M5STACK Cardputer with ESP32-S3-FN8':
                    profile = {'slot':3, 'sck':40, 'miso':39, 'mosi':14, 'cs':12}
                    name = 'Cardputer'
                else:
                    raise RuntimeError(\(quoted(L("Kein geprueftes SD-Profil fuer diese Firmware: "))) + str(board))

                import machine
                if not callable(getattr(machine, 'SDCard', None)):
                    raise RuntimeError(\(quoted(L("Diese Firmware bietet keinen machine.SDCard-Treiber."))))
                key = '_m5fm_sd_mount_1'
                if key in sys.modules:
                    raise RuntimeError(\(quoted(L("Ein vorheriger SD-Zustand ist noch aufbewahrt. Keine zweite Initialisierung; Geraet bei Bedarf kontrolliert neu starten."))))
                state = {'owner':'m5-dateimanager/1', 'card':None, 'mounted':False}
                # Built-in sys rejects new attributes in MicroPython; its module table is mutable.
                sys.modules[key] = state
                attempted_mount = False
                step = \(quoted(L("Treiber starten")))
                try:
                    card = machine.SDCard(width=1, freq=1000000, **profile)
                    state['card'] = card
                    step = \(quoted(L("Karte lesen")))
                    info = card.info()
                    if not isinstance(info, (list, tuple)) or len(info) != 2 or not all(isinstance(value, int) and value > 0 for value in info):
                        raise RuntimeError(\(quoted(L("Die SD-Karte liefert keine gueltige Groesse."))))
                    step = \(quoted(L("Dateisystem einbinden")))
                    attempted_mount = True
                    vfs.mount(card, '/sd', readonly=False, mkfs=False)
                    state['mounted'] = True
                    step = \(quoted(L("Mount pruefen")))
                    if not any(entry[1] == '/sd' for entry in sd_mount_table(vfs)):
                        raise RuntimeError(\(quoted(L("Der neue Mount wurde nicht bestaetigt."))))
                    step = \(quoted(L("Verzeichnis lesen")))
                    os.listdir('/sd')
                except BaseException as e:
                    message = \(quoted(L("SD-Karte: "))) + step + \(quoted(L(" fehlgeschlagen: "))) + str(e)
                    # A failing native constructor may own resources without returning a handle.
                    constructor_failed = state['card'] is None
                    retain = state['mounted'] or constructor_failed
                    if attempted_mount and not retain:
                        try:
                            retain = any(entry[1] == '/sd' for entry in sd_mount_table(vfs))
                            state['mounted'] = retain
                        except Exception:
                            # Unknown completion must never deinitialize a potentially live device.
                            retain = True
                    if retain:
                        message += \(quoted(L(" Der SD-Zustand bleibt aufbewahrt; kein bestehender Mount wurde getrennt.")))
                        if constructor_failed:
                            message += \(quoted(L(" Der native Treiberstart hat kein Handle geliefert; vor einem neuen Versuch das Geraet kontrolliert neu starten.")))
                    else:
                        try:
                            if state['card'] is not None:
                                state['card'].deinit()
                            del sys.modules[key]
                        except BaseException as cleanup_error:
                            message += \(quoted(L(" Zusaetzlich ist die Treiberfreigabe fehlgeschlagen; Referenz aufbewahrt: "))) + str(cleanup_error)
                    raise RuntimeError(message)
                return \(quoted(L("SD-Karte wurde auf /sd eingebunden ("))) + name + ').'

            result = {'message':mount_sd()}
            """)
            guard let message = result["message"] as? String, !message.isEmpty else { throw protocolFailure() }
            return message
        }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }

    func sha256(path: String) throws -> String {
        let path = try checkedRemotePath(path, file: true)
        return try withRawREPL {
            let result = try execute("sha256", """
            import hashlib, binascii
            h = hashlib.sha256()
            f = open(\(quoted(path)), 'rb')
            try:
                while True:
                    block = f.read(1024)
                    if not block:
                        break
                    h.update(block)
            finally:
                f.close()
            result = {'hash':binascii.hexlify(h.digest()).decode()}
            """)
            guard let hash = result["hash"] as? String, hash.count == 64,
                  hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw protocolFailure() }
            return hash
        }
    }

    func list(path: String) throws -> [RemoteEntry] {
        let path = try checkedRemotePath(path)
        return try withRawREPL {
            let result = try execute("list", """
            import os
            path = \(quoted(path))
            error_path = path
            try:
                entries = []
                for name in os.listdir(path):
                    child = (path.rstrip('/') + '/' + name)
                    error_path = child
                    s = os.stat(child)
                    entries.append({'name':name, 'directory':bool(s[0] & 0x4000), 'size':s[6]})
                result = {'entries':entries}
            except OSError as e:
                if not e.args or not isinstance(e.args[0], int):
                    raise
                result = {'error':{'path':error_path, 'code':e.args[0]}}
            """)
            try checkFilesystemError(result)
            guard let values = result["entries"] as? [[String: Any]] else { throw protocolFailure() }
            return try values.map {
                guard let name = $0["name"] as? String, !name.isEmpty,
                      !name.contains("/"), name != ".", name != "..",
                      let directory = $0["directory"] as? Bool,
                      let size = ($0["size"] as? NSNumber)?.int64Value, size >= 0 else {
                    throw protocolFailure()
                }
                return RemoteEntry(name: name, path: remoteJoin(path, name), isDirectory: directory, size: size)
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    func upload(localURL: URL, remotePath: String, overwrite: Bool,
                progress: ((Double) -> Void)?) throws {
        let remotePath = try checkedRemotePath(remotePath, file: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw failure(L("Nur reguläre Dateien können hochgeladen werden: {0}", String(describing: (localURL.lastPathComponent))))
        }
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let directory = (remotePath as NSString).deletingLastPathComponent
        let token = UUID().uuidString.lowercased()
        let staging = remoteJoin(directory, ".m5fm-\(token).part")
        let backup = remoteJoin(directory, ".m5fm-\(token).backup")
        try withRawREPL {
            let existing = try stat(remotePath)
            if existing.exists {
                guard !existing.directory else { throw failure(L("Ziel ist ein Ordner: {0}", String(describing: (remotePath)))) }
                guard overwrite else { throw M5Error.fileExists(remotePath) }
            }
            var stagingCreated = false
            do {
                // UUID names are collision checked; no existing remote file is opened for truncation.
                guard !(try stat(staging)).exists, !(try stat(backup)).exists else {
                    throw failure(L("Temporärer Dateiname ist bereits belegt. Bitte erneut versuchen."))
                }
                stagingCreated = true
                _ = try execute("upload-create", """
                f = open(\(quoted(staging)), 'wb')
                f.close()
                result = {'ok':True}
                """)
                var transferred: Int64 = 0
                progress?(0)
                while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
                    guard transferred + Int64(data.count) <= size else {
                        throw failure(L("Die lokale Datei hat sich während der Übertragung verändert."))
                    }
                    let result = try execute("upload-write", """
                    import os, binascii
                    data = binascii.a2b_base64(\(quoted(data.base64EncodedString())))
                    def m5_crc(block):
                        crc = 0xffffffff
                        for value in block:
                            crc ^= value
                            for bit in range(8):
                                crc = (crc >> 1) ^ (0xedb88320 if crc & 1 else 0)
                        return crc ^ 0xffffffff
                    if m5_crc(data) != \(Self.crc32(data)):
                        raise RuntimeError(\(quoted(L("CRC der empfangenen Daten falsch"))))
                    f = open(\(quoted(staging)), 'ab')
                    try:
                        written = f.write(data)
                    finally:
                        f.close()
                    f = open(\(quoted(staging)), 'rb')
                    try:
                        f.seek(\(transferred))
                        verified = f.read(\(data.count))
                    finally:
                        f.close()
                    result = {'written':written, 'size':os.stat(\(quoted(staging)))[6], 'crc':m5_crc(verified), 'read':len(verified)}
                    """)
                    transferred += Int64(data.count)
                    guard (result["written"] as? NSNumber)?.intValue == data.count,
                          (result["size"] as? NSNumber)?.int64Value == transferred,
                          (result["crc"] as? NSNumber)?.uint32Value == Self.crc32(data),
                          (result["read"] as? NSNumber)?.intValue == data.count else {
                        throw failure(L("Schreibprüfung fehlgeschlagen. Die Zieldatei wurde nicht ersetzt."))
                    }
                    progress?(size == 0 ? 0 : min(0.99, Double(transferred) / Double(size)))
                }
                guard transferred == size, (try stat(staging)).size == size else {
                    throw failure(L("Dateigrösse stimmt nicht überein. Die Zieldatei wurde nicht ersetzt."))
                }
                let result = try execute("upload-commit", """
                import os
                target = \(quoted(remotePath))
                stage = \(quoted(staging))
                backup = \(quoted(backup))
                exists = False
                try:
                    s = os.stat(target)
                    exists = True
                    if s[0] & 0x4000:
                        raise RuntimeError(\(quoted(L("Ziel ist ein Ordner"))))
                except OSError as e:
                    if not e.args or e.args[0] != 2:
                        raise
                if exists and not \(overwrite ? "True" : "False"):
                    result = {'status':'exists'}
                else:
                    saved = False
                    installed = False
                    try:
                        if exists:
                            os.rename(target, backup)
                            saved = True
                        os.rename(stage, target)
                        installed = True
                        if os.stat(target)[6] != \(size):
                            raise RuntimeError(\(quoted(L("Dateigroesse nach Umbenennung falsch"))))
                    except Exception as transfer_error:
                        try:
                            if installed:
                                os.rename(target, stage)
                            if saved:
                                os.rename(backup, target)
                        except Exception as rollback_error:
                            raise RuntimeError(\(quoted(L("Wiederherstellung fehlgeschlagen. Original gesichert unter "))) + backup + ': ' + str(rollback_error))
                        raise transfer_error
                    retained_backup = ''
                    if saved:
                        try:
                            os.remove(backup)
                        except OSError:
                            retained_backup = backup
                    result = {'status':'ok', 'backup':retained_backup}
                """)
                if result["status"] as? String == "exists" { throw M5Error.fileExists(remotePath) }
                guard result["status"] as? String == "ok" else { throw protocolFailure() }
                stagingCreated = false
                if let retained = result["backup"] as? String, !retained.isEmpty {
                    onOutput?(L("Übertragen; ursprüngliche Datei zusätzlich aufbewahrt unter {0}\r\n", String(describing: (retained))))
                }
                progress?(1)
            } catch {
                if stagingCreated && rawPromptReady {
                    do { try removeStagingFile(staging) }
                    catch { onOutput?(L("Temporäre Datei eventuell noch vorhanden: {0}\r\n", String(describing: (staging)))) }
                } else if stagingCreated {
                    onOutput?(L("Übertragung unterbrochen. Bitte Ziel und mögliche Hilfsdateien prüfen:\r\n{0}\r\n{1}\r\n{2}\r\n", String(describing: (remotePath)), String(describing: (staging)), String(describing: (backup))))
                }
                throw error
            }
        }
    }

    func download(remotePath: String, localURL: URL, overwrite: Bool,
                  progress: ((Double) -> Void)?) throws {
        let remotePath = try checkedRemotePath(remotePath, file: true)
        try checkLocalTarget(localURL, overwrite: overwrite)
        let stage = localURL.deletingLastPathComponent().appendingPathComponent(".m5fm-\(UUID().uuidString).part")
        let fd = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { throw systemFailure(L("Lokale temporäre Datei kann nicht erstellt werden")) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var closed = false
        defer {
            if !closed { try? handle.close() }
            try? FileManager.default.removeItem(at: stage)
        }
        try withRawREPL {
            let source = try stat(remotePath)
            guard source.exists, !source.directory else {
                throw failure(L("Keine lesbare Datei: {0}", String(describing: (remotePath))))
            }
            var transferred: Int64 = 0
            progress?(0)
            while transferred < source.size {
                let count = Int(min(Int64(chunkSize), source.size - transferred))
                let result = try execute("download-read", """
                import binascii
                f = open(\(quoted(remotePath)), 'rb')
                try:
                    f.seek(\(transferred))
                    data = f.read(\(count))
                finally:
                    f.close()
                result = {'data':binascii.hexlify(data).decode(), 'count':len(data)}
                """)
                guard let hex = result["data"] as? String, hex.utf8.count == count * 2,
                      (result["count"] as? NSNumber)?.intValue == count,
                      let data = Data(strictHex: hex) else {
                    throw failure(L("Leseprüfung fehlgeschlagen. Die lokale Zieldatei wurde nicht ersetzt."))
                }
                try handle.write(contentsOf: data)
                transferred += Int64(data.count)
                progress?(min(0.99, Double(transferred) / Double(source.size)))
            }
            let final = try stat(remotePath)
            guard final.exists, !final.directory, final.size == source.size else {
                throw failure(L("Die Datei auf dem M5 hat sich während der Übertragung verändert."))
            }
            try handle.synchronize()
            try handle.close()
            closed = true
            let written = try FileManager.default.attributesOfItem(atPath: stage.path)[.size] as? NSNumber
            guard written?.int64Value == source.size else {
                throw failure(L("Lokale Dateigrösse stimmt nicht mit der Quelle überein."))
            }
            try commitLocal(stage: stage, target: localURL, overwrite: overwrite)
            progress?(1)
        }
    }

    func createDirectory(path: String) throws {
        let path = try checkedRemotePath(path)
        try withRawREPL {
            let existing = try stat(path)
            if existing.exists {
                guard existing.directory else { throw M5Error.fileExists(path) }
                return
            }
            _ = try execute("mkdir", "import os\nos.mkdir(\(quoted(path)))\nresult = {'ok':True}")
        }
    }

    func storage(path: String) throws -> StorageUsage {
        let path = try checkedRemotePath(path)
        return try withRawREPL {
            let result = try executeFilesystem("storage", path: path, """
            s = os.statvfs(error_path)
            block = s[1] or s[0]
            result = {'total':block * s[2], 'free':block * s[3]}
            """)
            guard let total = (result["total"] as? NSNumber)?.int64Value,
                  let free = (result["free"] as? NSNumber)?.int64Value,
                  total >= 0, free >= 0, free <= total else { throw protocolFailure() }
            return StorageUsage(path: path, totalBytes: total, freeBytes: free)
        }
    }

    /// Reads an exact, bounded snapshot. Same-size changes by another task cannot be detected.
    func readFile(path: String, maxBytes: Int = 1_048_576,
                  progress: ((Double) -> Void)? = nil) throws -> Data {
        let path = try checkedRemotePath(path, file: true)
        guard maxBytes >= 0 else { throw failure(L("Die maximale Dateigrösse darf nicht negativ sein.")) }
        return try withRawREPL {
            let info = try executeFilesystem("read-info", path: path, """
            s = getattr(os, 'lstat', os.stat)(error_path)
            result = {'regular':(s[0] & 0xf000) == 0x8000, 'size':s[6]}
            """)
            guard info["regular"] as? Bool == true else { throw failure(L("Keine reguläre Datei: {0}", String(describing: (path)))) }
            guard let size = (info["size"] as? NSNumber)?.int64Value, size >= 0 else { throw protocolFailure() }
            guard size <= Int64(maxBytes) else {
                throw failure(L("Die Datei ist für diese Ansicht zu gross ({0} Bytes; maximal {1} Bytes).", String(describing: (size)), String(describing: (maxBytes))))
            }
            var data = Data()
            while data.count < size {
                let count = min(4096, Int(size) - data.count)
                let result = try executeFilesystem("read-file", path: path, """
                import binascii
                f = open(error_path, 'rb')
                try:
                    f.seek(\(data.count))
                    chunk = f.read(\(count))
                finally:
                    f.close()
                result = {'data':binascii.b2a_base64(chunk).decode().strip(), 'count':len(chunk)}
                """)
                guard (result["count"] as? NSNumber)?.intValue == count,
                      let encoded = result["data"] as? String,
                      encoded.utf8.count == ((count + 2) / 3) * 4,
                      let chunk = Data(base64Encoded: encoded), chunk.count == count else {
                    throw failure(L("Die Datei hat sich beim Lesen verändert oder konnte nicht vollständig gelesen werden: {0}", String(describing: (path))))
                }
                data.append(chunk)
                progress?(min(0.99, Double(data.count) / Double(max(1, size))))
            }
            let final = try executeFilesystem("read-verify", path: path, """
            s = getattr(os, 'lstat', os.stat)(error_path)
            result = {'regular':(s[0] & 0xf000) == 0x8000, 'size':s[6]}
            """)
            guard final["regular"] as? Bool == true,
                  (final["size"] as? NSNumber)?.int64Value == size else {
                throw failure(L("Die Datei hat sich während des Lesens verändert: {0}", String(describing: (path))))
            }
            progress?(1)
            return data
        }
    }

    /// Whole-batch read-only preflight, followed by one acknowledged rename per item.
    /// A lost reply is never presented as either a successful move or a proven rollback.
    func move(paths: [String], toDirectory: String) throws -> [String] {
        guard !paths.isEmpty, paths.count <= 128 else { throw failure(L("Bitte 1 bis 128 Einträge zum Verschieben auswählen.")) }
        let sources = try paths.map { try mutableRemotePath($0) }
        let directory = try checkedRemotePath(toDirectory)
        guard Set(sources).count == sources.count else { throw failure(L("Die Auswahl enthält einen Pfad mehrfach.")) }
        let names = sources.map { ($0 as NSString).lastPathComponent }
        guard Set(names.map { $0.lowercased() }).count == names.count else {
            throw failure(L("Mehrere ausgewählte Einträge haben denselben Zielnamen. Bitte einzeln verschieben."))
        }
        for source in sources {
            guard directory != source, !directory.hasPrefix(source + "/") else {
                throw failure(L("Ein Ordner kann nicht in sich selbst oder einen eigenen Unterordner verschoben werden: {0}", String(describing: (source))))
            }
            guard (source as NSString).deletingLastPathComponent != directory else {
                throw failure(L("Der Eintrag liegt bereits im Zielordner: {0}", String(describing: (source))))
            }
            guard !sources.contains(where: { $0 != source && $0.hasPrefix(source + "/") }) else {
                throw failure(L("Die Auswahl enthält einen Ordner zusammen mit seinem Inhalt. Bitte nur den übergeordneten Ordner wählen."))
            }
        }
        let helpers = """
        import os
        def mount_table():
            try:
                import vfs
                entries = vfs.mount()
            except Exception as e:
                raise RuntimeError(\(quoted(L("Die Speichergrenzen sind nicht sicher lesbar. Bitte stattdessen kopieren: "))) + str(e))
            if not isinstance(entries, (list, tuple)) or not entries:
                raise RuntimeError(\(quoted(L("Die Mount-Tabelle ist nicht auswertbar. Bitte stattdessen kopieren."))))
            seen = []
            for entry in entries:
                if not isinstance(entry, (list, tuple)) or len(entry) != 2 or not isinstance(entry[1], str):
                    raise RuntimeError(\(quoted(L("Die Mount-Tabelle ist nicht auswertbar. Bitte stattdessen kopieren."))))
                path = entry[1]
                parts = path.split('/')
                if not path.startswith('/') or path != '/' + '/'.join(part for part in parts if part) or '.' in parts or '..' in parts or path in seen:
                    raise RuntimeError(\(quoted(L("Die Mount-Tabelle ist nicht eindeutig. Bitte stattdessen kopieren."))))
                seen.append(path)
            return entries
        def locate(path, mounts):
            matches = [entry for entry in mounts if path == entry[1] or path.startswith(entry[1].rstrip('/') + '/')]
            if not matches:
                raise RuntimeError(\(quoted(L("Der Speicher fuer diesen Pfad ist nicht bestaetigt: "))) + path + \(quoted(L(". Bitte stattdessen kopieren."))))
            return max(matches, key=lambda entry: len(entry[1]))
        def checked_directory(path):
            current = ''
            for part in path.split('/'):
                if part:
                    current += '/' + part
                    if getattr(os, 'lstat', os.stat)(current)[0] & 0xf000 != 0x4000:
                        raise RuntimeError(\(quoted(L("Kein regulaerer Ordner: "))) + current)
        def absent(path):
            try:
                getattr(os, 'lstat', os.stat)(path)
            except OSError as e:
                if e.args and e.args[0] == 2:
                    return
                raise
            raise RuntimeError(\(quoted(L("Bereits vorhanden: "))) + path + \(quoted(L(". Verschieben ersetzt keine Eintraege."))))
        """
        return try withRawREPL {
            let preflight = try execute("move-preflight", """
            \(helpers)
            sources = [\(sources.map(quoted).joined(separator: ","))]
            directory = \(quoted(directory))
            mounts = mount_table()
            target_mount = locate(directory, mounts)
            checked_directory(directory)
            plans = []
            for source in sources:
                if any(source == entry[1] or entry[1].startswith(source + '/') for entry in mounts):
                    raise RuntimeError(\(quoted(L("Ein Speicher-Stammordner oder Ordner mit eingebundenem Speicher darf nicht verschoben werden: "))) + source)
                source_mount = locate(source, mounts)
                if source_mount[1] != target_mount[1] or source_mount[0] is not target_mount[0]:
                    raise RuntimeError(\(quoted(L("Verschieben zwischen verschiedenen Speichern wird nicht unterstuetzt. Bitte stattdessen kopieren: "))) + source)
                checked_directory(source.rsplit('/', 1)[0])
                stat = getattr(os, 'lstat', os.stat)(source)
                kind = stat[0] & 0xf000
                if kind not in (0x4000, 0x8000):
                    raise RuntimeError(\(quoted(L("Dieser Dateityp kann nicht sicher verschoben werden: "))) + source)
                target = directory.rstrip('/') + '/' + source.rsplit('/', 1)[1]
                if any(target == entry[1] or entry[1].startswith(target + '/') for entry in mounts):
                    raise RuntimeError(\(quoted(L("Der Zielpfad wuerde einen eingebundenen Speicher ueberdecken: "))) + target)
                absent(target)
                plans.append({'source':source, 'target':target, 'kind':kind, 'mount':source_mount[1], 'mountID':id(source_mount[0])})
            result = {'plans':plans}
            """)
            guard let plans = preflight["plans"] as? [[String: Any]], plans.count == sources.count else { throw protocolFailure() }
            // Validate every returned plan before the first mutating command.
            var prepared: [(source: String, target: String, kind: Int, mount: String, mountID: Int64)] = []
            for (index, plan) in plans.enumerated() {
                guard plan["source"] as? String == sources[index],
                      let target = plan["target"] as? String, target == remoteJoin(directory, names[index]),
                      let kind = plan["kind"] as? Int, kind == 0x4000 || kind == 0x8000,
                      let mount = plan["mount"] as? String,
                      let mountID = (plan["mountID"] as? NSNumber)?.int64Value else { throw protocolFailure() }
                prepared.append((sources[index], target, kind, try checkedRemotePath(mount), mountID))
            }
            var completed: [String] = []
            for plan in prepared {
                let response: [String: Any]
                do {
                    response = try execute("move-commit", """
                    \(helpers)
                    source = \(quoted(plan.source))
                    target = \(quoted(plan.target))
                    directory = \(quoted(directory))
                    try:
                        mounts = mount_table()
                        a = locate(source, mounts)
                        b = locate(directory, mounts)
                        if a[1] != \(quoted(plan.mount)) or b[1] != a[1] or id(a[0]) != \(plan.mountID) or b[0] is not a[0]:
                            raise RuntimeError(\(quoted(L("Die Speichereinbindung hat sich seit der Vorpruefung veraendert."))))
                        if any(source == entry[1] or entry[1].startswith(source + '/') for entry in mounts):
                            raise RuntimeError(\(quoted(L("Der Quellordner enthaelt jetzt einen Mount."))))
                        if any(target == entry[1] or entry[1].startswith(target + '/') for entry in mounts):
                            raise RuntimeError(\(quoted(L("Der Zielpfad wuerde einen eingebundenen Speicher ueberdecken: "))) + target)
                        checked_directory(source.rsplit('/', 1)[0])
                        checked_directory(directory)
                        if getattr(os, 'lstat', os.stat)(source)[0] & 0xf000 != \(plan.kind):
                            raise RuntimeError(\(quoted(L("Der Dateityp hat sich seit der Vorpruefung veraendert."))))
                        absent(target)
                        os.rename(source, target)
                        result = {'ok':True}
                    except BaseException as e:
                        result = {'ok':False, 'error':type(e).__name__ + ': ' + str(e)}
                    """)
                } catch {
                    throw moveFailure(completed: completed, source: plan.source, target: plan.target,
                                      uncertain: true, underlying: error.localizedDescription)
                }
                guard response["ok"] as? Bool == true else {
                    throw moveFailure(completed: completed, source: plan.source, target: plan.target,
                                      uncertain: response["ok"] as? Bool != false,
                                      underlying: response["error"] as? String ?? L("Ungültige Geräteantwort."))
                }
                completed.append(plan.target)
            }
            return completed
        }
    }

    private func moveFailure(completed: [String], source: String, target: String,
                             uncertain: Bool, underlying: String) -> Error {
        let progress = completed.isEmpty ? L("Keine Verschiebung bestätigt.") : L("Bestätigt verschoben:\n") + completed.joined(separator: "\n")
        let step = uncertain ? L("Letzter Schritt unbestätigt") : L("Letzter Schritt fehlgeschlagen")
        return failure(L("Verschieben abgebrochen.\n{0}\n{1}: {2} → {3}\n{4}\nBitte den Dateibaum aktualisieren. Es wurde kein automatisches Zurückverschieben versucht.", String(describing: (progress)), String(describing: (step)), String(describing: (source)), String(describing: (target)), String(describing: (underlying))))
    }

    func rename(path: String, to destination: String) throws {
        let path = try mutableRemotePath(path)
        let destination = try mutableRemotePath(destination)
        guard (path as NSString).deletingLastPathComponent == (destination as NSString).deletingLastPathComponent else {
            throw failure(L("Umbenennen ist nur im selben Ordner möglich."))
        }
        try withRawREPL {
            let result = try executeFilesystem("rename", path: path, """
            source = \(quoted(path))
            target = \(quoted(destination))
            kind = getattr(os, 'lstat', os.stat)(source)[0] & 0xf000
            if kind not in (0x4000, 0x8000):
                result = {'status':'type'}
            else:
                error_path = target
                exists = True
                try:
                    getattr(os, 'lstat', os.stat)(target)
                except OSError as e:
                    if not e.args or e.args[0] != 2:
                        raise
                    exists = False
                if exists:
                    result = {'status':'exists'}
                else:
                    error_path = source
                    os.rename(source, target)
                    result = {'status':'ok'}
            """)
            if result["status"] as? String == "exists" { throw M5Error.fileExists(destination) }
            guard result["status"] as? String == "ok" else { throw failure(L("Dieser Dateityp kann nicht umbenannt werden: {0}", String(describing: (path)))) }
        }
    }

    /// Preflights the whole tree before deleting; a later device error can leave a partial deletion.
    func remove(path: String, recursive: Bool) throws {
        let path = try mutableRemotePath(path)
        try withRawREPL {
            let result = try executeFilesystem("remove", path: path, """
            target = \(quoted(path))
            recursive = \(recursive ? "True" : "False")
            pending = [(target, 0, False)]
            deletion = []
            status = 'ok'
            while pending and status == 'ok':
                current, depth, visited = pending.pop()
                error_path = current
                if current in ('/', '/flash', '/sd'):
                    status = 'protected'
                    break
                if visited:
                    deletion.append((current, 0x4000))
                    continue
                if len(deletion) + len(pending) >= 4096 or depth > 32:
                    status = 'limit'
                    break
                kind = getattr(os, 'lstat', os.stat)(current)[0] & 0xf000
                if kind == 0x8000:
                    deletion.append((current, kind))
                elif kind == 0x4000:
                    names = os.listdir(current)
                    if names and not recursive:
                        status = 'not-empty'
                        break
                    pending.append((current, depth, True))
                    for name in names:
                        if not name or '/' in name or name in ('.', '..'):
                            status = 'type'
                            break
                        pending.append((current + '/' + name, depth + 1, False))
                else:
                    status = 'type'
            if status == 'ok':
                for current, kind in deletion:
                    error_path = current
                    if (getattr(os, 'lstat', os.stat)(current)[0] & 0xf000) != kind:
                        status = 'changed'
                        break
                    if kind == 0x4000:
                        os.rmdir(current)
                    else:
                        os.remove(current)
            result = {'status':status, 'path':error_path}
            """)
            let failedPath = result["path"] as? String ?? path
            switch result["status"] as? String {
            case "ok": return
            case "not-empty": throw failure(L("Der Ordner ist nicht leer: {0}. Bitte das Löschen samt Inhalt bestätigen.", String(describing: (path))))
            case "limit": throw failure(L("Der Ordner ist zum sicheren Löschen zu gross oder zu tief (maximal 4096 Einträge, 32 Ebenen). Es wurde nichts gelöscht."))
            case "changed": throw failure(L("Der Dateityp hat sich während des Löschens verändert: {0}. Bereits gelöschte Einträge bleiben gelöscht.", String(describing: (failedPath))))
            case "protected": throw failure(L("Dieser Speicher-Stammordner ist geschützt: {0}", String(describing: (failedPath))))
            case "type": throw failure(L("Dieser Dateityp kann nicht sicher gelöscht werden: {0}", String(describing: (failedPath))))
            default: throw protocolFailure()
            }
        }
    }

    /// Submission only: stdout, completion and script exceptions arrive later in the terminal.
    func runFile(path: String) throws {
        let path = try checkedRemotePath(path, file: true)
        guard path.lowercased().hasSuffix(".py") else { throw failure(L("Nur Python-Dateien (.py) können gestartet werden.")) }
        try withRawREPL {
            let result = try executeFilesystem("run-check", path: path, """
            result = {'regular':(getattr(os, 'lstat', os.stat)(error_path)[0] & 0xf000) == 0x8000}
            """)
            guard result["regular"] as? Bool == true else { throw failure(L("Keine ausführbare Python-Datei: {0}", String(describing: (path)))) }
        }
        let directory = (path as NSString).deletingLastPathComponent
        let source = """
        # M5FM:run-file
        import os, sys
        previous_cwd = os.getcwd()
        previous_path = sys.path[:]
        try:
            os.chdir(\(quoted(directory)))
            sys.path.insert(0, \(quoted(directory)))
            f = open(\(quoted(path)), 'r')
            try:
                source = f.read()
            finally:
                f.close()
            exec(source, {'__name__':'__main__', '__file__':\(quoted(path))})
        finally:
            sys.path[:] = previous_path
            os.chdir(previous_cwd)
        """
        try send(command: "exec(" + quoted(source) + ", {})")
    }

    /// UIFlow uses unsigned NVS accessors absent from ordinary ESP32 MicroPython.
    func uiFlowBootOption() throws -> Int? {
        try withRawREPL {
            let result = try execute("boot-option-read", """
            try:
                import esp32
            except ImportError:
                esp32 = None
            nvs_type = getattr(esp32, 'NVS', None)
            supported = nvs_type is not None and all(callable(getattr(nvs_type, name, None)) for name in ('get_u8', 'set_u8', 'commit'))
            if not supported:
                result = {'supported':False}
            else:
                nvs = nvs_type('uiflow')
                try:
                    value = nvs.get_u8('boot_option')
                except OSError as e:
                    if not e.args or e.args[0] != 4354:
                        raise
                    value = 1
                result = {'supported':True, 'value':value}
            """)
            guard let supported = result["supported"] as? Bool else { throw protocolFailure() }
            if !supported { return nil }
            guard let value = result["value"] as? Int, (0...2).contains(value) else {
                throw failure(L("Die UIFlow-Startoption ist unbekannt. Autostart wurde nicht verändert."))
            }
            return value
        }
    }

    func setUIFlowBootOption(_ value: Int) throws {
        guard (0...2).contains(value) else { throw failure(L("Ungültige UIFlow-Startoption.")) }
        try withRawREPL {
            let result = try execute("boot-option-write", """
            import esp32
            nvs_type = getattr(esp32, 'NVS', None)
            supported = nvs_type is not None and all(callable(getattr(nvs_type, name, None)) for name in ('get_u8', 'set_u8', 'commit'))
            if not supported:
                result = {'supported':False}
            else:
                nvs = nvs_type('uiflow')
                nvs.set_u8('boot_option', \(value))
                nvs.commit()
                result = {'supported':True, 'value':nvs.get_u8('boot_option')}
            """)
            guard result["supported"] as? Bool == true else {
                throw failure(L("Diese Firmware unterstützt keine UIFlow-Startoption."))
            }
            guard result["value"] as? Int == value else {
                throw failure(L("Die UIFlow-Startoption konnte nach dem Speichern nicht bestätigt werden."))
            }
        }
    }

    func send(command: String) throws {
        try requireConnection()
        guard !inRawREPL else { throw failure(L("Dateiübertragung läuft; Terminal bitte kurz warten lassen.")) }
        guard !command.contains("\0") else { throw failure(L("Terminalbefehl enthält ein ungültiges Nullzeichen.")) }
        try writeAll(Data((command + "\r").utf8))
    }

    func interrupt() throws {
        try requireConnection()
        try writeAll(Data([3, 3]))
    }

    func restart() throws {
        try requireConnection()
        if inRawREPL { try leaveRawREPL() }
        try writeAll(Data([3, 3]))
        try drainOutputUntilQuiet()
        try writeAll(Data([4]))
    }

    func pollOutput() throws {
        try requireConnection()
        guard !inRawREPL else { return }
        if !incoming.isEmpty { emit(incoming); incoming.removeAll(keepingCapacity: true) }
        let data = try readAvailable()
        if !data.isEmpty { emit(data) }
    }

    // MARK: - Filesystem helpers

    private func mutableRemotePath(_ path: String) throws -> String {
        let path = try checkedRemotePath(path, file: true)
        guard path != "/flash", path != "/sd" else { throw failure(L("Dieser Speicher-Stammordner ist geschützt: {0}", String(describing: (path)))) }
        return path
    }

    private func executeFilesystem(_ operation: String, path: String, _ body: String) throws -> [String: Any] {
        let indented = body.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")
        let result = try execute(operation, """
        import os
        error_path = \(quoted(path))
        try:
        \(indented)
        except OSError as e:
            if not e.args or not isinstance(e.args[0], int):
                raise
            result = {'error':{'path':error_path, 'code':e.args[0]}}
        """)
        try checkFilesystemError(result)
        return result
    }

    private func checkFilesystemError(_ result: [String: Any]) throws {
        guard let error = result["error"] else { return }
        guard let details = error as? [String: Any],
              let path = details["path"] as? String,
              let code = details["code"] as? Int else { throw protocolFailure() }
        throw M5Error.filesystem(path: try checkedRemotePath(path), code: code)
    }

    private func stat(_ path: String) throws -> (exists: Bool, directory: Bool, size: Int64) {
        let result = try execute("stat", """
        import os
        try:
            s = os.stat(\(quoted(path)))
            result = {'exists':True, 'directory':bool(s[0] & 0x4000), 'size':s[6]}
        except OSError as e:
            if e.args and e.args[0] == 2:
                result = {'exists':False, 'directory':False, 'size':0}
            else:
                raise
        """)
        guard let exists = result["exists"] as? Bool, let directory = result["directory"] as? Bool,
              let size = (result["size"] as? NSNumber)?.int64Value, size >= 0 else { throw protocolFailure() }
        return (exists, directory, size)
    }

    private func removeStagingFile(_ path: String) throws {
        _ = try execute("upload-cleanup", """
        import os
        try:
            os.remove(\(quoted(path)))
        except OSError as e:
            if not e.args or e.args[0] != 2:
                raise
        result = {'ok':True}
        """)
    }

    private func checkedRemotePath(_ path: String, file: Bool = false) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 1024 else {
            throw failure(L("Ungültiger Pfad auf dem Gerät."))
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains("."), !parts.contains(".."), !file || !parts.isEmpty else {
            throw failure(L("Ungültiger Dateipfad auf dem Gerät."))
        }
        return "/" + parts.joined(separator: "/")
    }

    private func localExists(_ url: URL) throws -> Bool {
        var info = Darwin.stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw systemFailure(L("Lokaler Dateistatus nicht lesbar"))
    }

    private func checkLocalTarget(_ target: URL, overwrite: Bool) throws {
        guard target.isFileURL else { throw failure(L("Lokales Ziel ist keine Datei-URL.")) }
        if try localExists(target) {
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw failure(L("Lokales Ziel ist keine reguläre Datei: {0}", String(describing: (target.lastPathComponent))))
            }
            guard overwrite else { throw M5Error.fileExists(target.path) }
        }
    }

    private func commitLocal(stage: URL, target: URL, overwrite: Bool) throws {
        try checkLocalTarget(target, overwrite: overwrite)
        let backup = target.deletingLastPathComponent().appendingPathComponent(".m5fm-\(UUID().uuidString).backup")
        let saved = try localExists(target)
        if saved { try renameExclusive(target, backup) }
        do {
            try renameExclusive(stage, target)
        } catch {
            if saved {
                do { try renameExclusive(backup, target) }
                catch { throw failure(L("Wiederherstellung fehlgeschlagen. Original aufbewahrt: {0}", String(describing: (backup.path)))) }
            }
            throw error
        }
        if saved {
            do { try FileManager.default.removeItem(at: backup) }
            catch { onOutput?(L("Download abgeschlossen; Original zusätzlich aufbewahrt: {0}\r\n", String(describing: (backup.path)))) }
        }
    }

    private func renameExclusive(_ source: URL, _ target: URL) throws {
        try LocalFileMove.exclusive(source, to: target)
    }

    // MARK: - Raw REPL protocol

    private func withRawREPL<T>(_ operation: () throws -> T) throws -> T {
        try enterRawREPL()
        do {
            let result = try operation()
            try leaveRawREPL()
            return result
        } catch {
            // Ctrl-C may abort an incomplete command. Ctrl-B returns to the friendly REPL.
            try? writeAll(Data([3, 3, 2]), timeout: 0.3)
            incoming.removeAll(keepingCapacity: true)
            inRawREPL = false
            rawPromptReady = false
            throw error
        }
    }

    private func enterRawREPL() throws {
        try requireConnection()
        if inRawREPL { return }
        try writeAll(Data([13, 3, 3]))
        try drainOutputUntilQuiet()
        incoming.removeAll(keepingCapacity: true)
        try writeAll(Data([13, 1]))
        let banner = try readUntil(Data("raw REPL; CTRL-B to exit\r\n>".utf8), timeout: commandTimeout)
        if !banner.isEmpty { emit(banner) }
        inRawREPL = true
        rawPromptReady = true
    }

    private func leaveRawREPL() throws {
        try writeAll(Data([2]))
        inRawREPL = false
        rawPromptReady = false
        // Prompt and subsequent device output belong to the console, not to the protocol parser.
        if !incoming.isEmpty { emit(incoming); incoming.removeAll(keepingCapacity: true) }
    }

    private func execute(_ operation: String, _ body: String) throws -> [String: Any] {
        guard inRawREPL, rawPromptReady else { throw protocolFailure() }
        // Isolated globals avoid overwriting variables of the interrupted user's program.
        let source = "# M5FM:\(operation)\n" + body + "\nimport json\nprint(" + quoted(resultMarker) + " + json.dumps(result))\n"
        let command = Data(("exec(" + quoted(source) + ", {})").utf8)
        rawPromptReady = false
        // Classic raw REPL is supported by old UIFlow firmware as well as current MicroPython.
        // Pace source chunks to avoid overrunning the device's UART receive buffer.
        var offset = 0
        while offset < command.count {
            let end = min(offset + 128, command.count)
            try writeAll(command.subdata(in: offset..<end))
            offset = end
            if offset < command.count { usleep(2_000) }
        }
        try writeAll(Data([4]))
        let acknowledgement = try readCount(2, timeout: commandTimeout)
        guard acknowledgement == Data("OK".utf8) else {
            throw failure(L("Das Gerät bestätigt den Dateibefehl nicht. Bitte neu verbinden."))
        }
        let output = try readUntil(Data([4]), timeout: commandTimeout)
        let errors = try readUntil(Data([4]), timeout: commandTimeout)
        let prompt = try readCount(1, timeout: commandTimeout)
        guard prompt == Data([62]) else { throw protocolFailure() }
        rawPromptReady = true
        let text = String(decoding: output, as: UTF8.self)
        var payload: String?
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            if line.hasPrefix(resultMarker) {
                guard payload == nil else { throw protocolFailure() }
                payload = String(line.dropFirst(resultMarker.count))
            } else { onOutput?(line + "\r\n") }
        }
        if !errors.isEmpty {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            onOutput?(message + "\r\n")
            throw failure(L("M5-Dateibefehl fehlgeschlagen: {0}", String(describing: (message))))
        }
        guard let payload, let data = payload.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw protocolFailure()
        }
        return value
    }

    private func quoted(_ string: String) -> String {
        // JSON string escaping is also valid for Python string literals. Keep slash escapes disabled.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(string), as: UTF8.self)
    }

    private func drainOutputUntilQuiet() throws {
        let end = Date().addingTimeInterval(min(commandTimeout, 1.0))
        var lastReceived = Date()
        if !incoming.isEmpty { emit(incoming); incoming.removeAll(keepingCapacity: true) }
        while Date() < end {
            let data = try readAvailable()
            if !data.isEmpty { emit(data); lastReceived = Date() }
            if Date().timeIntervalSince(lastReceived) >= 0.10 { return }
            usleep(5_000)
        }
    }

    private func readCount(_ count: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while incoming.count < count {
            try receiveMore(until: deadline)
        }
        let value = incoming.prefix(count)
        incoming.removeFirst(count)
        return Data(value)
    }

    /// Returns bytes before marker, removing both returned bytes and marker from the buffer.
    private func readUntil(_ marker: Data, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let range = incoming.range(of: marker) {
                let value = incoming[..<range.lowerBound]
                incoming.removeSubrange(..<range.upperBound)
                return Data(value)
            }
            guard incoming.count < 8 * 1024 * 1024 else {
                throw failure(L("Antwort des Geräts ist zu gross. Bitte Verbindung prüfen."))
            }
            try receiveMore(until: deadline)
        }
    }

    private func receiveMore(until deadline: Date) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw failure(L("Zeitüberschreitung beim M5. Bitte Verbindung und Zustand der letzten Dateiaktion prüfen."))
        }
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let status = Darwin.poll(&request, 1, Int32(min(remaining * 1_000, 100)))
        if status < 0 {
            if errno == EINTR { return }
            throw systemFailure(L("USB-Verbindung kann nicht gelesen werden"))
        }
        if request.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
            throw failure(L("USB-Verbindung wurde getrennt."))
        }
        if status > 0 { incoming.append(try readAvailable()) }
    }

    private func readAvailable() throws -> Data {
        try requireConnection()
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let status = Darwin.poll(&request, 1, 0)
            if status < 0 {
                if errno == EINTR { continue }
                throw systemFailure(L("USB-Verbindung kann nicht gelesen werden"))
            }
            if request.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw failure(L("USB-Verbindung wurde getrennt."))
            }
            guard status > 0, request.revents & Int16(POLLIN) != 0 else { return result }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                // Keep terminal polling bounded even when a program continuously prints.
                if result.count >= 256 * 1024 { return result }
            } else if count == 0 {
                throw failure(L("USB-Verbindung wurde getrennt."))
            } else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return result }
            else { throw systemFailure(L("USB-Lesefehler")) }
        }
    }

    private func writeAll(_ data: Data, timeout: TimeInterval? = nil) throws {
        try requireConnection()
        let deadline = Date().addingTimeInterval(timeout ?? commandTimeout)
        var sent = 0
        while sent < data.count {
            let count = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: sent), data.count - sent)
            }
            if count > 0 { sent += count; continue }
            if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                throw systemFailure(L("USB-Schreibfehler"))
            }
            guard deadline.timeIntervalSinceNow > 0 else { throw failure(L("Zeitüberschreitung beim Schreiben auf USB.")) }
            var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            _ = Darwin.poll(&request, 1, 20)
            if request.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw failure(L("USB-Verbindung wurde getrennt."))
            }
        }
    }

    private func requireConnection() throws {
        guard descriptor >= 0 else { throw failure(L("Kein M5 verbunden.")) }
    }

    private func emit(_ data: Data) { onOutput?(String(decoding: data, as: UTF8.self)) }
    private func failure(_ message: String) -> M5Error { .message(message) }
    private func protocolFailure() -> M5Error { failure(L("Unerwartete Antwort des M5. Bitte neu verbinden.")) }
    private func systemFailure(_ context: String) -> M5Error {
        let code = errno
        return failure("\(context): \(String(cString: strerror(code)))")
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(strictHex string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var output = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            output.append((high << 4) | low)
        }
        self = output
    }
}
