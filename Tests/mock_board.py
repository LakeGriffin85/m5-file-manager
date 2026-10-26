#!/usr/bin/env python3
"""Temporary, local-only MicroPython raw REPL simulator for transport tests.

The process reports one JSON line containing a new pseudo terminal. Python code
received on it runs with virtual os/open functions rooted in the test fixture.
This models the file protocol, not M5 hardware, firmware timing or USB drivers.
"""
import builtins
import contextlib
import errno
import io
import json
import os
import pathlib
import pty
import select
import sys
import traceback
import types
import binascii
import threading
import re
import hashlib


class FixedSys:
    # MicroPython's built-in sys module rejects arbitrary new attributes.
    # Its path and modules containers themselves remain mutable.
    __slots__ = ("path", "modules")

    def __init__(self, modules):
        self.path = ["", "/lib"]
        self.modules = modules


class Board:
    def __init__(self, root):
        self.root = pathlib.Path(root).resolve()
        self.cwd = "/"
        self.fault_file = self.root / ".test-fault"
        self.filesystem_fault_file = self.root / ".test-filesystem-faults"
        self.statvfs_file = self.root / ".test-statvfs"
        self.boot_option_file = self.root / ".test-boot-option"
        self.move_config_file = self.root / ".test-move"
        self.move_filesystems = {}
        self.fault_identity = None
        self.fault_match_count = 0
        self.modules = {}
        self.sys = FixedSys(self.modules)
        self.sd_config_file = self.root / ".test-sd"
        self.sd_events_file = self.root / ".test-sd-events"
        self.sd_state_file = self.root / ".test-sd-state"
        self.sd_mounts = list(self.sd_config().get("mounts", ["/system", "/flash"]))
        self.sd_readonly_mounts = list(self.sd_config().get("readonlyMounts", []))
        self.sd_cards = []
        self.sd_mount_attempted = False
        self.sd_mounted = False
        if self.sd_config_file.exists():
            for mount in self.sd_mounts:
                self.host(mount).mkdir(parents=True, exist_ok=True)
            if self.sd_config().get("preexistingReference"):
                self.modules["_m5fm_sd_mount_1"] = {"owner": "other", "card": None, "mounted": False}
        self.os = types.SimpleNamespace(
            listdir=self.listdir, ilistdir=self.ilistdir, stat=self.stat, lstat=self.lstat,
            statvfs=self.statvfs,
            mkdir=lambda path: os.mkdir(self.host(path)),
            remove=self.remove,
            unlink=lambda path: os.unlink(self.host(path)),
            rmdir=self.rmdir,
            rename=self.rename,
            getcwd=lambda: self.cwd, chdir=self.chdir,
            uname=lambda: os.uname_result(("esp32", "test-board", "mock", "test", self.sd_config().get("board", "M5 test"))),
            sync=lambda: None,
            umount=self.sd_forbidden_unmount,
        )
        self.builtins = dict(vars(builtins), open=self.open, __import__=self.import_module)
        self.builtins["exec"] = self.execute
        self.globals = {"__builtins__": self.builtins}

    def host(self, path):
        text = os.fspath(path)
        relative = text.lstrip("/") if text.startswith("/") else (self.cwd.rstrip("/") + "/" + text).lstrip("/")
        result = (self.root / relative).resolve()
        if result != self.root and self.root not in result.parents:
            raise PermissionError("mock path outside sandbox")
        return result

    def open(self, path, mode="r", *args, **kwargs):
        self.check_filesystem_fault("open", path)
        return builtins.open(self.host(path), mode, *args, **kwargs)

    def listdir(self, path="."):
        self.check_filesystem_fault("listdir", path)
        if path == "/sd" and self.sd_config_file.exists():
            config = self.sd_config()
            if config.get("existingUnreadable") or (self.sd_mounted and config.get("postMountListError")):
                raise OSError(19, "simulated unreadable SD")
        return [name for name in os.listdir(self.host(path))
                if name not in (".test-fault", ".test-filesystem-faults", ".test-statvfs", ".test-boot-option", ".test-sd", ".test-sd-events", ".test-sd-state", ".test-move")]

    def ilistdir(self, path="."):
        for name in self.listdir(path):
            st = os.stat(self.host(path) / name)
            yield (name, st.st_mode & 0xf000, st.st_ino, st.st_size)

    def stat(self, path):
        self.check_filesystem_fault("stat", path)
        if path == "/sd" and not self.host(path).exists() and self.sd_config().get("absentErrno"):
            raise OSError(self.sd_config()["absentErrno"], "simulated absent SD path")
        return tuple(os.stat(self.host(path)))

    def sd_config(self):
        return json.loads(self.sd_config_file.read_text()) if self.sd_config_file.exists() else {}

    def move_mount_table(self):
        config = json.loads(self.move_config_file.read_text())
        if config.get("tableError"):
            raise TypeError("simulated unsupported mount introspection")
        if "malformedTable" in config:
            return config["malformedTable"]
        mounts = []
        for path in config.get("mounts", ["/flash", "/sd"]):
            kind = config.get("mountTypes", {}).get(path, "VfsLfs2" if path == "/flash" else "VfsFat")
            key = (path, kind)
            if key not in self.move_filesystems:
                self.move_filesystems[key] = type(kind, (), {})()
            mounts.append((self.move_filesystems[key], path))
        return mounts

    def sd_event(self, operation, **values):
        with builtins.open(self.sd_events_file, "a") as stream:
            stream.write(json.dumps(dict(operation=operation, **values)) + "\n")

    def sd_forbidden_unmount(self, *args, **kwargs):
        self.sd_event("unmount")
        raise AssertionError("SD mount flow must not unmount anything")

    def sd_mount(self, *args, **kwargs):
        config = self.sd_config()
        if not args:
            self.sd_event("table")
            if config.get("tableError") or (self.sd_mount_attempted and config.get("tableAfterAttemptError")):
                raise TypeError("simulated unsupported mount introspection")
            if "malformedTable" in config:
                return config["malformedTable"]
            # Preserve filesystem type identity so flash-only preflight is tested.
            mount_types = config.get("mountTypes", {})
            return [(type(mount_types.get(path, "VfsLfs2" if path in ("/system", "/flash") else "VfsFat"), (), {})(), path)
                    for path in self.sd_mounts]
        if len(args) != 2 or args[1] != "/sd":
            raise AssertionError("unexpected mount call")
        card, path = args
        self.sd_mount_attempted = True
        self.sd_event("mount", path=path, kwargs=kwargs, card=card.number)
        if kwargs != {"readonly": False, "mkfs": False}:
            raise AssertionError("mount must explicitly disable formatting")
        if config.get("mountError"):
            raise OSError(5, "simulated mount failure")
        self.sd_mounts.append(path)
        self.host(path).mkdir(exist_ok=True)
        self.sd_mounted = True
        if config.get("mountRaisesAfter"):
            raise OSError(5, "simulated lost mount completion")

    def sd_new_card(self, **kwargs):
        self.sd_event("init", kwargs=kwargs)
        config = self.sd_config()
        if config.get("initError"):
            raise OSError(19, "simulated missing card")
        board = self

        class Card:
            def __init__(self):
                self.number = len(board.sd_cards) + 1
                self.closed = False

            def info(self):
                board.sd_event("info", card=self.number)
                current = board.sd_config()
                if current.get("infoError"):
                    raise OSError(19, "simulated missing card")
                return current.get("info", (1_000_000, 512))

            def deinit(self):
                board.sd_event("deinit", card=self.number)
                if board.sd_config().get("deinitError"):
                    raise OSError(5, "simulated cleanup failure")
                self.closed = True

        card = Card()
        self.sd_cards.append(card)
        return card

    def sd_write_state(self):
        if not self.sd_config_file.exists():
            return
        state = self.modules.get("_m5fm_sd_mount_1")
        snapshot = {"retained": state is not None, "mounts": self.sd_mounts,
                    "readonlyMounts": self.sd_readonly_mounts,
                    "closedCards": [card.number for card in self.sd_cards if card.closed]}
        if isinstance(state, dict):
            snapshot.update(owner=state.get("owner"), mounted=state.get("mounted"),
                            card=getattr(state.get("card"), "number", None))
        self.sd_state_file.write_text(json.dumps(snapshot))

    def lstat(self, path):
        self.check_filesystem_fault("stat", path)
        self.host(path)  # Still reject paths that would resolve outside the fixture.
        text = os.fspath(path)
        relative = text.lstrip("/") if text.startswith("/") else (self.cwd.rstrip("/") + "/" + text).lstrip("/")
        return tuple(os.lstat(self.root / relative))

    def statvfs(self, path):
        self.check_filesystem_fault("statvfs", path)
        os.stat(self.host(path))
        if self.statvfs_file.exists():
            return tuple(json.loads(self.statvfs_file.read_text()))
        return tuple(os.statvfs(self.host(path)))

    def remove(self, path):
        self.check_filesystem_fault("remove", path)
        os.remove(self.host(path))

    def rmdir(self, path):
        self.check_filesystem_fault("rmdir", path)
        os.rmdir(self.host(path))

    def rename(self, old, new):
        self.check_filesystem_fault("rename", old)
        os.rename(self.host(old), self.host(new))

    def check_filesystem_fault(self, operation, path):
        # Read each time so a mounted device can become unavailable and recover
        # during the same serial session. These are MicroPython errno values,
        # independent of the host OS's errno numbering.
        if not self.filesystem_fault_file.exists():
            return
        relative = self.host(path).relative_to(self.root).as_posix()
        remote = "/" if relative == "." else "/" + relative
        faults = json.loads(self.filesystem_fault_file.read_text())
        for fault in faults:
            if fault["operation"] == operation and fault["path"] == remote:
                raise OSError(fault["code"], "simulated filesystem unavailable")

    def chdir(self, path):
        resolved = self.host(path)
        if not resolved.is_dir():
            raise NotADirectoryError(path)
        relative = str(resolved.relative_to(self.root))
        self.cwd = "/" if relative == "." else "/" + relative

    def import_module(self, name, globals=None, locals=None, fromlist=(), level=0):
        if name in ("os", "uos"):
            return self.os
        if name in ("json", "ujson"):
            return json
        if name in ("binascii", "ubinascii"):
            return binascii
        if name in ("hashlib", "uhashlib"):
            if (self.root / ".test-no-hashlib").exists():
                raise ImportError("simulated firmware without hashlib")
            return hashlib
        if name == "sys":
            return self.sys
        if name == "vfs" and self.move_config_file.exists():
            config = json.loads(self.move_config_file.read_text())
            if config.get("vfsMissing"):
                raise ImportError("simulated missing vfs")
            return types.SimpleNamespace(mount=self.move_mount_table)
        if name == "vfs" and self.sd_config_file.exists():
            if self.sd_config().get("vfsMissing"):
                raise ImportError("simulated missing vfs")
            return types.SimpleNamespace(mount=self.sd_mount, umount=self.sd_forbidden_unmount)
        if name == "machine" and self.sd_config_file.exists():
            if self.sd_config().get("driverMissing"):
                return types.SimpleNamespace()
            return types.SimpleNamespace(SDCard=self.sd_new_card)
        if name == "esp32" and self.boot_option_file.exists():
            marker = self.boot_option_file
            if json.loads(marker.read_text()).get("standard", False):
                return types.SimpleNamespace(NVS=type("NVS", (), {}))

            class NVS:
                def __init__(self, namespace):
                    if namespace != "uiflow":
                        raise ValueError(namespace)
                    self.pending = None

                def get_u8(self, key):
                    if key != "boot_option":
                        raise ValueError(key)
                    config = json.loads(marker.read_text())
                    if "readError" in config:
                        raise OSError(config["readError"])
                    if "value" not in config:
                        raise OSError(4354)
                    return config["value"]

                def set_u8(self, key, value):
                    if key != "boot_option":
                        raise ValueError(key)
                    config = json.loads(marker.read_text())
                    if "writeError" in config:
                        raise OSError(config["writeError"])
                    self.pending = value

                def commit(self):
                    config = json.loads(marker.read_text())
                    if "commitError" in config:
                        raise OSError(config["commitError"])
                    if not config.get("dropCommit", False):
                        config["value"] = self.pending
                        marker.write_text(json.dumps(config))

            return types.SimpleNamespace(NVS=NVS)
        if name in self.modules:
            return self.modules[name]
        if level == 0 and name.isidentifier():
            for directory in self.sys.path:
                path = (directory.rstrip("/") + "/" if directory else "") + name + ".py"
                candidate = self.host(path)
                if candidate.is_file():
                    module = types.ModuleType(name)
                    self.execute(candidate.read_text(), vars(module))
                    self.modules[name] = module
                    return module
        raise ImportError("mock does not expose module: " + name)

    def execute(self, source, globals=None, locals=None):
        namespace = self.globals if globals is None else globals
        namespace["__builtins__"] = self.builtins
        builtins.exec(source, namespace, namespace if locals is None else locals)

    def run(self, source):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                self.execute(source)
            except BaseException:
                traceback.print_exc()
        self.sd_write_state()
        return out.getvalue().encode(), err.getvalue().encode()


