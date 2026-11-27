"""Owned rsync peer. Execute only a fixed rsync server against a disposable tree."""
import shlex
import socket
import subprocess
import threading
from pathlib import Path


def request(channel, command, server):
    binary = Path(".dependencies/rsync/rsync").resolve()
    if command.startswith(b"sh -c 'LC_ALL=C; export LC_ALL;"):
        def version():
            channel.sendall(b"\0/fixture/rsync\0" + subprocess.check_output([binary, "--version"]))
            channel.send_exit_status(0)
            channel.close()
        threading.Thread(target=version, daemon=True).start()
        return True
    words = shlex.split(command.decode())
    # Only fixture-owned paths and the option shapes emitted by our client.
    if words[:2] != ["/fixture/rsync", "--server"] or words[-2] != ".":
        return False
    name = words[-1].rstrip("/")
    if name not in {"/sample '$ demo", "/single"} or not hasattr(server, "file_root"):
        return False
    options = words[2:-2]
    compressed = any(opt.startswith("-") and not opt.startswith("--") and "z" in opt for opt in options)
    if compressed != (name != "/single"):
        return False
    if any(opt not in {"--sender", "--partial", "--existing", "--ignore-non-existing", "--relative", "--dirs", "--from0", "--files-from=-", "--ignore-existing", "--log-format=%i", "--log-format=X"}
           and not (opt.startswith("-") and not opt.startswith("--") and
                    all(c.isalpha() or c == "." for c in opt[1:])) for opt in options):
        return False
    target = str(server.file_root / name.lstrip("/")) + ("/" if words[-1].endswith("/") else "")
    a, b = socket.socketpair()
    proc = subprocess.Popen([binary, "--server", *options, ".", target], stdin=b, stdout=b,
                            stderr=subprocess.DEVNULL, env={"PATH": "/usr/bin:/bin"})
    b.close()
    def receive():
        try:
            while chunk := channel.recv(32768):
                a.sendall(chunk)
            a.shutdown(socket.SHUT_WR)
        except OSError:
            pass
    def send():
        try:
            while chunk := a.recv(32768):
                channel.sendall(chunk)
            channel.send_exit_status(proc.wait(timeout=10))
            channel.shutdown_write()
        finally:
            a.close()
            channel.close()
    threading.Thread(target=receive, daemon=True).start()
    threading.Thread(target=send, daemon=True).start()
    return True
