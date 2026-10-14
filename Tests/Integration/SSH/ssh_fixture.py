"""Local, synthetic SSH server; never executes received commands on the host."""
import base64
import hashlib
import socket
import sys
import subprocess
import threading
from pathlib import Path
import paramiko
from sftp_fixture import Files, FixtureSFTPServer

root = Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
mode = sys.argv[2] if len(sys.argv) > 2 else 'interactive'
host_key = paramiko.RSAKey.generate(2048)
user_key = paramiko.RSAKey.generate(2048)
(root / 'fingerprint').write_text('SHA256:' + base64.b64encode(hashlib.sha256(host_key.asbytes()).digest()).decode().rstrip('='))
user_key.write_private_key_file(str(root / 'user-key.pem'), password='fixture-passphrase')
ed_key_path = root / 'ed25519-key'
if ed_key_path.exists(): ed_key_path.unlink()
if ed_key_path.with_suffix('.pub').exists(): ed_key_path.with_suffix('.pub').unlink()
subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','fixture-passphrase','-f',str(ed_key_path)], check=True)
ed_key = paramiko.Ed25519Key.from_private_key_file(str(ed_key_path), password='fixture-passphrase')
class Server(paramiko.ServerInterface):
    def __init__(self):
        self.shell = threading.Event()
        self.channel = None
        self.destinations = {}
        self.forward_listeners = {}
        self.transport = None
    def get_allowed_auths(self, username):
        if mode.startswith('keyboard-'): return 'keyboard-interactive'
        if mode == 'key-only': return 'publickey'
        return 'password,publickey,keyboard-interactive'
    def check_auth_none(self, username):
        return paramiko.AUTH_SUCCESSFUL if mode == 'none-auth' and username == 'fixture' else paramiko.AUTH_FAILED
    def check_auth_password(self, username, password):
        if mode.startswith('keyboard-') or mode in ('password-fallback', 'key-only'): return paramiko.AUTH_FAILED
        return paramiko.AUTH_SUCCESSFUL if username == 'fixture' and password == 'fixture-password' else paramiko.AUTH_FAILED
    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == 'fixture' and key in (user_key, ed_key) else paramiko.AUTH_FAILED
    def check_auth_interactive(self, username, submethods):
        if mode == 'key-only' or username != 'fixture': return paramiko.AUTH_FAILED
        if mode == 'keyboard-code':
            return paramiko.InteractiveQuery('Fixture code', '', ('Verification code:', False))
        if mode == 'keyboard-echo':
            return paramiko.InteractiveQuery('Fixture visible prompt', '', ('Password:', True))
        if mode in ('keyboard-password', 'keyboard-no-shell', 'password-fallback'):
            return paramiko.InteractiveQuery('Fixture password', '', ('Password:', False))
        return paramiko.InteractiveQuery('Fixture MFA', 'Test prompts', ('Password:', False), ('Code:', False))
    def check_auth_interactive_response(self, responses):
        expected = ['fixture-password', '123456']
        if mode == 'keyboard-code': expected = ['123456']
        if mode in ('keyboard-password', 'keyboard-no-shell', 'keyboard-echo', 'password-fallback'):
            expected = ['fixture-password']
        return paramiko.AUTH_SUCCESSFUL if responses == expected else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, channel):
        if mode == 'forward-only': return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        if mode == 'channel-denied' and channel == 0:
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_direct_tcpip_request(self, channel, origin, destination):
        if mode not in ('forwarding', 'forward-only', 'forward-eof', 'forward-delay', 'forward-timeout'):
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        host, port = destination
        if host not in ('127.0.0.1', '::1', 'only-on-server.invalid'):
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        self.destinations[channel] = ('127.0.0.1' if host == 'only-on-server.invalid' else host, port)
        if mode == 'forward-delay': threading.Event().wait(0.25)
        if mode == 'forward-timeout': threading.Event().wait(26)
        return paramiko.OPEN_SUCCEEDED
    def check_port_forward_request(self, address, port):
        if mode not in ('forwarding', 'forward-only', 'forward-eof', 'forward-delay') or address not in ('127.0.0.1', '::1'):
            return False
        listener = socket.socket(socket.AF_INET6 if address == '::1' else socket.AF_INET)
        try:
            listener.bind((address, port)); listener.listen(16); listener.settimeout(0.2)
        except OSError:
            listener.close(); return False
        actual = listener.getsockname()[1]
        stopped = threading.Event()
        self.forward_listeners[(address, actual)] = (listener, stopped)
        def accept_forwarded():
            while not stopped.is_set() and self.transport.is_active():
                try:
                    peer, origin = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                try:
                    channel = self.transport.open_forwarded_tcpip_channel(origin[:2], (address, actual))
                    threading.Thread(target=bridge, args=(channel, peer), daemon=True).start()
                except Exception:
                    peer.close()
        threading.Thread(target=accept_forwarded, daemon=True).start()
        return actual
    def cancel_port_forward_request(self, address, port):
        found = self.forward_listeners.pop((address, port), None)
        if found: found[1].set(); found[0].close()
    def check_channel_pty_request(self, channel, term, width, height, *args):
        return mode not in ('no-pty', 'no-services') and term == b'xterm-256color'
    def check_channel_shell_request(self, channel):
        if mode in ('no-shell', 'keyboard-no-shell'): return False
        self.channel = channel
        self.shell.set()
        return True
    def check_channel_window_change_request(self, channel, width, height, *args):
        channel.send(f'RESIZED:{width}x{height}\r\n'.encode()); return True