def main():
    board = Board(sys.argv[1])
    master, slave = pty.openpty()
    # Keep slave open: opening the app's side may happen after initial reads.
    print(json.dumps({"path": os.ttyname(slave)}), flush=True)
    raw, source, friendly = False, bytearray(), bytearray()
    interrupted = threading.Event()
    worker = None

    class TerminalWriter:
        def write(self, value):
            os.write(master, value.encode())
            return len(value)

        def flush(self):
            pass

    def run_friendly(code):
        def trace(frame, event, arg):
            if interrupted.is_set():
                raise KeyboardInterrupt
            return trace
        with contextlib.redirect_stdout(TerminalWriter()), contextlib.redirect_stderr(TerminalWriter()):
            try:
                sys.settrace(trace)
                board.execute(code)
            except BaseException:
                sys.settrace(None)
                traceback.print_exc()
            finally:
                sys.settrace(None)
        os.write(master, b"\r\n>>> ")

    def stop_worker():
        if worker is not None and worker.is_alive():
            interrupted.set()
            worker.join(timeout=2)
            if worker.is_alive():
                raise RuntimeError("simulated program did not stop")

    while True:
        if not select.select([master], [], [], 1)[0]:
            continue
        try:
            data = os.read(master, 8192)
        except OSError as exc:
            if exc.errno == errno.EIO:
                continue
            raise
        if not data:
            return
        for byte in data:
            if byte == 1:
                stop_worker()
                raw, source = True, bytearray()
                os.write(master, b"raw REPL; CTRL-B to exit\r\n>")
            elif byte == 2:
                raw, source, friendly = False, bytearray(), bytearray()
                os.write(master, b"\r\n>>> ")
            elif byte == 3:
                stop_worker()
                source, friendly = bytearray(), bytearray()
                if not raw:
                    os.write(master, b"\r\nKeyboardInterrupt\r\n>>> ")
            elif byte == 4:
                if raw:
                    pending = bytes(source)
                    source.clear()
                    if board.fault_file.exists():
                        fault = board.fault_file.read_text().strip()
                        operation, separator, action = fault.partition(":")
                        marker, ordinal_separator, ordinal = operation.partition("@")
                        matches = not separator or ("# M5FM:" + marker).encode() in pending
                        if matches and ordinal_separator:
                            if board.fault_identity != fault:
                                board.fault_identity, board.fault_match_count = fault, 0
                            board.fault_match_count += 1
                            matches = board.fault_match_count == int(ordinal)
                        if matches:
                            board.fault_file.unlink()
                            board.fault_identity, board.fault_match_count = None, 0
                            action = action if separator else operation
                            if action == "corrupt-upload":
                                decoded = json.loads(pending.decode("utf-8")[5:-5])
                                decoded, altered = re.subn(r'(data = binascii.a2b_base64\(")([A-Za-z0-9+/])',
                                                           lambda m: m[1] + ('A' if m[2] != 'A' else 'B'), decoded, count=1)
                                assert altered == 1, "Corruption fixture did not match payload"
                                pending = ("exec(" + json.dumps(decoded) + ", {})").encode("utf-8")
                            if action == "stall":
                                continue
                            if action == "reply-lost":
                                # The operation really happened, but its reply
                                # is lost. Subsequent Ctrl-C/raw entry can
                                # recover this same one-shot PTY connection.
                                board.run(pending.decode("utf-8"))
                                continue
                            if action == "disconnect":
                                return
                            if action == "remote-error":
                                os.write(master, b"OK\x04Traceback: OSError: test fault\r\n\x04>")
                                continue
                    out, err = board.run(pending.decode("utf-8"))
                    os.write(master, b"OK" + out + b"\x04" + err + b"\x04>")
                else:
                    os.write(master, b"MPY: soft reboot\r\n>>> ")
            elif raw:
                source.append(byte)
            elif byte in (10, 13):
                if friendly:
                    code = friendly.decode("utf-8")
                    friendly.clear()
                    stop_worker()
                    interrupted.clear()
                    worker = threading.Thread(target=run_friendly, args=(code,), daemon=True)
                    worker.start()
            else:
                friendly.append(byte)


if __name__ == "__main__":
    main()
