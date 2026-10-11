"""Disposable SFTP subsystem; all paths stay inside a per-connection fixture root."""
import errno
import os
from pathlib import Path
import tempfile
import time
import paramiko

class FixtureSFTPServer(paramiko.SFTPServer):
    def _send_packet(self, packet_type, packet):
        if packet_type == paramiko.sftp.CMD_VERSION:
            packet.add_string('posix-rename@openssh.com')
            packet.add_string('1')
        return super()._send_packet(packet_type, packet)

class Files(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, root, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.root = Path(tempfile.mkdtemp(prefix='files-', dir=root))
        (self.root / 'folder').mkdir()
        (self.root / 'empty.txt').write_bytes(b'')
        (self.root / 'hello 世界.txt').write_bytes(bytes(range(256)) * 8192)
        (self.root / 'slow.bin').write_bytes(bytes(range(256)) * 32768)
        (self.root / 'link').symlink_to('folder')
        (self.root / 'mutating.bin').write_bytes(bytes(range(256)) * 128)
    def path(self, path):
        target = Path(os.path.abspath(self.root / path.lstrip('/')))
        if not target.is_relative_to(self.root): raise OSError(errno.EACCES, 'outside fixture')
        for parent in target.parents:
            if parent == self.root: break
            if parent.is_symlink(): raise OSError(errno.EACCES, 'linked parent')
        return target
    def canonicalize(self, path):
        try: return '/' + str(self.path(path).relative_to(self.root)).replace('\\', '/') if self.path(path) != self.root else '/'
        except OSError: return '/denied'
    def list_folder(self, path):
        try:
            out = []
            for dot in ['.', '..']:
                attrs = paramiko.SFTPAttributes.from_stat(self.path(path).stat()); attrs.filename = dot; out.append(attrs)
            for file in self.path(path).iterdir():
                attrs = paramiko.SFTPAttributes.from_stat(file.lstat()); attrs.filename = file.name
                if file.name == 'metadata-lite.bin':
                    attrs.st_atime = attrs.st_mtime = None
                if file.name == 'listing-changed.bin' and not getattr(self, 'listing_changed', False):
                    self.listing_changed = True
                    value = file.stat()
                    os.utime(file, (value.st_atime, value.st_mtime + 10))
                out.append(attrs)
            return out
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def stat(self, path):
        try: return paramiko.SFTPAttributes.from_stat(self.path(path).stat())
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def lstat(self, path):
        try: return paramiko.SFTPAttributes.from_stat(self.path(path).lstat())
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def mkdir(self, path, attr):
        try: self.path(path).mkdir(mode=0o700); return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def rmdir(self, path):
        try: self.path(path).rmdir(); return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def rename(self, oldpath, newpath):
        try:
            destination = self.path(newpath)
            if os.path.lexists(destination): return paramiko.SFTP_FAILURE
            self.path(oldpath).rename(destination)
            return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def posix_rename(self, oldpath, newpath):
        if newpath.endswith('/no-atomic.bin'): return paramiko.SFTP_OP_UNSUPPORTED
        try:
            self.path(oldpath).replace(self.path(newpath))
            return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def open(self, path, flags, attr):
        try:
            file = self.path(path)
            fd = os.open(file, flags, 0o600)
            stream = os.fdopen(fd, 'rb' if flags & os.O_WRONLY == 0 else 'wb', buffering=0)
            class Handle(paramiko.SFTPHandle):
                def stat(self): return paramiko.SFTPAttributes.from_stat(os.fstat(stream.fileno()))
                def write(self, offset, data):
                    if file.name == 'slow-upload.bin' or file.name.startswith('.farcast-transfer-'): time.sleep(0.003)
                    return super().write(offset, data)
                def read(self, offset, length):
                    if file.name == 'mutating.bin' and not getattr(self, 'touched', False):
                        self.touched = True
                        value = file.stat()
                        os.utime(file, (value.st_atime, value.st_mtime + 10))
                    if file.name == 'slow.bin': time.sleep(0.03)
                    return super().read(offset, length)
            handle = Handle(flags)
            if flags & os.O_WRONLY: handle.writefile = stream
            else: handle.readfile = stream
            return handle
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
    def remove(self, path):
        try: self.path(path).unlink(); return paramiko.SFTP_OK
        except OSError as error: return paramiko.SFTPServer.convert_errno(error.errno)