def serve_shell(transport, channel):
    try:
        if mode in ('shell-eof', 'forward-eof'):
            channel.send_exit_status(0)
            channel.shutdown_write()
            channel.close()
            return
        channel.send(b'\x1b[32mFIXTURE_READY\x1b[0m\r\n')
        buffer = b''
        while transport.is_active():
            data = channel.recv(4096)
            if not data: break
            buffer += data.replace(b'\r', b'\n')
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                if line.strip() == b'exit':
                    channel.send_exit_status(0); channel.shutdown_write(); channel.close()
                    return
                channel.send(b'INPUT:' + line + b'\r\n')
    except Exception:
        pass

def bridge(channel, peer):
    # Both directions independently preserve EOF and buffered tail bytes.
    def pump(source, destination):
        try:
            while True:
                data = source.recv(32768)
                if not data: break
                destination.sendall(data)
            if hasattr(destination, 'shutdown_write'): destination.shutdown_write()
            else: destination.shutdown(socket.SHUT_WR)
        except Exception:
            pass
    first = threading.Thread(target=pump, args=(channel, peer), daemon=True)
    second = threading.Thread(target=pump, args=(peer, channel), daemon=True)
    first.start(); second.start(); first.join(); second.join()
    peer.close(); channel.close()

def serve_direct(channel, destination):
    try:
        peer = socket.create_connection(destination, timeout=5)
        peer.settimeout(None)
        bridge(channel, peer)
    except Exception:
        channel.close()

def serve(sock):
    transport = paramiko.Transport(sock); transport.add_server_key(host_key); server = Server()
    server.transport = transport
    if mode not in ('no-sftp', 'no-services', 'forward-only'):
        transport.set_subsystem_handler('sftp', FixtureSFTPServer, Files, root=root)
    try:
        transport.start_server(server=server)
        shell_started = False
        channels = []
        # Keep the authenticated transport alive for subsystem-only clients.
        while transport.is_active():
            channel = transport.accept(0.05)
            if channel is not None:
                channels.append(channel)
                if channel.get_id() in server.destinations:
                    threading.Thread(target=serve_direct, args=(channel, server.destinations[channel.get_id()]), daemon=True).start()
            if server.shell.is_set() and not shell_started:
                shell_started = True
                threading.Thread(target=serve_shell, args=(transport, server.channel), daemon=True).start()
    except Exception:
        pass
    finally:
        for listener, stopped in list(server.forward_listeners.values()):
            stopped.set(); listener.close()
        transport.close()
listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(10)
if mode == 'forwarding':
    forward_peer = socket.socket(); forward_peer.bind(('127.0.0.1', 0)); forward_peer.listen(16)
    (root / 'forward-port').write_text(str(forward_peer.getsockname()[1]))
    def echo_forward_peer(peer):
        try:
            while True:
                data = peer.recv(32768)
                if not data: break
                peer.sendall(data)
            peer.sendall(b'TAIL'); peer.shutdown(socket.SHUT_WR)
        except OSError: pass
        finally: peer.close()
    def accept_forward_peer():
        while True:
            peer, _ = forward_peer.accept()
            threading.Thread(target=echo_forward_peer, args=(peer,), daemon=True).start()
    threading.Thread(target=accept_forward_peer, daemon=True).start()
(root / 'port').write_text(str(listener.getsockname()[1]))
print('Synthetic SSH fixture ready', flush=True)
while True:
    sock, _ = listener.accept()
    threading.Thread(target=serve, args=(sock,), daemon=True).start()
